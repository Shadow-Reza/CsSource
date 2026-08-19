/**
 * probe_setinfo.sp — MISSION §5 probe 1.
 *
 * Question: on a client, `setinfo lt hello` then `connect`. Can the server read
 * GetClientInfo(client, "lt", ...) — and at which forward does the value first
 * become visible?
 *
 * This probe NEVER kicks. It logs (LogMessage + PrintToServer) the value of the
 * `lt` userinfo key at every client lifecycle stage:
 *   OnClientConnect (pre), OnClientConnected, OnClientAuthorized,
 *   OnClientPutInServer, OnClientPostAdminCheck, OnClientSettingsChanged (with a per-connection counter),
 *   and 1.0 s after OnClientConnected (timer, resolved via client serial).
 * plus GetClientAuthId for Steam2/Steam3/Engine and the IP, and two control keys
 * (`name`, `cl_language`, `rate`) so a missing `lt` can be told apart from
 * "no userinfo at all at this stage".
 *
 * Fallback branch (b) of probe 1: a console command `cg_ticket <token>` that
 * the launcher could fire right after connect. It is registered here so the same
 * probe session can test both channels.
 *
 * On OnClientConnected a "grace" timer (cvar probe_grace, default 8.0 s) is
 * armed; when it fires it logs whether *any* lt / cg_ticket was seen for that
 * client, and where it was seen first. Nothing is enforced.
 *
 * Log lines are prefixed "[probe1]" so they can be grepped out of
 * addons/sourcemod/logs/L*.log and the console log for docs/probes.md.
 *
 * SourceMod 1.12. Compile: spcomp probe_setinfo.sp
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "0.1.0"
#define LT_MAX 300   /* userinfo values are capped at 260 bytes on Source (MISSION §3) */

public Plugin myinfo =
{
	name        = "[Chogan] Probe 1: setinfo lt visibility",
	author      = "Chogan build (autonomous run)",
	description = "Logs GetClientInfo(client,\"lt\") at every client lifecycle stage; never kicks",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/Shadow-Reza/CsSource"
};

ConVar g_cvGrace;

bool   g_bSeenLt[MAXPLAYERS + 1];
bool   g_bSeenCmd[MAXPLAYERS + 1];
char   g_sFirstStage[MAXPLAYERS + 1][32];
char   g_sFirstValue[MAXPLAYERS + 1][LT_MAX];
float  g_fConnectedAt[MAXPLAYERS + 1];
Handle g_hGrace[MAXPLAYERS + 1];
Handle g_hOneSec[MAXPLAYERS + 1];
int    g_iSettingsChanges[MAXPLAYERS + 1];   /* OnClientSettingsChanged counter per connection */

/* ---------------------------------------------------------------------------- */

public void OnPluginStart()
{
	g_cvGrace = CreateConVar("probe_grace", "8.0",
		"Seconds after OnClientConnected before the probe logs whether any lt/cg_ticket was seen (no kick).",
		FCVAR_NONE, true, 1.0, true, 120.0);

	RegConsoleCmd("cg_ticket", Cmd_Ticket,
		"Probe 1 fallback (b): client presents its ticket by console command: cg_ticket <token>");
	RegAdminCmd("sm_probe_setinfo", Cmd_Dump, ADMFLAG_GENERIC,
		"Dump the lt userinfo key (and auth ids) of every connected client right now");

	for (int i = 1; i <= MaxClients; i++)
	{
		ResetClient(i);
	}

	PLog("plugin loaded v%s — probe_grace=%.1f (edit with the cvar). Waiting for clients.",
		PLUGIN_VERSION, g_cvGrace.FloatValue);
}

public void OnPluginEnd()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		delete g_hGrace[i];
		delete g_hOneSec[i];
	}
}

/* ---------------------------------------------------------------------------- */
/* lifecycle forwards                                                            */

public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
	/* SM has already Initialize()d the CPlayer at this point, so GetClientInfo is
	 * legal (IsClientConnected() is true). Whether the engine already holds the
	 * userinfo this early is exactly what we are measuring. */
	ResetClient(client);
	Probe(client, "OnClientConnect");
	return true; /* never reject */
}

