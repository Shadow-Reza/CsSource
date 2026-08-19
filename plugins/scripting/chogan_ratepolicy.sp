/**
 * chogan_ratepolicy.sp — rate policy audit / enforcement (MISSION §4.6).
 *
 * Background: Source-1-Games issue #3812 reports that CS:S server-side rate clamps
 * (sv_minrate/sv_maxrate, sv_min/maxupdaterate, sv_min/maxcmdrate,
 * sv_client_min/max_interp_ratio) are not enforced. Status on v92 is unknown, so the
 * MISSION says: set them, verify whether they bind, and if not, enforce with a plugin.
 *
 * This plugin does both halves of that:
 *   1. AUDIT (always): every cg_rate_interval seconds (default 30) and on every
 *      OnClientSettingsChanged it reads each human client's userinfo
 *      rate / cl_updaterate / cl_cmdrate / cl_interp_ratio / cl_interp and compares
 *      them with the server policy cvars. It also logs what the netchannel actually
 *      does (GetClientAvgPackets out/in = effective update/cmd rate, GetClientAvgData,
 *      GetClientAvgChoke), so the log shows whether the engine clamps or not: a client
 *      claiming cl_updaterate 100 on sv_maxupdaterate 66 that measures ~66 pkt/s is
 *      being clamped; one that measures ~100 is not.
 *   2. ENFORCE (opt-in, cg_rate_enforce 1): warn the client (chat + console) each time
 *      it is found out of policy; after cg_rate_warnings (default 3) warnings, kick.
 *      Compliance resets the warning counter. Default is log-only (0).
 *
 * Admin: sm_ratepolicy            — print the table (claimed vs measured vs policy)
 *        sm_ratepolicy reset      — reset all warning counters
 *
 * Log lines are prefixed "[ratepolicy]".
 *
 * Policy cvars read live (server.cfg per MISSION §6.2): sv_minrate, sv_maxrate (0 = no
 * cap), sv_minupdaterate, sv_maxupdaterate, sv_mincmdrate, sv_maxcmdrate,
 * sv_client_min_interp_ratio (-1 = no limit), sv_client_max_interp_ratio (-1 = no limit).
 * cl_interp itself has no server-side cap; it is logged (and the effective interp
 * max(cl_interp, cl_interp_ratio / cl_updaterate) is shown) but never enforced.
 *
 * SourceMod 1.12.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "0.1.0"
#define RP_TAG "[ratepolicy]"
#define VIOL_MAX 256

public Plugin myinfo =
{
	name        = "[Chogan] Rate policy",
	author      = "Chogan build (autonomous run)",
	description = "Audits client rate/cl_updaterate/cl_cmdrate/cl_interp_ratio against sv_* policy; optional kick after N warnings",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/Shadow-Reza/CsSource"
};

/* our cvars */
ConVar g_cvEnforce;        /* cg_rate_enforce */
ConVar g_cvWarnings;       /* cg_rate_warnings */
ConVar g_cvInterval;       /* cg_rate_interval */
ConVar g_cvChat;           /* cg_rate_chat */
ConVar g_cvLogCompliant;   /* cg_rate_log_compliant */
ConVar g_cvWarnGap;        /* cg_rate_warn_gap */

/* server policy cvars (may be null if the engine lacks one) */
ConVar g_cvMinRate, g_cvMaxRate;
ConVar g_cvMinUpd, g_cvMaxUpd;
ConVar g_cvMinCmd, g_cvMaxCmd;
ConVar g_cvMinRatio, g_cvMaxRatio;

int    g_iWarnings[MAXPLAYERS + 1];
float  g_fLastWarn[MAXPLAYERS + 1];
bool   g_bWasViolating[MAXPLAYERS + 1];
bool   g_bKickQueued[MAXPLAYERS + 1];
Handle g_hTimer = null;
int    g_iSyncDepth = 0;   /* > 0 inside OnClientSettingsChanged: kick via RequestFrame */

/* snapshot of one evaluation, filled by Measure() */
enum struct RateSnap
{
	int   rate;
	int   upd;
	int   cmd;
	float ratio;
	float interp;
	bool  haveRate;
	bool  haveUpd;
	bool  haveCmd;
	bool  haveRatio;
	bool  haveInterp;
	float outPps;
	float inPps;
	float outBps;
	float choke;
	float loss;
	float latency;
}

