/**
 * chogan_gungame.sp — GunGame gamemode for Counter-Strike: Source v92 (MISSION §6.5).
 *
 * GunGame: every player climbs a weapon ladder. A kill with your current-level weapon
 * moves you up one level (and gives you the next weapon immediately). The first player
 * to get a kill on the final level (the knife) wins the map. A knife kill steals a
 * level from the victim.
 *
 * SINGLE RESPAWN AUTHORITY (MISSION §6.5): this plugin is the ONLY plugin allowed to
 * respawn players on the GunGame server. It respawns every victim after
 * cg_gg_respawn_delay via CS_RespawnPlayer (cstrike). CSS:DM / any other respawn
 * plugin MUST NOT be loaded on the same instance, or players spawn inside each other
 * and the round-start logic corrupts (the classic double-respawn bug §6.5 warns about).
 * The DeathMatch server owns its own respawn (its DM plugin); these two servers never
 * run both plugins.
 *
 * Weapon give / respawn path is single: CS_RespawnPlayer -> player_spawn -> (next frame)
 * EquipLevel(). Every timer / frame callback is serial-guarded (MISSION §4.5) so a reused
 * client slot across the async boundary never equips or respawns the wrong player.
 *
 * Buying is suppressed at the server-config level (mp_startmoney 0 / mp_buytime 0 in the
 * instance cfg) and, defensively, by stripping every weapon on each spawn and re-giving
 * only the level weapon (+ knife). This plugin therefore does NOT need to hook buy
 * commands; if a future config leaves money on, add an SDKHook_WeaponCanUse cull here.
 *
 * Cvars autoexec to cfg/sourcemod/chogan_gungame.cfg (AutoExecConfig).
 *
 * Target: CS:S v92 (buildid 6953255), SourceMod 1.12.0-git7179, engine Engine_CSS.
 * Uses only core + cstrike + sdktools natives (no SDKCall / gamedata) — unaffected by
 * the §4.1 v92 gamedata trap.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <cstrike>

#define PLUGIN_VERSION "0.1.0"
#define GG_TAG         "[gungame]"

#define MAX_LEVELS       64
#define WEAPON_NAME_LEN  64

/* Classic CS:S ladder: rifles -> SMGs -> shotguns -> pistols -> knife. */
#define DEFAULT_LADDER "weapon_m4a1,weapon_ak47,weapon_famas,weapon_galil,weapon_mp5navy,weapon_ump45,weapon_p90,weapon_m3,weapon_xm1014,weapon_deagle,weapon_elite,weapon_fiveseven,weapon_p228,weapon_glock,weapon_knife"

public Plugin myinfo =
{
	name        = "[Chogan] GunGame",
	author      = "Chogan build (autonomous run)",
	description = "GunGame weapon-ladder gamemode for CS:S; single respawn authority (CS_RespawnPlayer)",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/Shadow-Reza/CsSource"
};

/* cvars */
ConVar g_cvWeapons;        /* cg_gg_weapons */
ConVar g_cvAnyWeapon;      /* cg_gg_anyweapon */
ConVar g_cvRespawnDelay;   /* cg_gg_respawn_delay */
ConVar g_cvLevelupHeal;    /* cg_gg_levelup_heal */
ConVar g_cvKnifeSteal;     /* cg_gg_knife_steal */
ConVar g_cvWinMapDelay;    /* cg_gg_winmap_delay */
ConVar g_cvResetEachRound; /* cg_gg_reset_each_round */
ConVar g_cvAnnounce;       /* cg_gg_announce */

/* ladder */
char g_Weapons[MAX_LEVELS][WEAPON_NAME_LEN];  /* full entity names, e.g. "weapon_ak47" */
int  g_iNumWeapons = 0;

/* per-client state (0-based level; display is level+1) */
int  g_iLevel[MAXPLAYERS + 1];

bool   g_bMatchOver = false;
Handle g_hAnnounceTimer = null;
Handle g_hWinTimer = null;

/* ---------------------------------------------------------------------------- */

