/**
 * chogan_weaponrestrict.sp - Counter-Strike: Source weapon restriction (Chogan, MISSION 6.5).
 *
 * CS:S has no cvar-driven weapon restriction (unlike CS 1.6), so this plugin enforces it three ways:
 *   1. CS_OnBuyCommand  - blocks buying a forbidden weapon (with a chat notice).
 *   2. SDKHook_WeaponCanUse - blocks equipping a forbidden weapon that was picked up off the ground.
 *   3. player_spawn (next frame) - strips any forbidden weapon the default loadout gave, and (optionally)
 *      gives the configured allow set with full ammo. Used on the AimAwp server to force AWP + knife.
 *
 * The knife is ALWAYS allowed and never stripped. Everything is netprop/CS-native based (no SDKCall,
 * no gamedata) so it is unaffected by the v92 gamedata trap (MISSION 4.1). Late-load safe; serial-guarded
 * timers/frames (MISSION 4.5).
 *
 * Modes (cg_wr_mode): 0 = off, 1 = allowlist (only cg_wr_allow usable), 2 = blocklist (cg_wr_block forbidden).
 * Default 1 with allow = "weapon_awp,weapon_knife" for the AimAwp instance.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

#define PLUGIN_VERSION "0.1.0"
#define WR_TAG         "[chogan_wr]"
#define WR_MAXLIST     32
#define WR_NAMELEN     32
#define WR_FILL_CLIP   30
#define WR_FILL_RESV   90

ConVar g_cvEnabled;
ConVar g_cvMode;          /* 0 off / 1 allowlist / 2 blocklist */
ConVar g_cvAllow;
ConVar g_cvBlock;
ConVar g_cvGive;
ConVar g_cvRefillAmmo;

char   g_sAllow[WR_MAXLIST][WR_NAMELEN];
int    g_iAllowCount;
char   g_sBlock[WR_MAXLIST][WR_NAMELEN];
int    g_iBlockCount;
char   g_sGive[WR_MAXLIST][WR_NAMELEN];
int    g_iGiveCount;

int    g_iViolations[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name        = "[Chogan] Weapon Restrict",
	author      = "Chogan build (autonomous run)",
	description  = "CS:S allow/block-list weapon restriction (buy + pickup + spawn loadout)",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/Shadow-Reza/CsSource"
};

public void OnPluginStart()
{
	CreateConVar("cg_wr_version", PLUGIN_VERSION, "chogan_weaponrestrict version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvEnabled = CreateConVar("cg_wr_enabled", "1", "Master switch (0 = plugin idle)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_cvMode    = CreateConVar("cg_wr_mode", "1", "0 = off, 1 = allowlist (only cg_wr_allow usable), 2 = blocklist (cg_wr_block forbidden)", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	g_cvAllow   = CreateConVar("cg_wr_allow", "weapon_awp,weapon_knife", "Allowlist (comma list of weapon_ classnames), used when cg_wr_mode 1", FCVAR_NOTIFY);
	g_cvBlock   = CreateConVar("cg_wr_block", "", "Blocklist (comma list), used when cg_wr_mode 2", FCVAR_NOTIFY);
	g_cvGive    = CreateConVar("cg_wr_give", "weapon_awp,weapon_knife", "Weapons to give on spawn (comma list; empty = do not force-give)", FCVAR_NOTIFY);
	g_cvRefillAmmo = CreateConVar("cg_wr_refill_ammo", "1", "Top up the allowed weapon's ammo on spawn", FCVAR_NOTIFY, true, 0.0, true, 1.0);

	g_cvAllow.AddChangeHook(OnListChanged);
	g_cvBlock.AddChangeHook(OnListChanged);
	g_cvGive.AddChangeHook(OnListChanged);

	RegAdminCmd("sm_wr", Cmd_Wr, ADMFLAG_GENERIC, "Show the current weapon-restriction policy and violation counts");

	HookEvent("player_spawn", Event_PlayerSpawn);

	ParseLists();
	AutoExecConfig(true, "chogan_weaponrestrict");

	/* late load: hook already-connected clients */
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			OnClientPutInServer(i);
		}
	}
}

public void OnConfigsExecuted()
{
	ParseLists();
}

public void OnListChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ParseLists();
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_WeaponCanUse, Hook_WeaponCanUse);
}