/* ---------------------------------------------------------------------------- */

public void OnPluginStart()
{
	CreateConVar("cg_rate_version", PLUGIN_VERSION, "Chogan rate policy plugin version",
		FCVAR_NOTIFY | FCVAR_DONTRECORD | FCVAR_SPONLY);

	g_cvEnforce = CreateConVar("cg_rate_enforce", "0",
		"0 = log only (default), 1 = warn and kick after cg_rate_warnings warnings",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvWarnings = CreateConVar("cg_rate_warnings", "3",
		"Warnings before a kick when cg_rate_enforce is 1", FCVAR_NONE, true, 1.0, true, 50.0);
	g_cvInterval = CreateConVar("cg_rate_interval", "30.0",
		"Seconds between periodic checks of every client", FCVAR_NONE, true, 5.0, true, 600.0);
	g_cvChat = CreateConVar("cg_rate_chat", "1",
		"1 = tell the client in chat/console what is out of policy (only when cg_rate_enforce is 1)",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvLogCompliant = CreateConVar("cg_rate_log_compliant", "0",
		"1 = also log compliant clients on every periodic check (evidence for docs/probes.md)",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvWarnGap = CreateConVar("cg_rate_warn_gap", "10.0",
		"Minimum seconds between two warnings for the same client (settings-change storms count once)",
		FCVAR_NONE, true, 1.0, true, 300.0);

	g_cvMinRate  = FindConVar("sv_minrate");
	g_cvMaxRate  = FindConVar("sv_maxrate");
	g_cvMinUpd   = FindConVar("sv_minupdaterate");
	g_cvMaxUpd   = FindConVar("sv_maxupdaterate");
	g_cvMinCmd   = FindConVar("sv_mincmdrate");
	g_cvMaxCmd   = FindConVar("sv_maxcmdrate");
	g_cvMinRatio = FindConVar("sv_client_min_interp_ratio");
	g_cvMaxRatio = FindConVar("sv_client_max_interp_ratio");

	g_cvInterval.AddChangeHook(OnIntervalChanged);

	RegAdminCmd("sm_ratepolicy", Cmd_RatePolicy, ADMFLAG_GENERIC,
		"sm_ratepolicy [reset] - table of claimed vs measured rates vs policy for every client");

	AutoExecConfig(true, "chogan_ratepolicy");

	for (int i = 1; i <= MaxClients; i++)
	{
		ResetClient(i);
	}

	LogMessage("%s v%s loaded (sv_minrate=%s sv_maxrate=%s sv_minupdaterate=%s sv_maxupdaterate=%s sv_mincmdrate=%s sv_maxcmdrate=%s sv_client_min_interp_ratio=%s sv_client_max_interp_ratio=%s)",
		RP_TAG, PLUGIN_VERSION,
		(g_cvMinRate != null) ? "found" : "MISSING", (g_cvMaxRate != null) ? "found" : "MISSING",
		(g_cvMinUpd != null) ? "found" : "MISSING", (g_cvMaxUpd != null) ? "found" : "MISSING",
		(g_cvMinCmd != null) ? "found" : "MISSING", (g_cvMaxCmd != null) ? "found" : "MISSING",
		(g_cvMinRatio != null) ? "found" : "MISSING", (g_cvMaxRatio != null) ? "found" : "MISSING");
}

public void OnConfigsExecuted()
{
	StartTimer();
	LogPolicy("OnConfigsExecuted");
}

public void OnPluginEnd()
{
	delete g_hTimer;
}

public void OnIntervalChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	StartTimer();
}

void StartTimer()
{
	delete g_hTimer;
	g_hTimer = CreateTimer(g_cvInterval.FloatValue, Timer_Check, _, TIMER_REPEAT);
}

/* ---------------------------------------------------------------------------- */
/* client lifecycle                                                              */

public void OnClientPutInServer(int client)
{
	ResetClient(client);
}

public void OnClientDisconnect(int client)
{
	if (client >= 1 && client <= MaxClients)
	{
		ResetClient(client);
	}
}

public void OnClientSettingsChanged(int client)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client))
	{
		return;
	}
	g_iSyncDepth++;
	Evaluate(client, "settings");
	g_iSyncDepth--;
}