public void OnPluginStart()
{
	CreateConVar("cg_gg_version", PLUGIN_VERSION, "Chogan GunGame plugin version",
		FCVAR_NOTIFY | FCVAR_DONTRECORD | FCVAR_SPONLY);

	g_cvWeapons = CreateConVar("cg_gg_weapons", DEFAULT_LADDER,
		"Comma-separated GunGame weapon ladder (entity names; a bare name gets a weapon_ prefix). Last entry is the winning level (normally weapon_knife).",
		FCVAR_NONE);
	g_cvAnyWeapon = CreateConVar("cg_gg_anyweapon", "0",
		"0 = a kill only counts for a level-up if made with the killer's current-level weapon; 1 = any weapon counts",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvRespawnDelay = CreateConVar("cg_gg_respawn_delay", "1.5",
		"Seconds before a dead player is respawned (this plugin is the only respawn authority)",
		FCVAR_NONE, true, 0.0, true, 30.0);
	g_cvLevelupHeal = CreateConVar("cg_gg_levelup_heal", "25",
		"HP added to the killer on a level-up (0 = none); total health is capped at 100",
		FCVAR_NONE, true, 0.0, true, 100.0);
	g_cvKnifeSteal = CreateConVar("cg_gg_knife_steal", "1",
		"1 = a knife kill drops the victim one level (min 0); 0 = knife kills do not steal levels",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvWinMapDelay = CreateConVar("cg_gg_winmap_delay", "10.0",
		"Seconds after a win before the map changes to the next map",
		FCVAR_NONE, true, 1.0, true, 120.0);
	g_cvResetEachRound = CreateConVar("cg_gg_reset_each_round", "0",
		"1 = reset every player's level to 1 on round_start; 0 = levels persist across rounds within a map",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvAnnounce = CreateConVar("cg_gg_announce", "30.0",
		"Seconds between periodic leader announcements in chat (0 = disabled)",
		FCVAR_NONE, true, 0.0, true, 600.0);

	g_cvWeapons.AddChangeHook(OnWeaponsChanged);
	g_cvAnnounce.AddChangeHook(OnAnnounceChanged);

	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("round_start",  Event_RoundStart);

	RegConsoleCmd("sm_gg", Cmd_GG,
		"Show the GunGame level table (leaderboard)");
	RegAdminCmd("sm_gg_setlevel", Cmd_SetLevel, ADMFLAG_GENERIC,
		"sm_gg_setlevel <target> <level 1..N> - set a player's GunGame level");

	AutoExecConfig(true, "chogan_gungame");

	ParseWeapons();

	/* late load: adopt clients already in game */
	for (int i = 1; i <= MaxClients; i++)
	{
		g_iLevel[i] = 0;
		if (IsClientInGame(i) && IsPlayerAlive(i))
		{
			EquipLevel(i);
		}
	}

	LogMessage("%s v%s loaded (respawn authority; ladder=%d levels)", GG_TAG, PLUGIN_VERSION, g_iNumWeapons);
}

public void OnConfigsExecuted()
{
	ParseWeapons();
	StartAnnounceTimer();
}

public void OnPluginEnd()
{
	delete g_hAnnounceTimer;
	delete g_hWinTimer;
}

public void OnMapStart()
{
	g_bMatchOver = false;
	/* A pending win timer (TIMER_FLAG_NO_MAPCHANGE) is auto-killed by core at map end,
	   so the stored handle is already freed here — null it, do not delete it. */
	g_hWinTimer = null;
	for (int i = 1; i <= MaxClients; i++)
	{
		g_iLevel[i] = 0;
	}
}

public void OnClientPutInServer(int client)
{
	g_iLevel[client] = 0;
}

public void OnClientDisconnect(int client)
{
	if (client >= 1 && client <= MaxClients)
	{
		g_iLevel[client] = 0;
	}
}

public void OnWeaponsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ParseWeapons();
}

public void OnAnnounceChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	StartAnnounceTimer();
}

/* ---------------------------------------------------------------------------- */
/* ladder                                                                        */

void ParseWeapons()
{
	char buf[1024];
	g_cvWeapons.GetString(buf, sizeof(buf));
	if (buf[0] == '\0')
	{
		strcopy(buf, sizeof(buf), DEFAULT_LADDER);
	}

	char parts[MAX_LEVELS][WEAPON_NAME_LEN];
	int n = ExplodeString(buf, ",", parts, MAX_LEVELS, WEAPON_NAME_LEN);

	int count = 0;
	for (int i = 0; i < n; i++)
	{
		TrimString(parts[i]);
		if (parts[i][0] == '\0')
		{
			continue;
		}
		if (strncmp(parts[i], "weapon_", 7) == 0)
		{
			strcopy(g_Weapons[count], WEAPON_NAME_LEN, parts[i]);
		}
		else
		{
			Format(g_Weapons[count], WEAPON_NAME_LEN, "weapon_%s", parts[i]);
		}
		count++;
		if (count >= MAX_LEVELS)
		{
			break;
		}
	}

	if (count == 0)
	{
		strcopy(g_Weapons[0], WEAPON_NAME_LEN, "weapon_knife");
		count = 1;
	}
	g_iNumWeapons = count;

	/* keep every live level within the (possibly shorter) new ladder */
	for (int c = 1; c <= MaxClients; c++)
	{
		if (g_iLevel[c] >= g_iNumWeapons)
		{
			g_iLevel[c] = g_iNumWeapons - 1;
		}
	}
}

void WeaponShort(const char[] full, char[] out, int maxlen)
{
	if (strncmp(full, "weapon_", 7) == 0)
	{
		strcopy(out, maxlen, full[7]);
	}
	else
	{
		strcopy(out, maxlen, full);
	}
}

/* ---------------------------------------------------------------------------- */
/* equip / strip                                                                 */

void StripAllWeapons(int client)
{
	/* CS:S slots 0..4 (primary, secondary, knife, grenade, c4); iterate one extra */
	for (int slot = 0; slot <= 5; slot++)
	{
		int wep;
		int guard = 0;
		while ((wep = GetPlayerWeaponSlot(client, slot)) != -1 && guard < 8)
		{
			RemovePlayerItem(client, wep);
			RemoveEntity(wep);
			guard++;
		}
	}
}

/**
 * Strip everything and give the client's current-level weapon (+ a knife, unless the
 * level weapon already is the knife). The level weapon is given first so that — with no
 * active weapon after the strip — the engine auto-deploys it.
 */
void EquipLevel(int client)
{
	if (g_iNumWeapons <= 0)
	{
		return;
	}
	if (!IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return;
	}
	int team = GetClientTeam(client);
	if (team != CS_TEAM_T && team != CS_TEAM_CT)
	{
		return;
	}

	int level = g_iLevel[client];
	if (level < 0)
	{
		level = 0;
	}
	if (level >= g_iNumWeapons)
	{
		level = g_iNumWeapons - 1;
	}

	StripAllWeapons(client);

	GivePlayerItem(client, g_Weapons[level]);
	if (!StrEqual(g_Weapons[level], "weapon_knife", false))
	{
		GivePlayerItem(client, "weapon_knife");
	}
}

/* ---------------------------------------------------------------------------- */
/* spawn                                                                         */

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || client > MaxClients)
	{
		return Plugin_Continue;
	}
	/* Equip next frame: the game finishes handing out default spawn equipment first,
	   then we strip it and give the level weapon. Serial-guarded for the async gap. */
	RequestFrame(Frame_EquipSpawn, GetClientSerial(client));
	return Plugin_Continue;
}

