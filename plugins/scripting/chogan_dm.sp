/**
 * chogan_dm.sp — Chogan Counter-Strike: Source deathmatch (MISSION §6.5).
 *
 * =========================================================================
 *  SOLE RESPAWN AUTHORITY
 * =========================================================================
 * On the DeathMatch server this plugin is the ONE and ONLY thing that
 * respawns players (MISSION §6.5). It must never be loaded on the same
 * instance as another respawn plugin (the GunGame respawn plugin, CSS:DM,
 * lanofdoom-respawn, a match plugin, ...). Two respawn authorities on one
 * server is the classic cause of "players spawn inside each other" and
 * round-start crashes. If you need DM behaviour on the GunGame server, use
 * that server's own single respawn plugin instead — not this one.
 *
 * What it does, and nothing more:
 *   - player_death  -> respawn the victim after cg_dm_respawn_delay seconds
 *                      with CS_RespawnPlayer (cstrike.inc), guarded across the
 *                      timer by the client SERIAL (MISSION §4.5), skipped while
 *                      the round has ended or the game is in warmup.
 *   - player_spawn  -> full HP / armor+helmet / spend money / (mode 1) a fixed
 *                      weapon set / optional full ammo, plus a brief spawn
 *                      protection: semi-transparent + god-mode (OnTakeDamage
 *                      returns Plugin_Handled) for cg_dm_protect seconds,
 *                      cleared by a serial-guarded timer.
 *
 * It does NOT touch bomb logic, freezetime, round limits or map rotation.
 * mp_freezetime 0 and the "no objectives" feel are configured in the DM cfg,
 * not here.
 *
 * Engine: CS:S v92 (Engine_CSS / orangebox_valve). Uses only core natives +
 * netprops (m_ArmorValue, m_bHasHelmet, m_iAccount, m_iAmmo, m_iClip1,
 * m_iPrimaryAmmoType) and CS_RespawnPlayer — no SDKCall, no gamedata, so it is
 * unaffected by the §4.1 gamedata trap.
 *
 * SourceMod 1.12 (pinned 1.12.0-git7179).
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

#define PLUGIN_VERSION "0.1.0"
#define DM_TAG         "[chogan_dm]"

/* full-ammo constants (mode-independent; only applied when cg_dm_full_ammo 1) */
#define DM_FILL_CLIP     100   /* rounds forced into the magazine  */
#define DM_FILL_RESERVE  250   /* reserve rounds for that ammo type */

/* anti-telefrag: only a small VERTICAL nudge is ever applied (see comment at
 * MaybeAntiStuck). A horizontal nudge risks pushing a player into a wall/out of
 * the world, so we never do that. */
#define DM_STUCK_DIST     40.0
#define DM_STUCK_NUDGE    16.0

/* ---- cvars ---- */
ConVar g_cvEnabled;       /* cg_dm_enabled       */
ConVar g_cvRespawnDelay;  /* cg_dm_respawn_delay */
ConVar g_cvHealth;        /* cg_dm_health        */
ConVar g_cvArmor;         /* cg_dm_armor         */
ConVar g_cvProtect;       /* cg_dm_protect       */
ConVar g_cvProtectAlpha;  /* cg_dm_protect_alpha */
ConVar g_cvFullAmmo;      /* cg_dm_full_ammo     */
ConVar g_cvMode;          /* cg_dm_mode          */
ConVar g_cvWeapons;       /* cg_dm_weapons       */
ConVar g_cvMoney;         /* cg_dm_money         */
ConVar g_cvAntiStuck;     /* cg_dm_antistuck     */

/* ---- state ---- */
bool   g_bRoundEnded    = false;
bool   g_bHasWarmupProp = false;                 /* CS:S base has none; set at OnConfigsExecuted */
bool   g_bProtected[MAXPLAYERS + 1];
bool   g_bHooked[MAXPLAYERS + 1];                /* OnTakeDamage hooked for this slot */
Handle g_hRespawnTimer[MAXPLAYERS + 1];
Handle g_hProtectTimer[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name        = "[Chogan] DeathMatch",
	author      = "Chogan build (autonomous run)",
	description = "CS:S deathmatch: single respawn authority, spawn protection, loadout",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/Shadow-Reza/CsSource"
};