public Action Timer_Check(Handle timer)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			Evaluate(i, "periodic");
		}
	}
	return Plugin_Continue;
}

void ResetClient(int client)
{
	g_iWarnings[client] = 0;
	g_fLastWarn[client] = 0.0;
	g_bWasViolating[client] = false;
	g_bKickQueued[client] = false;
}

/* ---------------------------------------------------------------------------- */
/* measurement                                                                   */

void Measure(int client, RateSnap snap)
{
	char buf[32];

	snap.haveRate = GetClientInfo(client, "rate", buf, sizeof(buf)) && buf[0] != '\0';
	snap.rate = snap.haveRate ? StringToInt(buf) : 0;

	snap.haveUpd = GetClientInfo(client, "cl_updaterate", buf, sizeof(buf)) && buf[0] != '\0';
	snap.upd = snap.haveUpd ? StringToInt(buf) : 0;

	snap.haveCmd = GetClientInfo(client, "cl_cmdrate", buf, sizeof(buf)) && buf[0] != '\0';
	snap.cmd = snap.haveCmd ? StringToInt(buf) : 0;

	snap.haveRatio = GetClientInfo(client, "cl_interp_ratio", buf, sizeof(buf)) && buf[0] != '\0';
	snap.ratio = snap.haveRatio ? StringToFloat(buf) : 0.0;

	snap.haveInterp = GetClientInfo(client, "cl_interp", buf, sizeof(buf)) && buf[0] != '\0';
	snap.interp = snap.haveInterp ? StringToFloat(buf) : 0.0;

	/* what the netchannel really does (needs a net channel: in-game human client) */
	snap.outPps  = GetClientAvgPackets(client, NetFlow_Outgoing);
	snap.inPps   = GetClientAvgPackets(client, NetFlow_Incoming);
	snap.outBps  = GetClientAvgData(client, NetFlow_Outgoing);
	snap.choke   = GetClientAvgChoke(client, NetFlow_Outgoing);
	snap.loss    = GetClientAvgLoss(client, NetFlow_Incoming);
	snap.latency = GetClientAvgLatency(client, NetFlow_Outgoing);
}

int CvInt(ConVar cv, int dflt)
{
	return (cv != null) ? cv.IntValue : dflt;
}

float CvFloat(ConVar cv, float dflt)
{
	return (cv != null) ? cv.FloatValue : dflt;
}

/**
 * Appends the list of policy violations to `out`. Returns the number of violations.
 */
int CheckPolicy(RateSnap snap, char[] out, int maxlen)
{
	int n = 0;
	out[0] = '\0';

	int minRate = CvInt(g_cvMinRate, 0);
	int maxRate = CvInt(g_cvMaxRate, 0);
	int minUpd  = CvInt(g_cvMinUpd, 0);
	int maxUpd  = CvInt(g_cvMaxUpd, 0);
	int minCmd  = CvInt(g_cvMinCmd, 0);
	int maxCmd  = CvInt(g_cvMaxCmd, 0);
	float minRatio = CvFloat(g_cvMinRatio, -1.0);
	float maxRatio = CvFloat(g_cvMaxRatio, -1.0);

	if (snap.haveRate)
	{
		if (minRate > 0 && snap.rate < minRate)
		{
			n++;
			Format(out, maxlen, "%srate %d < sv_minrate %d; ", out, snap.rate, minRate);
		}
		if (maxRate > 0 && snap.rate > maxRate)
		{
			n++;
			Format(out, maxlen, "%srate %d > sv_maxrate %d; ", out, snap.rate, maxRate);
		}
	}
	if (snap.haveUpd)
	{
		if (minUpd > 0 && snap.upd < minUpd)
		{
			n++;
			Format(out, maxlen, "%scl_updaterate %d < sv_minupdaterate %d; ", out, snap.upd, minUpd);
		}
		if (maxUpd > 0 && snap.upd > maxUpd)
		{
			n++;
			Format(out, maxlen, "%scl_updaterate %d > sv_maxupdaterate %d; ", out, snap.upd, maxUpd);
		}
	}
	if (snap.haveCmd)
	{
		if (minCmd > 0 && snap.cmd < minCmd)
		{
			n++;
			Format(out, maxlen, "%scl_cmdrate %d < sv_mincmdrate %d; ", out, snap.cmd, minCmd);
		}
		if (maxCmd > 0 && snap.cmd > maxCmd)
		{
			n++;
			Format(out, maxlen, "%scl_cmdrate %d > sv_maxcmdrate %d; ", out, snap.cmd, maxCmd);
		}
	}
	if (snap.haveRatio)
	{
		if (minRatio >= 0.0 && snap.ratio < minRatio)
		{
			n++;
			Format(out, maxlen, "%scl_interp_ratio %.2f < sv_client_min_interp_ratio %.2f; ", out, snap.ratio, minRatio);
		}
		if (maxRatio >= 0.0 && snap.ratio > maxRatio)
		{
			n++;
			Format(out, maxlen, "%scl_interp_ratio %.2f > sv_client_max_interp_ratio %.2f; ", out, snap.ratio, maxRatio);
		}
	}
	return n;
}