public void Frame_EquipSpawn(any serial)
{
	int client = GetClientFromSerial(serial);
	if (client == 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return;
	}
	EquipLevel(client);
}

/* ---------------------------------------------------------------------------- */
/* death: respawn (single authority) + scoring                                   */

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (g_bMatchOver)
	{
		return Plugin_Continue;
	}

	int victim   = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	char weapon[WEAPON_NAME_LEN];
	event.GetString("weapon", weapon, sizeof(weapon));

	/* ---- respawn the victim (the only respawn authority on this server) ---- */
	if (IsValidClient(victim))
	{
		CreateTimer(g_cvRespawnDelay.FloatValue, Timer_Respawn, GetClientSerial(victim),
			TIMER_FLAG_NO_MAPCHANGE);
	}

	/* ---- scoring ---- */
	/* world kill / suicide / no attacker: no level change */
	if (!IsValidClient(attacker) || attacker == victim)
	{
		return Plugin_Continue;
	}
	/* team kill: never rewards a level, never steals */
	if (IsValidClient(victim) && GetClientTeam(attacker) == GetClientTeam(victim))
	{
		return Plugin_Continue;
	}

	bool isKnife = StrEqual(weapon, "knife", false);

	/* knife-steal: enemy knife kill drops the victim one level */
	if (isKnife && g_cvKnifeSteal.BoolValue && IsValidClient(victim) && g_iLevel[victim] > 0)
	{
		g_iLevel[victim]--;
		PrintHintText(victim, "Knifed! Level down to %d / %d", g_iLevel[victim] + 1, g_iNumWeapons);
		PrintToChat(victim, "\x04%s\x01 You were knifed and lost a level (now \x04%d\x01/%d).",
			GG_TAG, g_iLevel[victim] + 1, g_iNumWeapons);
		/* the reduced level takes effect when the victim respawns (Frame_EquipSpawn) */
	}

	/* level-up: was the kill made with the attacker's current-level weapon? */
	char curShort[WEAPON_NAME_LEN];
	WeaponShort(g_Weapons[g_iLevel[attacker]], curShort, sizeof(curShort));
	bool match = g_cvAnyWeapon.BoolValue || StrEqual(weapon, curShort, false);
	if (!match)
	{
		return Plugin_Continue;
	}

	/* a matched kill while on the final level wins the map */
	if (g_iLevel[attacker] >= g_iNumWeapons - 1)
	{
		DoWin(attacker);
		return Plugin_Continue;
	}

	/* advance one level */
	g_iLevel[attacker]++;

	int heal = g_cvLevelupHeal.IntValue;
	if (heal > 0 && IsPlayerAlive(attacker))
	{
		int hp = GetClientHealth(attacker) + heal;
		if (hp > 100)
		{
			hp = 100;
		}
		SetEntProp(attacker, Prop_Send, "m_iHealth", hp);
	}

	EquipLevel(attacker);
	AnnounceLevelUp(attacker);

	return Plugin_Continue;
}