/* ------------------------------------------------------------------------- */
/* lifecycle                                                                  */
/* ------------------------------------------------------------------------- */

public void OnPluginStart()
{
	CreateConVar("cg_dm_version", PLUGIN_VERSION, "Chogan deathmatch plugin version",
		FCVAR_NOTIFY | FCVAR_DONTRECORD | FCVAR_SPONLY);

	g_cvEnabled = CreateConVar("cg_dm_enabled", "1",
		"Master switch: 1 = respawn + loadout + protection active, 0 = plugin idle",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvRespawnDelay = CreateConVar("cg_dm_respawn_delay", "2.0",
		"Seconds after death before the victim is respawned",
		FCVAR_NONE, true, 0.0, true, 30.0);
	g_cvHealth = CreateConVar("cg_dm_health", "100",
		"Health given on spawn", FCVAR_NONE, true, 1.0, true, 1000.0);
	g_cvArmor = CreateConVar("cg_dm_armor", "100",
		"Armor given on spawn (helmet is always granted when armor > 0)",
		FCVAR_NONE, true, 0.0, true, 255.0);
	g_cvProtect = CreateConVar("cg_dm_protect", "2.0",
		"Spawn-protection seconds: player is semi-transparent and immune to damage",
		FCVAR_NONE, true, 0.0, true, 30.0);
	g_cvProtectAlpha = CreateConVar("cg_dm_protect_alpha", "160",
		"Render alpha (0-255) while spawn-protected (lower = more transparent)",
		FCVAR_NONE, true, 0.0, true, 255.0);
	g_cvFullAmmo = CreateConVar("cg_dm_full_ammo", "1",
		"1 = refill clip + reserve ammo of the primary/secondary weapon on spawn",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvMode = CreateConVar("cg_dm_mode", "0",
		"0 = buy DM (keep default loadout, players buy with cg_dm_money), 1 = give cg_dm_weapons on spawn",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvWeapons = CreateConVar("cg_dm_weapons", "weapon_m4a1,weapon_deagle",
		"Mode 1 only: comma-separated weapon_ classnames granted on spawn (primary+secondary are stripped first)");
	g_cvMoney = CreateConVar("cg_dm_money", "16000",
		"Money set on spawn (lets players buy in mode 0; harmless in mode 1)",
		FCVAR_NONE, true, 0.0, true, 65535.0);
	g_cvAntiStuck = CreateConVar("cg_dm_antistuck", "1",
		"1 = nudge a freshly respawned player UP a little if another player is within 40u (anti-telefrag)",
		FCVAR_NONE, true, 0.0, true, 1.0);

	RegAdminCmd("sm_dm", Cmd_DM, ADMFLAG_GENERIC,
		"sm_dm - print Chogan deathmatch status (mode, cvars, round state, live/protected counts)");

	HookEvent("player_death", Event_PlayerDeath);
	HookEvent("player_spawn", Event_PlayerSpawn);
	HookEvent("round_start",  Event_RoundStart);
	HookEvent("round_end",    Event_RoundEnd);

	AutoExecConfig(true, "chogan_dm");

	/* late load: hook and clear every already-connected client */
	for (int i = 1; i <= MaxClients; i++)
	{
		ResetSlot(i);
		if (IsClientInGame(i))
			HookClient(i);
	}

	LogMessage("%s v%s loaded (sole respawn authority)", DM_TAG, PLUGIN_VERSION);
}

public void OnPluginEnd()
{
	/* undo everything we changed so a reload/unload leaves no ghost state */
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			if (g_bProtected[i])
				RestoreRender(i);
			UnhookClient(i);
		}
		ResetSlot(i);
	}
}

public void OnMapStart()
{
	g_bRoundEnded = false;
}

public void OnConfigsExecuted()
{
	/* CS:S base game has no engine warmup period. Detect the CS:GO-style
	 * m_bWarmupPeriod prop SAFELY (FindSendPropInfo returns -1 and never errors
	 * if the class/prop is absent) so a warmup-capable build is still honoured,
	 * while base CS:S simply never treats anything as warmup. */
	g_bHasWarmupProp = (FindSendPropInfo("CCSGameRules", "m_bWarmupPeriod") != -1);
}

public void OnClientPutInServer(int client)
{
	ResetSlot(client);
	HookClient(client);
}

public void OnClientDisconnect(int client)
{
	if (g_bProtected[client] && IsClientInGame(client))
		RestoreRender(client);
	UnhookClient(client);
	delete g_hRespawnTimer[client];   /* delete nulls the var; ResetSlot then no-ops */
	delete g_hProtectTimer[client];
	ResetSlot(client);
}

/* ------------------------------------------------------------------------- */
/* events                                                                     */
/* ------------------------------------------------------------------------- */

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundEnded = false;
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	g_bRoundEnded = true;
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue)
		return;

	int victim = GetClientOfUserId(event.GetInt("userid"));
	if (victim < 1 || victim > MaxClients || !IsClientInGame(victim))
		return;

	/* a corpse is neither protected nor mid-respawn any more */
	ClearProtection(victim);

	if (g_bRoundEnded || IsWarmup())
		return;

	int team = GetClientTeam(victim);
	if (team != CS_TEAM_T && team != CS_TEAM_CT)
		return;

	float delay = g_cvRespawnDelay.FloatValue;
	if (delay < 0.0)
		delay = 0.0;

	/* one pending respawn per client; the serial is resolved in the callback so
	 * a reused slot (MISSION §4.5) can never respawn the wrong player. */
	delete g_hRespawnTimer[victim];
	g_hRespawnTimer[victim] = CreateTimer(delay, Timer_Respawn, GetClientSerial(victim),
		TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Respawn(Handle timer, int serial)
{
	int client = GetClientFromSerial(serial);
	if (client >= 1 && client <= MaxClients)
		g_hRespawnTimer[client] = null;

	if (client == 0 || !IsClientInGame(client))
		return Plugin_Stop;
	if (!g_cvEnabled.BoolValue)
		return Plugin_Stop;
	if (g_bRoundEnded || IsWarmup())
		return Plugin_Stop;
	if (IsPlayerAlive(client))
		return Plugin_Stop;

	int team = GetClientTeam(client);
	if (team != CS_TEAM_T && team != CS_TEAM_CT)
		return Plugin_Stop;

	CS_RespawnPlayer(client);
	return Plugin_Stop;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue)
		return;

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return;
	if (!IsPlayerAlive(client))
		return;

	int team = GetClientTeam(client);
	if (team != CS_TEAM_T && team != CS_TEAM_CT)
		return;

	/* Arm protection immediately so the very first frame after spawn is already
	 * covered; the rest of the loadout is applied next frame, after the engine's
	 * own spawn equip has finished (otherwise the game overwrites our changes). */
	StartProtection(client);
	RequestFrame(Frame_ApplyLoadout, GetClientSerial(client));
}