/**
 * Heuristic "does the engine clamp?" note for the log: compares the claimed
 * cl_updaterate / cl_cmdrate with the measured packet rates when the claim is above
 * the server cap. Only a hint — packet rates also drop with choke and low tickrate.
 */
void ClampNote(RateSnap snap, char[] out, int maxlen)
{
	out[0] = '\0';
	int maxUpd = CvInt(g_cvMaxUpd, 0);
	int maxCmd = CvInt(g_cvMaxCmd, 0);
	if (snap.haveUpd && maxUpd > 0 && snap.upd > maxUpd && snap.outPps > 0.0)
	{
		if (snap.outPps <= float(maxUpd) * 1.10)
		{
			Format(out, maxlen, "%supdaterate claim %d > cap %d but measured %.0f pkt/s out => engine clamps; ",
				out, snap.upd, maxUpd, snap.outPps);
		}
		else
		{
			Format(out, maxlen, "%supdaterate claim %d > cap %d and measured %.0f pkt/s out => NOT clamped; ",
				out, snap.upd, maxUpd, snap.outPps);
		}
	}
	if (snap.haveCmd && maxCmd > 0 && snap.cmd > maxCmd && snap.inPps > 0.0)
	{
		if (snap.inPps <= float(maxCmd) * 1.10)
		{
			Format(out, maxlen, "%scmdrate claim %d > cap %d but measured %.0f pkt/s in => engine clamps; ",
				out, snap.cmd, maxCmd, snap.inPps);
		}
		else
		{
			Format(out, maxlen, "%scmdrate claim %d > cap %d and measured %.0f pkt/s in => NOT clamped (client sends more); ",
				out, snap.cmd, maxCmd, snap.inPps);
		}
	}
}

float EffectiveInterp(RateSnap snap)
{
	float byRatio = 0.0;
	if (snap.upd > 0)
	{
		byRatio = snap.ratio / float(snap.upd);
	}
	return (snap.interp > byRatio) ? snap.interp : byRatio;
}

/* ---------------------------------------------------------------------------- */
/* evaluation                                                                    */