public Action Timer_Respawn(Handle timer, any serial)
{
	if (g_bMatchOver)
	{
		return Plugin_Stop;
	}
	int client = GetClientFromSerial(serial);
	if (client == 0 || !IsClientInGame(client))
	{
		return Plugin_Stop;
	}
	int team = GetClientTeam(client);
	if (team != CS_TEAM_T && team != CS_TEAM_CT)
	{
		return Plugin_Stop;   /* spectator / not on a playing team */
	}
	if (IsPlayerAlive(client))
	{
		return Plugin_Stop;   /* already alive (e.g. round restarted) */
	}
	CS_RespawnPlayer(client);   /* triggers player_spawn -> Frame_EquipSpawn */
	return Plugin_Stop;
}

/* ---------------------------------------------------------------------------- */
/* round                                                                         */

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (g_cvResetEachRound.BoolValue)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			g_iLevel[i] = 0;
		}
		PrintToChatAll("\x04%s\x01 New round - everyone reset to level 1.", GG_TAG);
	}
	return Plugin_Continue;
}

/* ---------------------------------------------------------------------------- */
/* win                                                                           */

void DoWin(int client)
{
	if (g_bMatchOver)
	{
		return;
	}
	g_bMatchOver = true;

	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));

	PrintToChatAll("\x04%s\x01 \x03%s\x01 reached the final level and \x04WON THE GAME!\x01", GG_TAG, name);
	PrintHintTextToAll("%s won the GunGame!", name);
	LogMessage("%s WIN: #%d \"%s\" completed the %d-level ladder", GG_TAG, GetClientUserId(client), name, g_iNumWeapons);

	int team = GetClientTeam(client);
	CSRoundEndReason reason = (team == CS_TEAM_T) ? CSRoundEnd_TerroristWin : CSRoundEnd_CTWin;
	CS_TerminateRound(3.0, reason);

	float delay = g_cvWinMapDelay.FloatValue;
	if (delay < 3.0)
	{
		delay = 3.0;   /* let the round-end resolve before we change level */
	}
	delete g_hWinTimer;
	g_hWinTimer = CreateTimer(delay, Timer_WinMapChange, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_WinMapChange(Handle timer)
{
	g_hWinTimer = null;
	char map[PLATFORM_MAX_PATH];
	if (!GetNextMap(map, sizeof(map)) || map[0] == '\0')
	{
		GetCurrentMap(map, sizeof(map));
	}
	LogMessage("%s changing level to %s (gungame winner)", GG_TAG, map);
	ForceChangeLevel(map, "GunGame winner");
	return Plugin_Stop;
}

/* ---------------------------------------------------------------------------- */
/* HUD / announcements                                                           */

void StartAnnounceTimer()
{
	delete g_hAnnounceTimer;
	float t = g_cvAnnounce.FloatValue;
	if (t >= 1.0)
	{
		g_hAnnounceTimer = CreateTimer(t, Timer_Announce, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_Announce(Handle timer)
{
	if (g_bMatchOver)
	{
		return Plugin_Continue;
	}
	int best = 0;
	int bestLevel = -1;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			continue;
		}
		int team = GetClientTeam(i);
		if (team != CS_TEAM_T && team != CS_TEAM_CT)
		{
			continue;
		}
		if (g_iLevel[i] > bestLevel)
		{
			bestLevel = g_iLevel[i];
			best = i;
		}
	}
	if (best > 0)
	{
		char name[MAX_NAME_LENGTH];
		char wshort[WEAPON_NAME_LEN];
		GetClientName(best, name, sizeof(name));
		WeaponShort(g_Weapons[g_iLevel[best]], wshort, sizeof(wshort));
		PrintToChatAll("\x04%s\x01 Leader: \x03%s\x01 on level \x04%d\x01/%d (%s)",
			GG_TAG, name, g_iLevel[best] + 1, g_iNumWeapons, wshort);
	}
	return Plugin_Continue;
}

void AnnounceLevelUp(int client)
{
	char wshort[WEAPON_NAME_LEN];
	WeaponShort(g_Weapons[g_iLevel[client]], wshort, sizeof(wshort));
	PrintHintText(client, "Level %d / %d\n%s", g_iLevel[client] + 1, g_iNumWeapons, wshort);
	PrintToChat(client, "\x04%s\x01 Level up! Now \x04%d\x01/%d: %s",
		GG_TAG, g_iLevel[client] + 1, g_iNumWeapons, wshort);
}

/* ---------------------------------------------------------------------------- */
/* commands                                                                      */

public Action Cmd_GG(int client, int args)
{
	ReplyToCommand(client, "%s ladder: %d levels. anyweapon=%d knife_steal=%d reset_each_round=%d",
		GG_TAG, g_iNumWeapons, g_cvAnyWeapon.IntValue, g_cvKnifeSteal.IntValue, g_cvResetEachRound.IntValue);
	if (client >= 1 && client <= MaxClients && IsClientInGame(client))
	{
		ReplyToCommand(client, "  You are on level %d / %d.", g_iLevel[client] + 1, g_iNumWeapons);
	}

	/* collect playing clients */
	int list[MAXPLAYERS];
	int cnt = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			continue;
		}
		int team = GetClientTeam(i);
		if (team != CS_TEAM_T && team != CS_TEAM_CT)
		{
			continue;
		}
		list[cnt++] = i;
	}

	/* selection sort by level, highest first */
	for (int a = 0; a < cnt - 1; a++)
	{
		for (int b = a + 1; b < cnt; b++)
		{
			if (g_iLevel[list[b]] > g_iLevel[list[a]])
			{
				int tmp = list[a];
				list[a] = list[b];
				list[b] = tmp;
			}
		}
	}

	ReplyToCommand(client, "  %-4s %-26s %-6s %s", "lvl", "name", "alive", "weapon");
	for (int a = 0; a < cnt; a++)
	{
		int c = list[a];
		char name[MAX_NAME_LENGTH];
		char wshort[WEAPON_NAME_LEN];
		GetClientName(c, name, sizeof(name));
		WeaponShort(g_Weapons[g_iLevel[c]], wshort, sizeof(wshort));
		ReplyToCommand(client, "  %-4d %-26s %-6s %s",
			g_iLevel[c] + 1, name, IsPlayerAlive(c) ? "yes" : "no", wshort);
	}
	if (cnt == 0)
	{
		ReplyToCommand(client, "  (no players on a team)");
	}
	return Plugin_Handled;
}