/* ------------------------------------------------------------------------- */
/* loadout (next frame after spawn)                                           */
/* ------------------------------------------------------------------------- */

public void Frame_ApplyLoadout(any data)
{
	int client = GetClientFromSerial(data);
	if (client == 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
		return;

	int team = GetClientTeam(client);
	if (team != CS_TEAM_T && team != CS_TEAM_CT)
		return;

	/* health */
	int hp = g_cvHealth.IntValue;
	if (hp < 1)
		hp = 1;
	SetEntityHealth(client, hp);

	/* armor + helmet */
	int armor = g_cvArmor.IntValue;
	if (HasEntProp(client, Prop_Send, "m_ArmorValue"))
		SetEntProp(client, Prop_Send, "m_ArmorValue", armor);
	if (armor > 0 && HasEntProp(client, Prop_Send, "m_bHasHelmet"))
		SetEntProp(client, Prop_Send, "m_bHasHelmet", 1);

	/* money for buying */
	if (HasEntProp(client, Prop_Send, "m_iAccount"))
		SetEntProp(client, Prop_Send, "m_iAccount", g_cvMoney.IntValue);

	/* mode 1: fixed weapon set (strip primary+secondary, keep knife/nades) */
	if (g_cvMode.IntValue == 1)
	{
		StripSlot(client, CS_SLOT_PRIMARY);
		StripSlot(client, CS_SLOT_SECONDARY);
		GiveWeaponSet(client);
	}

	/* full ammo (after weapons exist) */
	if (g_cvFullAmmo.BoolValue)
	{
		FillSlotAmmo(client, CS_SLOT_PRIMARY);
		FillSlotAmmo(client, CS_SLOT_SECONDARY);
	}

	/* anti-telefrag nudge (optional) */
	if (g_cvAntiStuck.BoolValue)
		MaybeAntiStuck(client);
}

/* Strip one weapon slot: remove from the player, then delete the entity so it
 * does not drop on the floor. */
void StripSlot(int client, int slot)
{
	int wep = GetPlayerWeaponSlot(client, slot);
	if (wep > MaxClients && IsValidEntity(wep))
	{
		RemovePlayerItem(client, wep);
		RemoveEntity(wep);
	}
}

/* Parse cg_dm_weapons ("weapon_a,weapon_b,...") and give each. A token missing
 * the weapon_ prefix gets it added, so "m4a1,deagle" also works. */
void GiveWeaponSet(int client)
{
	char buf[256];
	g_cvWeapons.GetString(buf, sizeof(buf));

	char parts[10][40];
	int n = ExplodeString(buf, ",", parts, sizeof(parts), sizeof(parts[]));
	for (int i = 0; i < n; i++)
	{
		TrimString(parts[i]);
		if (parts[i][0] == '\0')
			continue;

		char cls[48];
		if (StrContains(parts[i], "weapon_") == 0)
			strcopy(cls, sizeof(cls), parts[i]);
		else
			Format(cls, sizeof(cls), "weapon_%s", parts[i]);

		GivePlayerItem(client, cls);
	}
}

/* Refill the clip and the reserve ammo of the weapon in one slot, using only
 * netprops (no gamedata). Grenade counts are left untouched on purpose. */
void FillSlotAmmo(int client, int slot)
{
	int wep = GetPlayerWeaponSlot(client, slot);
	if (wep <= MaxClients || !IsValidEntity(wep))
		return;

	if (HasEntProp(wep, Prop_Send, "m_iClip1"))
		SetEntProp(wep, Prop_Send, "m_iClip1", DM_FILL_CLIP);

	if (!HasEntProp(wep, Prop_Send, "m_iPrimaryAmmoType") ||
	    !HasEntProp(client, Prop_Send, "m_iAmmo"))
		return;

	int ammoType = GetEntProp(wep, Prop_Send, "m_iPrimaryAmmoType");
	int size = GetEntPropArraySize(client, Prop_Send, "m_iAmmo");
	if (ammoType >= 0 && ammoType < size)
		SetEntProp(client, Prop_Send, "m_iAmmo", DM_FILL_RESERVE, _, ammoType);
}

/* ------------------------------------------------------------------------- */
/* spawn protection                                                           */
/* ------------------------------------------------------------------------- */

void StartProtection(int client)
{
	float secs = g_cvProtect.FloatValue;

	/* cancel any protection left over from a previous life on this slot */
	delete g_hProtectTimer[client];

	if (secs <= 0.0)
	{
		g_bProtected[client] = false;
		RestoreRender(client);
		return;
	}

	g_bProtected[client] = true;

	int a = g_cvProtectAlpha.IntValue;
	SetEntityRenderMode(client, RENDER_TRANSCOLOR);
	SetEntityRenderColor(client, 255, 255, 255, a);

	g_hProtectTimer[client] = CreateTimer(secs, Timer_EndProtect, GetClientSerial(client),
		TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_EndProtect(Handle timer, int serial)
{
	int client = GetClientFromSerial(serial);
	if (client >= 1 && client <= MaxClients)
		g_hProtectTimer[client] = null;

	if (client == 0 || !IsClientInGame(client))
		return Plugin_Stop;

	g_bProtected[client] = false;
	RestoreRender(client);
	return Plugin_Stop;
}

/* god mode while protected: block ALL incoming damage. */
public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage,
	int &damagetype)
{
	if (victim >= 1 && victim <= MaxClients && g_bProtected[victim])
		return Plugin_Handled;
	return Plugin_Continue;
}

void RestoreRender(int client)
{
	SetEntityRenderMode(client, RENDER_NORMAL);
	SetEntityRenderColor(client, 255, 255, 255, 255);
}

/* clear protection state on death/disconnect without leaving a body transparent */
void ClearProtection(int client)
{
	delete g_hProtectTimer[client];
	if (g_bProtected[client])
	{
		g_bProtected[client] = false;
		if (IsClientInGame(client))
			RestoreRender(client);
	}
}

/* ------------------------------------------------------------------------- */
/* anti-telefrag                                                              */
/* ------------------------------------------------------------------------- */

/* CS_RespawnPlayer places the player on a real map spawn point, and the engine
 * usually spreads players across spawn points, so genuine origin overlap is
 * rare. When it does happen (few spawn points, many players) we only ever nudge
 * the player UPWARD: a horizontal nudge could shove them into a wall or off the
 * map, which is worse than a brief telefrag. Vertical stacking lets the engine
 * settle them on the next physics tick. This is deliberately minimal (MISSION
 * §6.5 marks it optional). */
void MaybeAntiStuck(int client)
{
	float me[3];
	GetEntPropVector(client, Prop_Send, "m_vecOrigin", me);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (i == client || !IsClientInGame(i) || !IsPlayerAlive(i))
			continue;
		int team = GetClientTeam(i);
		if (team != CS_TEAM_T && team != CS_TEAM_CT)
			continue;

		float other[3];
		GetEntPropVector(i, Prop_Send, "m_vecOrigin", other);
		if (GetVectorDistance(me, other) < DM_STUCK_DIST)
		{
			me[2] += DM_STUCK_NUDGE;
			TeleportEntity(client, me, NULL_VECTOR, NULL_VECTOR);
			return;
		}
	}
}

/* ------------------------------------------------------------------------- */
/* helpers                                                                    */
/* ------------------------------------------------------------------------- */

void HookClient(int client)
{
	if (!g_bHooked[client])
	{
		SDKHook(client, SDKHook_OnTakeDamage, OnTakeDamage);
		g_bHooked[client] = true;
	}
}

void UnhookClient(int client)
{
	if (g_bHooked[client])
	{
		SDKUnhook(client, SDKHook_OnTakeDamage, OnTakeDamage);
		g_bHooked[client] = false;
	}
}

void ResetSlot(int client)
{
	g_bProtected[client]   = false;
	g_bHooked[client]      = false;
	g_hRespawnTimer[client] = null;
	g_hProtectTimer[client] = null;
}

bool IsWarmup()
{
	if (!g_bHasWarmupProp)
		return false;
	return GameRules_GetProp("m_bWarmupPeriod") != 0;
}

/* ------------------------------------------------------------------------- */
/* admin command                                                              */
/* ------------------------------------------------------------------------- */

public Action Cmd_DM(int client, int args)
{
	int alive = 0, prot = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
			continue;
		if (IsPlayerAlive(i))
			alive++;
		if (g_bProtected[i])
			prot++;
	}

	char weapons[256];
	g_cvWeapons.GetString(weapons, sizeof(weapons));

	ReplyToCommand(client, "%s v%s - SOLE respawn authority on this server", DM_TAG, PLUGIN_VERSION);
	ReplyToCommand(client, "  enabled=%d  round=%s  warmup=%s",
		g_cvEnabled.IntValue, g_bRoundEnded ? "ENDED" : "live", IsWarmup() ? "yes" : "no");
	ReplyToCommand(client, "  respawn_delay=%.1f  health=%d  armor=%d  money=%d",
		g_cvRespawnDelay.FloatValue, g_cvHealth.IntValue, g_cvArmor.IntValue, g_cvMoney.IntValue);
	ReplyToCommand(client, "  protect=%.1fs alpha=%d  full_ammo=%d  antistuck=%d",
		g_cvProtect.FloatValue, g_cvProtectAlpha.IntValue, g_cvFullAmmo.IntValue, g_cvAntiStuck.IntValue);
	ReplyToCommand(client, "  mode=%d (%s)%s%s",
		g_cvMode.IntValue,
		g_cvMode.IntValue == 1 ? "give weapon set" : "buy DM",
		g_cvMode.IntValue == 1 ? "  weapons=" : "",
		g_cvMode.IntValue == 1 ? weapons : "");
	ReplyToCommand(client, "  players: %d alive, %d protected", alive, prot);
	return Plugin_Handled;
}