void Evaluate(int client, const char[] trigger)
{
	if (!IsClientInGame(client) || IsFakeClient(client) || g_bKickQueued[client])
	{
		return;
	}

	RateSnap snap;
	Measure(client, snap);

	char viol[VIOL_MAX];
	int n = CheckPolicy(snap, viol, sizeof(viol));

	char name[MAX_NAME_LENGTH], ip[48];
	GetClientName(client, name, sizeof(name));
	if (!GetClientIP(client, ip, sizeof(ip)))
	{
		strcopy(ip, sizeof(ip), "?");
	}

	if (n == 0)
	{
		if (g_bWasViolating[client])
		{
			LogMessage("%s #%d \"%s\" %s: back in policy (warnings reset from %d) rate=%d cl_updaterate=%d cl_cmdrate=%d cl_interp_ratio=%.2f cl_interp=%.3f",
				RP_TAG, GetClientUserId(client), name, ip, g_iWarnings[client],
				snap.rate, snap.upd, snap.cmd, snap.ratio, snap.interp);
		}
		else if (g_cvLogCompliant.BoolValue && StrEqual(trigger, "periodic"))
		{
			LogMessage("%s #%d \"%s\" %s: OK rate=%d cl_updaterate=%d cl_cmdrate=%d cl_interp_ratio=%.2f cl_interp=%.3f (eff %.3f) | measured out=%.1f pkt/s in=%.1f pkt/s out=%.1f kB/s choke=%.0f%% loss=%.0f%% ping=%.0fms",
				RP_TAG, GetClientUserId(client), name, ip,
				snap.rate, snap.upd, snap.cmd, snap.ratio, snap.interp, EffectiveInterp(snap),
				snap.outPps, snap.inPps, snap.outBps / 1024.0, snap.choke * 100.0, snap.loss * 100.0, snap.latency * 1000.0);
		}
		g_bWasViolating[client] = false;
		g_iWarnings[client] = 0;
		return;
	}

	/* out of policy */
	g_bWasViolating[client] = true;

	bool countWarning = (g_fLastWarn[client] == 0.0) || (GetEngineTime() - g_fLastWarn[client] >= g_cvWarnGap.FloatValue);
	if (countWarning)
	{
		g_iWarnings[client]++;
		g_fLastWarn[client] = GetEngineTime();
	}

	char note[256];
	ClampNote(snap, note, sizeof(note));

	LogMessage("%s #%d \"%s\" %s: VIOLATION trigger=%s warn=%d/%d enforce=%d | claimed rate=%d cl_updaterate=%d cl_cmdrate=%d cl_interp_ratio=%.2f cl_interp=%.3f (eff %.3f) | measured out=%.1f pkt/s in=%.1f pkt/s out=%.1f kB/s choke=%.0f%% loss=%.0f%% ping=%.0fms | %s%s",
		RP_TAG, GetClientUserId(client), name, ip, trigger, g_iWarnings[client], g_cvWarnings.IntValue, g_cvEnforce.IntValue,
		snap.rate, snap.upd, snap.cmd, snap.ratio, snap.interp, EffectiveInterp(snap),
		snap.outPps, snap.inPps, snap.outBps / 1024.0, snap.choke * 100.0, snap.loss * 100.0, snap.latency * 1000.0,
		viol, note);

	if (g_cvEnforce.IntValue < 1)
	{
		return; /* log-only */
	}

	if (countWarning && g_cvChat.BoolValue)
	{
		PrintToChat(client, "[Chogan] Your rate settings are out of server policy (%d/%d): %s",
			g_iWarnings[client], g_cvWarnings.IntValue, viol);
		PrintToConsole(client, "[Chogan] rate policy: sv_minrate %d sv_maxrate %d sv_minupdaterate %d sv_maxupdaterate %d sv_mincmdrate %d sv_maxcmdrate %d sv_client_min_interp_ratio %.2f sv_client_max_interp_ratio %.2f - fix: %s",
			CvInt(g_cvMinRate, 0), CvInt(g_cvMaxRate, 0), CvInt(g_cvMinUpd, 0), CvInt(g_cvMaxUpd, 0),
			CvInt(g_cvMinCmd, 0), CvInt(g_cvMaxCmd, 0), CvFloat(g_cvMinRatio, -1.0), CvFloat(g_cvMaxRatio, -1.0), viol);
	}

	if (g_iWarnings[client] >= g_cvWarnings.IntValue)
	{
		g_bKickQueued[client] = true;
		LogMessage("%s #%d \"%s\" %s: KICK after %d warnings: %s", RP_TAG, GetClientUserId(client), name, ip, g_iWarnings[client], viol);
		if (g_iSyncDepth > 0)
		{
			RequestFrame(Frame_Kick, GetClientSerial(client));
		}
		else
		{
			DoKick(client);
		}
	}
}

public void Frame_Kick(any serial)
{
	int client = GetClientFromSerial(serial);
	if (client > 0 && g_bKickQueued[client])
	{
		DoKick(client);
	}
}