public void OnClientDisconnect(int client)
{
	g_iViolations[client] = 0;
}

/* ------------------------------------------------------------------ list parsing */

void ParseLists()
{
	char buf[512];
	g_cvAllow.GetString(buf, sizeof(buf));
	g_iAllowCount = SplitList(buf, g_sAllow);
	g_cvBlock.GetString(buf, sizeof(buf));
	g_iBlockCount = SplitList(buf, g_sBlock);
	g_cvGive.GetString(buf, sizeof(buf));
	g_iGiveCount = SplitList(buf, g_sGive);
}

int SplitList(const char[] csv, char list[WR_MAXLIST][WR_NAMELEN])
{
	int count = 0;
	int start = 0;
	int len = strlen(csv);
	char item[WR_NAMELEN];
	for (int i = 0; i <= len && count < WR_MAXLIST; i++)
	{
		if (i == len || csv[i] == ',')
		{
			int n = i - start;
			if (n > 0)
			{
				if (n >= WR_NAMELEN) n = WR_NAMELEN - 1;
				strcopy(item, n + 1, csv[start]);
				TrimString(item);
				if (item[0] != '\0')
				{
					Normalize(item, list[count], WR_NAMELEN);
					count++;
				}
			}
			start = i + 1;
		}
	}
	return count;
}

/* ensure a leading "weapon_" prefix */
void Normalize(const char[] in_name, char[] out, int maxlen)
{
	if (StrContains(in_name, "weapon_") == 0)
	{
		strcopy(out, maxlen, in_name);
	}
	else
	{
		Format(out, maxlen, "weapon_%s", in_name);
	}
}

bool InList(const char[] classname, const char[][] list, int count)
{
	char norm[WR_NAMELEN];
	Normalize(classname, norm, sizeof(norm));
	for (int i = 0; i < count; i++)
	{
		if (StrEqual(norm, list[i], false))
		{
			return true;
		}
	}
	return false;
}

/* is this weapon allowed to be used/bought under the current policy? knife always allowed. */
bool IsWeaponAllowed(const char[] classname)
{
	char norm[WR_NAMELEN];
	Normalize(classname, norm, sizeof(norm));
	if (StrEqual(norm, "weapon_knife", false))
	{
		return true;
	}
	int mode = g_cvMode.IntValue;
	if (mode == 0)
	{
		return true;
	}
	if (mode == 1)
	{
		return InList(norm, g_sAllow, g_iAllowCount);
	}
	/* mode 2: blocklist */
	return !InList(norm, g_sBlock, g_iBlockCount);
}

/* ------------------------------------------------------------------ enforcement */