public void OnClientConnected(int client)
{
	g_fConnectedAt[client] = GetEngineTime();
	Probe(client, "OnClientConnected");

	if (IsFakeClient(client))
	{
		return; /* bots: nothing to wait for */
	}

	int serial = GetClientSerial(client);

	delete g_hOneSec[client];
	g_hOneSec[client] = CreateTimer(1.0, Timer_OneSec, serial);

	delete g_hGrace[client];
	g_hGrace[client] = CreateTimer(g_cvGrace.FloatValue, Timer_Grace, serial);
}

public void OnClientAuthorized(int client, const char[] auth)
{
	char stage[64];
	FormatEx(stage, sizeof(stage), "OnClientAuthorized(auth=%s)", auth);
	Probe(client, stage);
}

public void OnClientPutInServer(int client)
{
	Probe(client, "OnClientPutInServer");
}

public void OnClientPostAdminCheck(int client)
{
	Probe(client, "OnClientPostAdminCheck");
}

public void OnClientSettingsChanged(int client)
{
	/* The first call is expected right after the client's initial net_SetConVar
	 * batch (docs/source-connect-protocol.md §3) — i.e. the first moment `lt` can
	 * exist. The counter tells the first batch apart from later name/rate changes. */
	if (client < 1 || client > MaxClients)
	{
		return;
	}
	g_iSettingsChanges[client]++;
	char stage[48];
	FormatEx(stage, sizeof(stage), "OnClientSettingsChanged#%d", g_iSettingsChanges[client]);
	Probe(client, stage);
}

public void OnClientDisconnect(int client)
{
	if (client >= 1 && client <= MaxClients && IsClientConnected(client) && !IsFakeClient(client))
	{
		char first[32];
		strcopy(first, sizeof(first), g_sFirstStage[client]);
		if (first[0] == '\0')
		{
			strcopy(first, sizeof(first), "(none)");
		}
		PLog("client=%d disconnect: seen_lt=%d seen_cmd=%d first_stage=%s",
			client, g_bSeenLt[client], g_bSeenCmd[client], first);
	}
	ResetClient(client);
}

/* ---------------------------------------------------------------------------- */
/* timers (client serial across the async boundary — MISSION §4.5)              */

public Action Timer_OneSec(Handle timer, any serial)
{
	int client = GetClientFromSerial(serial);
	if (client > 0)
	{
		g_hOneSec[client] = null;
		Probe(client, "T+1.0s after OnClientConnected");
	}
	return Plugin_Stop;
}

public Action Timer_Grace(Handle timer, any serial)
{
	int client = GetClientFromSerial(serial);
	if (client <= 0)
	{
		return Plugin_Stop; /* client left before the grace period ended */
	}
	g_hGrace[client] = null;

	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));

	Probe(client, "grace-expired");

	if (g_bSeenLt[client] || g_bSeenCmd[client])
	{
		PLog("GRACE RESULT client=%d name=\"%s\": TICKET SEEN — via_setinfo_lt=%d via_cg_ticket_cmd=%d first_stage=%s first_value=\"%s\" (no kick: probe only)",
			client, name, g_bSeenLt[client], g_bSeenCmd[client], g_sFirstStage[client], g_sFirstValue[client]);
	}
	else
	{
		PLog("GRACE RESULT client=%d name=\"%s\": NO TICKET SEEN within %.1fs — neither setinfo lt nor cg_ticket (no kick: probe only)",
			client, name, g_cvGrace.FloatValue);
	}
	return Plugin_Stop;
}

/* ---------------------------------------------------------------------------- */
/* commands                                                                     */

public Action Cmd_Ticket(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[probe1] cg_ticket is a client command.");
		return Plugin_Handled;
	}
	if (!IsClientConnected(client))
	{
		return Plugin_Handled;
	}

	char token[LT_MAX];
	if (args >= 1)
	{
		GetCmdArg(1, token, sizeof(token));
	}

	float dt = (g_fConnectedAt[client] > 0.0) ? (GetEngineTime() - g_fConnectedAt[client]) : -1.0;

	PLog("cg_ticket command client=%d serial=%d ingame=%d dt_since_connected=%.3fs token_len=%d token=\"%s\"",
		client, GetClientSerial(client), IsClientInGame(client), dt, strlen(token), token);

	if (token[0] != '\0')
	{
		g_bSeenCmd[client] = true;
		if (g_sFirstStage[client][0] == '\0')
		{
			strcopy(g_sFirstStage[client], sizeof(g_sFirstStage[]), "cg_ticket-cmd");
			strcopy(g_sFirstValue[client], sizeof(g_sFirstValue[]), token);
		}
	}

	ReplyToCommand(client, "[probe1] ticket received (%d bytes). Nothing is enforced by the probe.", strlen(token));
	return Plugin_Handled;
}