public Action Cmd_SetLevel(int client, int args)
{
	if (args < 2)
	{
		ReplyToCommand(client, "%s usage: sm_gg_setlevel <target> <level 1..%d>", GG_TAG, g_iNumWeapons);
		return Plugin_Handled;
	}

	char targ[64];
	char lvlStr[16];
	GetCmdArg(1, targ, sizeof(targ));
	GetCmdArg(2, lvlStr, sizeof(lvlStr));

	int level1 = StringToInt(lvlStr);
	if (level1 < 1)
	{
		level1 = 1;
	}
	if (level1 > g_iNumWeapons)
	{
		level1 = g_iNumWeapons;
	}
	int newLevel = level1 - 1;

	int targets[MAXPLAYERS];
	char tn[64];
	bool tn_ml;
	int count = ProcessTargetString(targ, client, targets, MAXPLAYERS,
		COMMAND_FILTER_NO_IMMUNITY, tn, sizeof(tn), tn_ml);
	if (count <= 0)
	{
		ReplyToTargetError(client, count);
		return Plugin_Handled;
	}

	for (int i = 0; i < count; i++)
	{
		int t = targets[i];
		g_iLevel[t] = newLevel;
		if (IsClientInGame(t) && IsPlayerAlive(t))
		{
			EquipLevel(t);
			PrintToChat(t, "\x04%s\x01 An admin set your level to \x04%d\x01/%d.", GG_TAG, level1, g_iNumWeapons);
		}
	}

	ReplyToCommand(client, "%s set %s to level %d / %d.", GG_TAG, tn, level1, g_iNumWeapons);
	LogMessage("%s admin #%d set %s to level %d", GG_TAG,
		(client > 0) ? GetClientUserId(client) : 0, tn, level1);
	return Plugin_Handled;
}

/* ---------------------------------------------------------------------------- */
/* helpers                                                                       */

bool IsValidClient(int client)
{
	return client >= 1 && client <= MaxClients && IsClientInGame(client);
}