public Action CS_OnBuyCommand(int client, const char[] weapon)
{
	if (!g_cvEnabled.BoolValue || g_cvMode.IntValue == 0)
	{
		return Plugin_Continue;
	}
	if (!IsWeaponAllowed(weapon))
	{
		g_iViolations[client]++;
		PrintToChat(client, "\x04[Chogan]\x01 %s is restricted on this server.", weapon);
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public Action Hook_WeaponCanUse(int client, int weapon)
{
	if (!g_cvEnabled.BoolValue || g_cvMode.IntValue == 0)
	{
		return Plugin_Continue;
	}
	if (!IsValidEntity(weapon))
	{
		return Plugin_Continue;
	}
	char classname[WR_NAMELEN];
	GetEntityClassname(weapon, classname, sizeof(classname));
	if (!IsWeaponAllowed(classname))
	{
		return Plugin_Handled;
	}
	return Plugin_Continue;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if (!g_cvEnabled.BoolValue || g_cvMode.IntValue == 0)
	{
		return;
	}
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return;
	}
	/* apply on the next frame so the engine's own spawn-equip has finished */
	RequestFrame(Frame_ApplyLoadout, GetClientSerial(client));
}

public void Frame_ApplyLoadout(any serial)
{
	int client = GetClientFromSerial(serial);
	if (client <= 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return;
	}

	/* strip forbidden weapons from every weapon slot (never the knife) */
	for (int slot = 0; slot <= 4; slot++)
	{
		int wep = GetPlayerWeaponSlot(client, slot);
		if (wep == -1 || !IsValidEntity(wep))
		{
			continue;
		}
		char classname[WR_NAMELEN];
		GetEntityClassname(wep, classname, sizeof(classname));
		if (StrEqual(classname, "weapon_knife", false))
		{
			continue;
		}
		if (!IsWeaponAllowed(classname))
		{
			RemovePlayerItem(client, wep);
			RemoveEntity(wep);
		}
	}

	/* force-give the configured set (e.g. AWP + knife on aim maps) */
	if (g_iGiveCount > 0)
	{
		for (int i = 0; i < g_iGiveCount; i++)
		{
			/* only give if allowed under the policy and not already held */
			if (!IsWeaponAllowed(g_sGive[i]))
			{
				continue;
			}
			if (!HasWeapon(client, g_sGive[i]))
			{
				GivePlayerItem(client, g_sGive[i]);
			}
		}
	}

	if (g_cvRefillAmmo.BoolValue)
	{
		RefillAllowedAmmo(client);
	}
}

bool HasWeapon(int client, const char[] classname)
{
	char norm[WR_NAMELEN];
	Normalize(classname, norm, sizeof(norm));
	for (int slot = 0; slot <= 4; slot++)
	{
		int wep = GetPlayerWeaponSlot(client, slot);
		if (wep == -1 || !IsValidEntity(wep))
		{
			continue;
		}
		char cn[WR_NAMELEN];
		GetEntityClassname(wep, cn, sizeof(cn));
		if (StrEqual(cn, norm, false))
		{
			return true;
		}
	}
	return false;
}

void RefillAllowedAmmo(int client)
{
	for (int slot = 0; slot <= 1; slot++)   /* primary + secondary */
	{
		int wep = GetPlayerWeaponSlot(client, slot);
		if (wep == -1 || !IsValidEntity(wep))
		{
			continue;
		}
		char classname[WR_NAMELEN];
		GetEntityClassname(wep, classname, sizeof(classname));
		if (StrEqual(classname, "weapon_knife", false) || !IsWeaponAllowed(classname))
		{
			continue;
		}
		SetEntProp(wep, Prop_Send, "m_iClip1", WR_FILL_CLIP);
		int ammoType = GetEntProp(wep, Prop_Send, "m_iPrimaryAmmoType");
		if (ammoType >= 0)
		{
			SetEntProp(client, Prop_Send, "m_iAmmo", WR_FILL_RESV, _, ammoType);
		}
	}
}

/* ------------------------------------------------------------------ admin cmd */

public Action Cmd_Wr(int client, int args)
{
	char modeStr[16];
	switch (g_cvMode.IntValue)
	{
		case 0: strcopy(modeStr, sizeof(modeStr), "off");
		case 1: strcopy(modeStr, sizeof(modeStr), "allowlist");
		case 2: strcopy(modeStr, sizeof(modeStr), "blocklist");
	}
	ReplyToCommand(client, "%s mode=%s enabled=%d refill=%d", WR_TAG, modeStr, g_cvEnabled.BoolValue, g_cvRefillAmmo.BoolValue);

	char list[256];
	JoinList(g_sAllow, g_iAllowCount, list, sizeof(list));
	ReplyToCommand(client, "  allow (%d): %s", g_iAllowCount, list);
	JoinList(g_sBlock, g_iBlockCount, list, sizeof(list));
	ReplyToCommand(client, "  block (%d): %s", g_iBlockCount, list);
	JoinList(g_sGive, g_iGiveCount, list, sizeof(list));
	ReplyToCommand(client, "  give-on-spawn (%d): %s", g_iGiveCount, list);

	ReplyToCommand(client, "  violations:");
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && g_iViolations[i] > 0)
		{
			ReplyToCommand(client, "    %N: %d blocked buy attempt(s)", i, g_iViolations[i]);
		}
	}
	return Plugin_Handled;
}

void JoinList(const char[][] list, int count, char[] out, int maxlen)
{
	out[0] = '\0';
	for (int i = 0; i < count; i++)
	{
		if (i > 0)
		{
			StrCat(out, maxlen, ", ");
		}
		StrCat(out, maxlen, list[i]);
	}
	if (count == 0)
	{
		strcopy(out, maxlen, "(none)");
	}
}

public void OnPluginEnd()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			SDKUnhook(i, SDKHook_WeaponCanUse, Hook_WeaponCanUse);
		}
	}
}