public Action Cmd_Dump(int client, int args)
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			Probe(i, "sm_probe_setinfo");
			n++;
		}
	}
	ReplyToCommand(client, "[probe1] dumped %d connected client(s) to the log / server console.", n);
	return Plugin_Handled;
}

/* ---------------------------------------------------------------------------- */
/* the actual measurement                                                       */

void Probe(int client, const char[] stage)
{
	if (client < 1 || client > MaxClients)
	{
		return;
	}
	if (!IsClientConnected(client))
	{
		PLog("stage=%s client=%d: not connected (skipped)", stage, client);
		return;
	}

	char lt[LT_MAX];
	bool ok = GetClientInfo(client, "lt", lt, sizeof(lt));

	/* control keys: if these are empty too, the engine simply has no userinfo yet */
	char uiName[MAX_NAME_LENGTH], uiLang[32], uiRate[16];
	GetClientInfo(client, "name", uiName, sizeof(uiName));
	GetClientInfo(client, "cl_language", uiLang, sizeof(uiLang));
	GetClientInfo(client, "rate", uiRate, sizeof(uiRate));

	char ip[64];
	if (!GetClientIP(client, ip, sizeof(ip)))
	{
		strcopy(ip, sizeof(ip), "(n/a)");
	}

	/* GetClientAuthId returns false (and fills a sentinel string) while the client
	 * is not yet authorized — check the bool, never trust the buffer alone. */
	char s2[64], s3[64], eng[64];
	if (!GetClientAuthId(client, AuthId_Steam2, s2, sizeof(s2)))  strcopy(s2, sizeof(s2), "(n/a)");
	if (!GetClientAuthId(client, AuthId_Steam3, s3, sizeof(s3)))  strcopy(s3, sizeof(s3), "(n/a)");
	if (!GetClientAuthId(client, AuthId_Engine, eng, sizeof(eng))) strcopy(eng, sizeof(eng), "(n/a)");

	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));

	float dt = (g_fConnectedAt[client] > 0.0) ? (GetEngineTime() - g_fConnectedAt[client]) : -1.0;

	PLog("stage=%s client=%d serial=%d name=\"%s\" ip=%s fake=%d ingame=%d authorized=%d dt=%.3fs | lt_ok=%d lt_len=%d lt=\"%s\" | ctrl name=\"%s\" cl_language=\"%s\" rate=\"%s\" | steam2=%s steam3=%s engine=%s",
		stage, client, GetClientSerial(client), name, ip,
		IsFakeClient(client), IsClientInGame(client), IsClientAuthorized(client), dt,
		ok, strlen(lt), lt, uiName, uiLang, uiRate, s2, s3, eng);

	if (ok && lt[0] != '\0')
	{
		if (!g_bSeenLt[client])
		{
			g_bSeenLt[client] = true;
			PLog("FIRST SIGHTING of lt for client=%d at stage=%s (dt=%.3fs)", client, stage, dt);
		}
		if (g_sFirstStage[client][0] == '\0')
		{
			strcopy(g_sFirstStage[client], sizeof(g_sFirstStage[]), stage);
			strcopy(g_sFirstValue[client], sizeof(g_sFirstValue[]), lt);
		}
	}
}

/* ---------------------------------------------------------------------------- */
/* helpers                                                                      */

void ResetClient(int client)
{
	g_bSeenLt[client] = false;
	g_bSeenCmd[client] = false;
	g_sFirstStage[client][0] = '\0';
	g_sFirstValue[client][0] = '\0';
	g_fConnectedAt[client] = 0.0;
	g_iSettingsChanges[client] = 0;
	delete g_hGrace[client];
	delete g_hOneSec[client];
}

/** Log to SM's log file AND the server console (the console log is what we grep). */
void PLog(const char[] fmt, any ...)
{
	char buf[1400];
	VFormat(buf, sizeof(buf), fmt, 2);
	LogMessage("[probe1] %s", buf);
	PrintToServer("[probe1] %s", buf);
}