void DoKick(int client)
{
	if (!IsClientConnected(client) || IsClientInKickQueue(client))
	{
		return;
	}
	char msg[256];
	FormatEx(msg, sizeof(msg), "Rate settings out of server policy (set rate %d-%d, cl_updaterate %d-%d, cl_cmdrate %d-%d)",
		CvInt(g_cvMinRate, 0), CvInt(g_cvMaxRate, 0), CvInt(g_cvMinUpd, 0), CvInt(g_cvMaxUpd, 0),
		CvInt(g_cvMinCmd, 0), CvInt(g_cvMaxCmd, 0));
	KickClient(client, "%s", msg);
}

/* ---------------------------------------------------------------------------- */
/* admin                                                                         */

void LogPolicy(const char[] when)
{
	LogMessage("%s policy (%s): sv_minrate=%d sv_maxrate=%d sv_minupdaterate=%d sv_maxupdaterate=%d sv_mincmdrate=%d sv_maxcmdrate=%d sv_client_min_interp_ratio=%.2f sv_client_max_interp_ratio=%.2f enforce=%d warnings=%d interval=%.0fs",
		RP_TAG, when,
		CvInt(g_cvMinRate, 0), CvInt(g_cvMaxRate, 0), CvInt(g_cvMinUpd, 0), CvInt(g_cvMaxUpd, 0),
		CvInt(g_cvMinCmd, 0), CvInt(g_cvMaxCmd, 0), CvFloat(g_cvMinRatio, -1.0), CvFloat(g_cvMaxRatio, -1.0),
		g_cvEnforce.IntValue, g_cvWarnings.IntValue, g_cvInterval.FloatValue);
}

public Action Cmd_RatePolicy(int client, int args)
{
	if (args >= 1)
	{
		char arg[16];
		GetCmdArg(1, arg, sizeof(arg));
		if (StrEqual(arg, "reset", false))
		{
			for (int i = 1; i <= MaxClients; i++)
			{
				ResetClient(i);
			}
			ReplyToCommand(client, "%s warning counters reset.", RP_TAG);
			return Plugin_Handled;
		}
	}

	ReplyToCommand(client, "%s policy: sv_minrate=%d sv_maxrate=%d sv_minupdaterate=%d sv_maxupdaterate=%d sv_mincmdrate=%d sv_maxcmdrate=%d sv_client_min_interp_ratio=%.2f sv_client_max_interp_ratio=%.2f | enforce=%d warnings=%d interval=%.0fs",
		RP_TAG,
		CvInt(g_cvMinRate, 0), CvInt(g_cvMaxRate, 0), CvInt(g_cvMinUpd, 0), CvInt(g_cvMaxUpd, 0),
		CvInt(g_cvMinCmd, 0), CvInt(g_cvMaxCmd, 0), CvFloat(g_cvMinRatio, -1.0), CvFloat(g_cvMaxRatio, -1.0),
		g_cvEnforce.IntValue, g_cvWarnings.IntValue, g_cvInterval.FloatValue);
	ReplyToCommand(client, "  #uid   name                      rate    upd  cmd  ratio interp  eff   | out pkt/s in pkt/s out kB/s choke%% loss%% ping | warn status");

	int shown = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
		{
			continue;
		}
		RateSnap snap;
		Measure(i, snap);
		char viol[VIOL_MAX];
		int n = CheckPolicy(snap, viol, sizeof(viol));
		if (n == 0)
		{
			strcopy(viol, sizeof(viol), "OK");
		}
		char name[MAX_NAME_LENGTH];
		GetClientName(i, name, sizeof(name));
		ReplyToCommand(client, "  #%-5d %-25s %-7d %-4d %-4d %-5.2f %-7.3f %-5.3f | %-9.1f %-8.1f %-8.1f %-6.0f %-5.0f %-4.0f | %-4d %s",
			GetClientUserId(i), name, snap.rate, snap.upd, snap.cmd, snap.ratio, snap.interp, EffectiveInterp(snap),
			snap.outPps, snap.inPps, snap.outBps / 1024.0, snap.choke * 100.0, snap.loss * 100.0, snap.latency * 1000.0,
			g_iWarnings[i], viol);
		shown++;
	}
	if (shown == 0)
	{
		ReplyToCommand(client, "  (no human clients in game)");
	}
	return Plugin_Handled;
}
