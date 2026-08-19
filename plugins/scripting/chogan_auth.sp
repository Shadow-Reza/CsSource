/**
 * chogan_auth.sp — Chogan phone-account authentication for CS:Source (MISSION §6.3).
 *
 * Flow (per connection):
 *   OnClientConnected ─► read `lt` userinfo key (setinfo lt <ticket>, set by the launcher
 *   BEFORE connect) ─► POST /v1/redeem to the local cg-agent (async, RIPExt) or INSERT a
 *   request row + poll (async, threaded MySQL) ─► callback resolves the client by SERIAL
 *   (never by index, MISSION §4.5) ─► bind account (natives + Chogan_OnAccountBound) or
 *   KickClient() (delayed to next frame by SourceMod itself, safe from any context).
 *
 * If `lt` is empty at OnClientConnected the plugin keeps looking at
 * OnClientSettingsChanged / OnClientPutInServer (probe 1 decides where the userinfo shows
 * up first) and also accepts the fallback console command `cg_ticket <token>` (probe 1
 * branch (b)) until the grace timer (cg_auth_grace) fires.
 *
 * Modes (cg_auth_mode): 0 off · 1 soft (API failure ⇒ cache ⇒ guest) · 2 hard (API failure
 * ⇒ cache ⇒ kick). A *rejected* ticket (invalid/used/expired/scope) is NOT an API failure and
 * kicks in both modes unless cg_auth_allow_invalid_as_guest 1. Fail open, not closed.
 *
 * Reconnect handling: authid+ip → account cache for cg_auth_cache_ttl seconds (default 600)
 * on top of the agent's own cache, so a manual reconnect that re-presents an already
 * redeemed ticket is not kicked. Circuit breaker: after cg_auth_breaker_fails consecutive
 * transport failures the plugin stops calling the agent for cg_auth_breaker_open seconds
 * and takes the fallback path immediately, so a dead agent never costs a full timeout per
 * connect (MISSION §6.3).
 *
 * NEVER blocking: no SQL_Query/SQL_FastQuery, no synchronous HTTP (MISSION §4.4).
 *
 * Contract with cg-agent (implement the agent to match; see plugins/README.md):
 *   POST {cg_agent_url}/v1/redeem  {"ticket","server_id","ip","authid","name","userid"}
 *     200 {"ok":true,"account_id":123,"display_name":"…","cached":false}
 *     200/4xx {"ok":false,"reason":"invalid|used|expired|scope|api_down|…"}
 *     anything else / 5xx / transport error / non-JSON ⇒ api_down
 *   POST {cg_agent_url}/v1/event   {"server_id","event":"join|leave","account_id","authid","ip","name","map"}
 *   GET  {cg_agent_url}/health
 *   SQL transport: table cg_auth_requests (plugins/sql/chogan_auth.sql); the agent fills
 *     verdict ('ok'|'reject'|'error'), account_id, display_name, reason.
 *
 * SourceMod 1.12, RIPExt 1.3.2 (optional at load time; required for transport "ripext").
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

/* RIPExt is optional at load time so the SQL transport works on a box where rip.ext is
 * absent/broken. Every RIPExt native we use is marked optional in AskPluginLoad2. */
#undef REQUIRE_EXTENSIONS
#include <ripext>
#define REQUIRE_EXTENSIONS

#include <chogan>

#define PLUGIN_VERSION   CHOGAN_AUTH_VERSION
#define TICKET_MAX       512   /* userinfo values are capped at 260 bytes; cg_ticket may carry more */
#define TAG              "[chogan_auth]"

enum Transport
{
	Transport_None = 0,
	Transport_RipExt,
	Transport_Sql
};

/* ------------------------------------------------------------------------- cvars */
ConVar g_cvMode;            /* cg_auth_mode */
ConVar g_cvAgentUrl;        /* cg_agent_url */
ConVar g_cvServerId;        /* cg_server_id */
ConVar g_cvTimeout;         /* cg_auth_timeout */
ConVar g_cvGrace;           /* cg_auth_grace */
ConVar g_cvTransport;       /* cg_auth_transport */
ConVar g_cvKickMsg;         /* cg_auth_kick_msg */
ConVar g_cvInvalidGuest;    /* cg_auth_allow_invalid_as_guest */
ConVar g_cvCacheTtl;        /* cg_auth_cache_ttl */
ConVar g_cvBreakerFails;    /* cg_auth_breaker_fails */
ConVar g_cvBreakerOpen;     /* cg_auth_breaker_open */
ConVar g_cvEvents;          /* cg_auth_events */
ConVar g_cvDebug;           /* cg_auth_debug */

/* ------------------------------------------------------------------------- state */
ChoganAuthState g_State[MAXPLAYERS + 1];
int    g_iAccountId[MAXPLAYERS + 1];
char   g_sDisplayName[MAXPLAYERS + 1][CHOGAN_MAX_DISPLAYNAME];
char   g_sSource[MAXPLAYERS + 1][16];    /* setinfo | cmd | cache | lateload | - */
char   g_sReason[MAXPLAYERS + 1][32];
char   g_sTicketHint[MAXPLAYERS + 1][12];/* first 8 chars of the ticket, for logs only */
float  g_fRedeemStart[MAXPLAYERS + 1];
Handle g_hGraceTimer[MAXPLAYERS + 1];
Handle g_hWatchdog[MAXPLAYERS + 1];
Handle g_hPollTimer[MAXPLAYERS + 1];
int    g_iSqlRowId[MAXPLAYERS + 1];
bool   g_bSqlInFlight[MAXPLAYERS + 1];
int    g_iSqlPollErrors[MAXPLAYERS + 1];
bool   g_bJoinEventSent[MAXPLAYERS + 1];

Transport g_Transport = Transport_None;
bool      g_bRipExt = false;
Database  g_hDb = null;
bool      g_bDbConnecting = false;
char      g_sServerId[64];
bool      g_bLateLoad = false;

/* circuit breaker */
int   g_iBreakerFails = 0;
float g_fBreakerOpenUntil = 0.0;
int   g_iBreakerTrips = 0;

/* reconnect cache: key "<ip>|<authid>" -> {account_id, expires_at(unix)} + display name */
StringMap g_hCacheAcct;
StringMap g_hCacheName;

/* forwards */
GlobalForward g_fwdBound;
GlobalForward g_fwdResolved;

/* stats for sm_cgauth */
int g_iStatRedeemOk, g_iStatRedeemCached, g_iStatRejected, g_iStatApiDown, g_iStatGuests, g_iStatKicks;

public Plugin myinfo =
{
	name        = "[Chogan] Auth (phone-account login)",
	author      = "Chogan build (autonomous run)",
	description = "Redeems the launcher ticket (setinfo lt) against cg-agent; binds account or kicks",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/Shadow-Reza/CsSource"
};

/* ============================================================================ */
/* load                                                                          */

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLateLoad = late;

	CreateNative("Chogan_GetAccountId",   Native_GetAccountId);
	CreateNative("Chogan_GetDisplayName", Native_GetDisplayName);
	CreateNative("Chogan_GetAuthState",   Native_GetAuthState);
	CreateNative("Chogan_IsGuest",        Native_IsGuest);
	CreateNative("Chogan_GetServerId",    Native_GetServerId);
	RegPluginLibrary("chogan_auth");

	/* RIPExt natives used below — optional so the plugin loads without rip.ext */
	MarkNativeAsOptional("HTTPRequest.HTTPRequest");
	MarkNativeAsOptional("HTTPRequest.SetHeader");
	MarkNativeAsOptional("HTTPRequest.Get");
	MarkNativeAsOptional("HTTPRequest.Post");
	MarkNativeAsOptional("HTTPRequest.ConnectTimeout.set");
	MarkNativeAsOptional("HTTPRequest.ConnectTimeout.get");
	MarkNativeAsOptional("HTTPRequest.Timeout.set");
	MarkNativeAsOptional("HTTPRequest.Timeout.get");
	MarkNativeAsOptional("HTTPResponse.Status.get");
	MarkNativeAsOptional("HTTPResponse.Data.get");
	MarkNativeAsOptional("HTTPResponse.GetHeader");
	MarkNativeAsOptional("JSONObject.JSONObject");
	MarkNativeAsOptional("JSONObject.SetString");
	MarkNativeAsOptional("JSONObject.SetInt");
	MarkNativeAsOptional("JSONObject.SetBool");
	MarkNativeAsOptional("JSONObject.GetBool");
	MarkNativeAsOptional("JSONObject.GetInt");
	MarkNativeAsOptional("JSONObject.GetString");
	MarkNativeAsOptional("JSONObject.HasKey");
	MarkNativeAsOptional("JSONObject.IsNull");
	MarkNativeAsOptional("JSON.ToString");

	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar("cg_auth_version", PLUGIN_VERSION, "Chogan auth plugin version",
		FCVAR_NOTIFY | FCVAR_DONTRECORD | FCVAR_SPONLY);

	g_cvMode = CreateConVar("cg_auth_mode", "1",
		"0 = off, 1 = soft (API failure -> cache -> guest), 2 = hard (API failure -> cache -> kick)",
		FCVAR_NONE, true, 0.0, true, 2.0);
	g_cvAgentUrl = CreateConVar("cg_agent_url", "http://127.0.0.1:8480",
		"Base URL of the local cg-agent (no trailing slash)", FCVAR_NONE);
	g_cvServerId = CreateConVar("cg_server_id", "",
		"REQUIRED. Server id the launcher tickets are scoped to (e.g. pub1, dm, m1)", FCVAR_NONE);
	g_cvTimeout = CreateConVar("cg_auth_timeout", "4.0",
		"Seconds to wait for the agent (HTTP timeout / SQL poll deadline) before the failure path",
		FCVAR_NONE, true, 0.5, true, 60.0);
	g_cvGrace = CreateConVar("cg_auth_grace", "8.0",
		"Seconds after connect the client has to present a ticket (setinfo lt or cg_ticket) before no-ticket handling",
		FCVAR_NONE, true, 1.0, true, 120.0);
	g_cvTransport = CreateConVar("cg_auth_transport", "ripext",
		"Transport to cg-agent: \"ripext\" (async HTTP, default) or \"sql\" (threaded MySQL fallback via databases.cfg \"chogan\")",
		FCVAR_NONE);
	g_cvKickMsg = CreateConVar("cg_auth_kick_msg", "Chogan: please start the game from the Chogan launcher (login required)",
		"Kick reason shown to the client", FCVAR_NONE);
	g_cvInvalidGuest = CreateConVar("cg_auth_allow_invalid_as_guest", "0",
		"1 = a rejected ticket (invalid/used/expired/scope) lets the client in as guest instead of kicking",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvCacheTtl = CreateConVar("cg_auth_cache_ttl", "600",
		"Seconds an authid+ip -> account cache entry stays valid (reconnect / agent-down fallback)",
		FCVAR_NONE, true, 0.0, true, 86400.0);
	g_cvBreakerFails = CreateConVar("cg_auth_breaker_fails", "3",
		"Consecutive transport failures that open the circuit breaker (0 = disabled)",
		FCVAR_NONE, true, 0.0, true, 100.0);
	g_cvBreakerOpen = CreateConVar("cg_auth_breaker_open", "20.0",
		"Seconds the breaker stays open (agent not called, fallback path taken immediately)",
		FCVAR_NONE, true, 1.0, true, 600.0);
	g_cvEvents = CreateConVar("cg_auth_events", "1",
		"1 = post join/leave events for bound accounts to the agent (fire and forget)",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("cg_auth_debug", "0",
		"1 = verbose logging of every step", FCVAR_NONE, true, 0.0, true, 1.0);

	g_cvTransport.AddChangeHook(OnTransportCvarChanged);
	g_cvServerId.AddChangeHook(OnServerIdCvarChanged);

	AutoExecConfig(true, "chogan_auth");

	RegConsoleCmd("cg_ticket", Cmd_Ticket,
		"Present the Chogan login ticket by console command (fallback to setinfo lt): cg_ticket <token>");
	RegAdminCmd("sm_cgauth", Cmd_Status, ADMFLAG_GENERIC,
		"Show Chogan auth status of every client (account, source, guest) and plugin health");
	RegAdminCmd("sm_cgauth_health", Cmd_Health, ADMFLAG_GENERIC,
		"Async GET {cg_agent_url}/health and log the result");

	g_fwdBound    = new GlobalForward("Chogan_OnAccountBound",  ET_Ignore, Param_Cell, Param_Cell, Param_String);
	g_fwdResolved = new GlobalForward("Chogan_OnAuthResolved",  ET_Ignore, Param_Cell, Param_Cell, Param_String);

	g_hCacheAcct = new StringMap();
	g_hCacheName = new StringMap();

	for (int i = 1; i <= MaxClients; i++)
	{
		ResetClient(i);
	}

	g_bRipExt = LibraryExists("ripext");

	CreateTimer(60.0, Timer_PruneCache, _, TIMER_REPEAT);

	LogMessage("%s v%s loaded (late=%d, ripext=%d)", TAG, PLUGIN_VERSION, g_bLateLoad, g_bRipExt);
}

public void OnAllPluginsLoaded()
{
	if (!g_bLateLoad)
	{
		return;
	}
	/* Late load (plugin reload mid-session): everybody already connected becomes a
	 * guest. Their tickets have been redeemed already; mass-kicking a full server on a
	 * plugin reload is worse than one session of guests. They re-auth on next connect.
	 * (Recorded in docs/OPEN-QUESTIONS.md by the orchestrator.) */
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && !IsFakeClient(i))
		{
			ResetClient(i);
			SetGuest(i, "lateload", "lateload");
			n++;
		}
	}
	if (n > 0)
	{
		LogMessage("%s late load: %d already-connected client(s) marked guest (source=lateload)", TAG, n);
	}
}

public void OnConfigsExecuted()
{
	g_cvServerId.GetString(g_sServerId, sizeof(g_sServerId));
	TrimString(g_sServerId);
	if (g_sServerId[0] == '\0')
	{
		LogError("%s cg_server_id is EMPTY — set it in cfg/sourcemod/chogan_auth.cfg. Every redeem will fail (soft mode => guests).", TAG);
	}
	ResolveTransport();
}

public void OnPluginEnd()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		delete g_hGraceTimer[i];
		delete g_hWatchdog[i];
		delete g_hPollTimer[i];
	}
	delete g_hDb;
}

public void OnLibraryAdded(const char[] name)
{
	if (StrEqual(name, "ripext"))
	{
		g_bRipExt = true;
		ResolveTransport();
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "ripext"))
	{
		g_bRipExt = false;
		ResolveTransport();
	}
}

public void OnTransportCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	ResolveTransport();
}

public void OnServerIdCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	strcopy(g_sServerId, sizeof(g_sServerId), newValue);
	TrimString(g_sServerId);
}

void ResolveTransport()
{
	char want[16];
	g_cvTransport.GetString(want, sizeof(want));
	TrimString(want);

	Transport before = g_Transport;

	if (StrEqual(want, "sql", false))
	{
		g_Transport = Transport_Sql;
		if (g_hDb == null)
		{
			ConnectDb();
		}
	}
	else
	{
		if (!StrEqual(want, "ripext", false))
		{
			LogError("%s cg_auth_transport \"%s\" unknown — using \"ripext\"", TAG, want);
		}
		if (g_bRipExt)
		{
			g_Transport = Transport_RipExt;
		}
		else if (SQL_CheckConfig("chogan"))
		{
			LogError("%s RIPExt (rip.ext) is not loaded — falling back to the SQL transport (databases.cfg \"chogan\")", TAG);
			g_Transport = Transport_Sql;
			if (g_hDb == null)
			{
				ConnectDb();
			}
		}
		else
		{
			LogError("%s RIPExt is not loaded and no \"chogan\" database config exists — NO TRANSPORT. Every redeem takes the api_down path.", TAG);
			g_Transport = Transport_None;
		}
	}

	if (before != g_Transport)
	{
		LogMessage("%s transport = %s", TAG, TransportName(g_Transport));
	}
}

void TransportNameCopy(Transport t, char[] buf, int maxlen)
{
	switch (t)
	{
		case Transport_RipExt: strcopy(buf, maxlen, "ripext");
		case Transport_Sql:    strcopy(buf, maxlen, "sql");
		default:               strcopy(buf, maxlen, "none");
	}
}

/* small helper so TransportName() can be used inline in format calls */
char g_sTransportNameBuf[16];
char[] TransportName(Transport t)
{
	TransportNameCopy(t, g_sTransportNameBuf, sizeof(g_sTransportNameBuf));
	char out[16];
	strcopy(out, sizeof(out), g_sTransportNameBuf);
	return out;
}

/* ============================================================================ */
/* client lifecycle                                                              */

public void OnClientConnected(int client)
{
	ResetClient(client);

	if (IsFakeClient(client))
	{
		g_State[client] = ChoganAuth_Skipped;
		strcopy(g_sReason[client], sizeof(g_sReason[]), "bot");
		return;
	}
	if (g_cvMode.IntValue == 0)
	{
		g_State[client] = ChoganAuth_Skipped;
		strcopy(g_sReason[client], sizeof(g_sReason[]), "mode_off");
		return;
	}

	g_State[client] = ChoganAuth_Waiting;

	/* grace: the client has this long to present a ticket by any channel */
	g_hGraceTimer[client] = CreateTimer(g_cvGrace.FloatValue, Timer_Grace, GetClientSerial(client));

	Debug("client %d (%N) connected: waiting for ticket (grace %.1fs)", client, client, g_cvGrace.FloatValue);

	TryReadSetinfoToken(client, "OnClientConnected");
}

public void OnClientSettingsChanged(int client)
{
	if (client >= 1 && client <= MaxClients && g_State[client] == ChoganAuth_Waiting)
	{
		TryReadSetinfoToken(client, "OnClientSettingsChanged");
	}
}

public void OnClientPutInServer(int client)
{
	if (g_State[client] == ChoganAuth_Waiting)
	{
		TryReadSetinfoToken(client, "OnClientPutInServer");
	}
}

public void OnClientPostAdminCheck(int client)
{
	/* the auth id usually arrives after we bound — refresh the cache key with it */
	if (g_State[client] == ChoganAuth_Bound)
	{
		CacheStore(client, g_iAccountId[client], g_sDisplayName[client]);
	}
}

public void OnClientDisconnect(int client)
{
	if (client < 1 || client > MaxClients)
	{
		return;
	}
	if (g_State[client] == ChoganAuth_Bound && g_bJoinEventSent[client])
	{
		PostEvent(client, "leave");
	}
	ResetClient(client);
}

public void OnMapStart()
{
	/* Clients survive a map change on Source; our timers do too (no TIMER_FLAG_NO_MAPCHANGE).
	 * Defensive: re-arm anything that lost its timer. */
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || IsFakeClient(i))
		{
			continue;
		}
		if (g_State[i] == ChoganAuth_Waiting && g_hGraceTimer[i] == null)
		{
			g_hGraceTimer[i] = CreateTimer(g_cvGrace.FloatValue, Timer_Grace, GetClientSerial(i));
		}
		else if (g_State[i] == ChoganAuth_Pending && g_hWatchdog[i] == null)
		{
			g_hWatchdog[i] = CreateTimer(g_cvTimeout.FloatValue + 1.5, Timer_Watchdog, GetClientSerial(i));
		}
	}
}

void ResetClient(int client)
{
	g_State[client] = ChoganAuth_None;
	g_iAccountId[client] = 0;
	g_sDisplayName[client][0] = '\0';
	strcopy(g_sSource[client], sizeof(g_sSource[]), "-");
	g_sReason[client][0] = '\0';
	g_sTicketHint[client][0] = '\0';
	g_fRedeemStart[client] = 0.0;
	g_iSqlRowId[client] = 0;
	g_bSqlInFlight[client] = false;
	g_iSqlPollErrors[client] = 0;
	g_bJoinEventSent[client] = false;
	delete g_hGraceTimer[client];
	delete g_hWatchdog[client];
	delete g_hPollTimer[client];
}

/* ============================================================================ */
/* ticket acquisition                                                            */

void TryReadSetinfoToken(int client, const char[] where)
{
	if (g_State[client] != ChoganAuth_Waiting || !IsClientConnected(client))
	{
		return;
	}
	char token[TICKET_MAX];
	if (!GetClientInfo(client, "lt", token, sizeof(token)))
	{
		return;
	}
	TrimString(token);
	if (token[0] == '\0')
	{
		return;
	}
	Debug("client %d: lt found at %s (%d bytes)", client, where, strlen(token));
	StartRedeem(client, token, "setinfo");
}

public Action Cmd_Ticket(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%s cg_ticket is a client command.", TAG);
		return Plugin_Handled;
	}
	if (!IsClientConnected(client))
	{
		return Plugin_Handled;
	}

	if (g_State[client] != ChoganAuth_Waiting)
	{
		ReplyToCommand(client, "%s ticket ignored (state=%s).", TAG, StateName(g_State[client]));
		return Plugin_Handled;
	}

	char token[TICKET_MAX];
	if (args >= 1)
	{
		GetCmdArg(1, token, sizeof(token));
		TrimString(token);
	}
	if (token[0] == '\0')
	{
		ReplyToCommand(client, "%s usage: cg_ticket <token>", TAG);
		return Plugin_Handled;
	}

	Debug("client %d: ticket via cg_ticket command (%d bytes)", client, strlen(token));
	StartRedeem(client, token, "cmd");
	ReplyToCommand(client, "%s ticket received, verifying...", TAG);
	return Plugin_Handled;
}

public Action Timer_Grace(Handle timer, any serial)
{
	int client = GetClientFromSerial(serial);
	if (client <= 0)
	{
		return Plugin_Stop;
	}
	g_hGraceTimer[client] = null;

	if (g_State[client] != ChoganAuth_Waiting)
	{
		return Plugin_Stop; /* ticket arrived meanwhile */
	}

	/* one last look at the userinfo before deciding */
	TryReadSetinfoToken(client, "grace-expiry");
	if (g_State[client] != ChoganAuth_Waiting)
	{
		return Plugin_Stop;
	}

	if (g_cvMode.IntValue >= 2)
	{
		KickForAuth(client, "no_ticket");
	}
	else
	{
		SetGuest(client, "no_ticket", "none");
	}
	return Plugin_Stop;
}

/* ============================================================================ */
/* redemption                                                                    */

void StartRedeem(int client, const char[] ticket, const char[] source)
{
	if (g_State[client] != ChoganAuth_Waiting)
	{
		return;
	}
	g_State[client] = ChoganAuth_Pending;
	strcopy(g_sSource[client], sizeof(g_sSource[]), source);
	strcopy(g_sTicketHint[client], sizeof(g_sTicketHint[]), ticket); /* truncates to 11 chars */
	g_fRedeemStart[client] = GetEngineTime();

	delete g_hGraceTimer[client];
	/* the watchdog is the safety net for a callback that never fires or throws */
	delete g_hWatchdog[client];
	g_hWatchdog[client] = CreateTimer(g_cvTimeout.FloatValue + 1.5, Timer_Watchdog, GetClientSerial(client));

	if (g_sServerId[0] == '\0')
	{
		HandleApiDown(client, "no_server_id");
		return;
	}
	if (BreakerIsOpen())
	{
		Debug("client %d: breaker open, skipping agent", client);
		HandleApiDown(client, "breaker_open");
		return;
	}

	switch (g_Transport)
	{
		case Transport_RipExt: SendRedeemHttp(client, ticket);
		case Transport_Sql:    SendRedeemSql(client, ticket);
		default:               HandleApiDown(client, "no_transport");
	}
}

public Action Timer_Watchdog(Handle timer, any serial)
{
	int client = GetClientFromSerial(serial);
	if (client <= 0)
	{
		return Plugin_Stop;
	}
	g_hWatchdog[client] = null;
	if (g_State[client] == ChoganAuth_Pending)
	{
		LogMessage("%s client %d (%N): redeem still pending after %.1fs — watchdog takes the api_down path",
			TAG, client, client, GetEngineTime() - g_fRedeemStart[client]);
		HandleApiDown(client, "timeout");
	}
	return Plugin_Stop;
}

/* ---------------------------------------------------------------- identity bits */

void GetIdentity(int client, char[] ip, int iplen, char[] authid, int authlen, char[] name, int namelen)
{
	if (!GetClientIP(client, ip, iplen))
	{
		ip[0] = '\0';
	}
	/* Steam2 first (what RevEmu hands out), then the raw engine string. Both return
	 * false while the client is not authorized yet — that is normal at connect time. */
	if (!GetClientAuthId(client, AuthId_Steam2, authid, authlen))
	{
		if (!GetClientAuthId(client, AuthId_Engine, authid, authlen))
		{
			authid[0] = '\0';
		}
	}
	if (!GetClientName(client, name, namelen))
	{
		name[0] = '\0';
	}
}

/* ---------------------------------------------------------------- HTTP transport */

void BuildUrl(char[] url, int maxlen, const char[] path)
{
	char base[256];
	g_cvAgentUrl.GetString(base, sizeof(base));
	TrimString(base);
	int len = strlen(base);
	while (len > 0 && base[len - 1] == '/')
	{
		base[--len] = '\0';
	}
	FormatEx(url, maxlen, "%s%s", base, path);
}

void SendRedeemHttp(int client, const char[] ticket)
{
	char ip[48], authid[64], name[MAX_NAME_LENGTH];
	GetIdentity(client, ip, sizeof(ip), authid, sizeof(authid), name, sizeof(name));

	char url[512];
	BuildUrl(url, sizeof(url), "/v1/redeem");

	JSONObject body = new JSONObject();
	body.SetString("ticket", ticket);
	body.SetString("server_id", g_sServerId);
	body.SetString("ip", ip);
	body.SetString("authid", authid);
	body.SetString("name", name);
	body.SetInt("userid", GetClientUserId(client));

	HTTPRequest req = new HTTPRequest(url);
	req.ConnectTimeout = 2;
	req.Timeout = RoundToCeil(g_cvTimeout.FloatValue);
	req.SetHeader("Accept", "application/json");
	req.Post(body, OnRedeemResponse, GetClientSerial(client)); /* handle freed by RIPExt */
	delete body;                                                /* body already serialised */

	Debug("client %d: POST %s (authid=%s ip=%s)", client, url, authid, ip);
}

public void OnRedeemResponse(HTTPResponse response, any serial, const char[] error)
{
	int client = GetClientFromSerial(serial);
	if (client <= 0)
	{
		return; /* slot reused or client gone — never touch by index (MISSION §4.5) */
	}
	if (g_State[client] != ChoganAuth_Pending)
	{
		return; /* watchdog or disconnect already resolved this connection */
	}

	int status = view_as<int>(response.Status);

	if (error[0] != '\0' || status == 0)
	{
		char why[128];
		FormatEx(why, sizeof(why), "transport:%s", (error[0] != '\0') ? error : "status0");
		HandleApiDown(client, why);
		return;
	}
	if (status >= 500)
	{
		char why[32];
		FormatEx(why, sizeof(why), "http_%d", status);
		HandleApiDown(client, why);
		return;
	}

	char ctype[96];
	if (!response.GetHeader("Content-Type", ctype, sizeof(ctype)) || StrContains(ctype, "json", false) == -1)
	{
		/* .Data would throw on a non-JSON body and abort this callback */
		char why[64];
		FormatEx(why, sizeof(why), "non_json_http_%d", status);
		HandleApiDown(client, why);
		return;
	}

	JSONObject data = view_as<JSONObject>(response.Data);
	if (data == null || !data.HasKey("ok"))
	{
		char why[64];
		FormatEx(why, sizeof(why), "bad_body_http_%d", status);
		HandleApiDown(client, why);
		return;
	}

	if (data.GetBool("ok"))
	{
		int accountId = data.GetInt("account_id");
		if (accountId == 0 && data.HasKey("account_id"))
		{
			char tmp[32];
			if (data.GetString("account_id", tmp, sizeof(tmp)))
			{
				accountId = StringToInt(tmp);
			}
		}
		char dname[CHOGAN_MAX_DISPLAYNAME];
		if (!data.GetString("display_name", dname, sizeof(dname)))
		{
			dname[0] = '\0';
		}
		bool cached = data.HasKey("cached") && data.GetBool("cached");
		if (accountId <= 0)
		{
			HandleApiDown(client, "ok_without_account_id");
			return;
		}
		BreakerSuccess();
		BindClient(client, accountId, dname, cached ? "ok_agent_cache" : "ok");
		return;
	}

	char reason[32];
	if (!data.GetString("reason", reason, sizeof(reason)) || reason[0] == '\0')
	{
		strcopy(reason, sizeof(reason), "rejected");
	}
	if (IsApiFailureReason(reason))
	{
		HandleApiDown(client, reason);
	}
	else
	{
		BreakerSuccess(); /* the agent answered — transport is healthy */
		HandleBadTicket(client, reason);
	}
}

bool IsApiFailureReason(const char[] reason)
{
	return StrEqual(reason, "api_down", false)
	    || StrEqual(reason, "upstream", false)
	    || StrEqual(reason, "timeout", false)
	    || StrEqual(reason, "breaker_open", false)
	    || StrEqual(reason, "unavailable", false)
	    || StrEqual(reason, "internal", false);
}

/* ---------------------------------------------------------------- SQL transport */

void ConnectDb()
{
	if (g_bDbConnecting)
	{
		return;
	}
	if (!SQL_CheckConfig("chogan"))
	{
		LogError("%s databases.cfg has no \"chogan\" section — SQL transport unavailable", TAG);
		return;
	}
	g_bDbConnecting = true;
	Database.Connect(OnDbConnect, "chogan");
}

public void OnDbConnect(Database db, const char[] error, any data)
{
	g_bDbConnecting = false;
	if (db == null)
	{
		LogError("%s database connect failed: %s (retry in 30s)", TAG, error);
		CreateTimer(30.0, Timer_DbRetry);
		return;
	}
	delete g_hDb;
	g_hDb = db;
	g_hDb.SetCharset("utf8mb4");
	LogMessage("%s database \"chogan\" connected (SQL transport ready)", TAG);
}

public Action Timer_DbRetry(Handle timer)
{
	if (g_hDb == null && (g_Transport == Transport_Sql))
	{
		ConnectDb();
	}
	return Plugin_Stop;
}

void SendRedeemSql(int client, const char[] ticket)
{
	if (g_hDb == null)
	{
		ConnectDb();
		HandleApiDown(client, "sql_not_connected");
		return;
	}

	char ip[48], authid[64], name[MAX_NAME_LENGTH];
	GetIdentity(client, ip, sizeof(ip), authid, sizeof(authid), name, sizeof(name));

	/* Database.Format escapes every %s (SM 1.10+), so this is injection-safe. */
	char query[1400];
	g_hDb.Format(query, sizeof(query),
		"INSERT INTO cg_auth_requests (ticket, server_id, ip, authid, name, created_at) VALUES ('%s', '%s', '%s', '%s', '%s', NOW())",
		ticket, g_sServerId, ip, authid, name);
	g_hDb.Query(OnSqlInsert, query, GetClientSerial(client));
	Debug("client %d: SQL request row inserting", client);
}

public void OnSqlInsert(Database db, DBResultSet results, const char[] error, any serial)
{
	int client = GetClientFromSerial(serial);
	if (client <= 0 || g_State[client] != ChoganAuth_Pending)
	{
		return;
	}
	if (results == null)
	{
		LogError("%s SQL insert failed: %s", TAG, error);
		HandleApiDown(client, "sql_insert_failed");
		return;
	}
	g_iSqlRowId[client] = results.InsertId;
	g_bSqlInFlight[client] = false;
	g_iSqlPollErrors[client] = 0;
	delete g_hPollTimer[client];
	g_hPollTimer[client] = CreateTimer(0.5, Timer_SqlPoll, serial, TIMER_REPEAT);
	Debug("client %d: SQL request row id=%d, polling", client, g_iSqlRowId[client]);
}

public Action Timer_SqlPoll(Handle timer, any serial)
{
	int client = GetClientFromSerial(serial);
	if (client <= 0)
	{
		return Plugin_Stop;
	}
	if (g_State[client] != ChoganAuth_Pending)
	{
		g_hPollTimer[client] = null;
		return Plugin_Stop;
	}
	if (GetEngineTime() - g_fRedeemStart[client] > g_cvTimeout.FloatValue)
	{
		g_hPollTimer[client] = null;
		HandleApiDown(client, "sql_timeout");
		return Plugin_Stop;
	}
	if (g_bSqlInFlight[client] || g_hDb == null)
	{
		return Plugin_Continue;
	}
	g_bSqlInFlight[client] = true;

	char query[256];
	FormatEx(query, sizeof(query),
		"SELECT verdict, account_id, display_name, reason FROM cg_auth_requests WHERE id = %d AND verdict IS NOT NULL",
		g_iSqlRowId[client]);
	g_hDb.Query(OnSqlPoll, query, serial);
	return Plugin_Continue;
}

public void OnSqlPoll(Database db, DBResultSet results, const char[] error, any serial)
{
	int client = GetClientFromSerial(serial);
	if (client <= 0)
	{
		return;
	}
	g_bSqlInFlight[client] = false;
	if (g_State[client] != ChoganAuth_Pending)
	{
		return;
	}
	if (results == null)
	{
		g_iSqlPollErrors[client]++;
		LogError("%s SQL poll failed (%d): %s", TAG, g_iSqlPollErrors[client], error);
		if (g_iSqlPollErrors[client] >= 3)
		{
			delete g_hPollTimer[client];
			HandleApiDown(client, "sql_poll_failed");
		}
		return;
	}
	if (!results.FetchRow())
	{
		return; /* no verdict yet — keep polling */
	}

	delete g_hPollTimer[client];

	char verdict[16], dname[CHOGAN_MAX_DISPLAYNAME], reason[32];
	results.FetchString(0, verdict, sizeof(verdict));
	int accountId = results.IsFieldNull(1) ? 0 : results.FetchInt(1);
	if (results.IsFieldNull(2)) dname[0] = '\0'; else results.FetchString(2, dname, sizeof(dname));
	if (results.IsFieldNull(3)) reason[0] = '\0'; else results.FetchString(3, reason, sizeof(reason));

	if (StrEqual(verdict, "ok", false) && accountId > 0)
	{
		BreakerSuccess();
		BindClient(client, accountId, dname, reason[0] ? reason : "ok");
	}
	else if (StrEqual(verdict, "reject", false))
	{
		BreakerSuccess();
		HandleBadTicket(client, reason[0] ? reason : "rejected");
	}
	else
	{
		HandleApiDown(client, reason[0] ? reason : "sql_error_verdict");
	}
}

/* ============================================================================ */
/* decisions                                                                     */

void HandleApiDown(int client, const char[] why)
{
	g_iStatApiDown++;
	BreakerFailure();
	LogMessage("%s client %d (%N): agent unavailable (%s) after %.2fs — mode=%d",
		TAG, client, client, why, GetEngineTime() - g_fRedeemStart[client], g_cvMode.IntValue);

	int accountId;
	char dname[CHOGAN_MAX_DISPLAYNAME];
	if (CacheLookup(client, accountId, dname, sizeof(dname)))
	{
		strcopy(g_sSource[client], sizeof(g_sSource[]), "cache");
		BindClient(client, accountId, dname, "ok_cache");
		return;
	}

	char reason[48];
	FormatEx(reason, sizeof(reason), "api_down:%s", why);
	if (g_cvMode.IntValue >= 2)
	{
		KickForAuth(client, reason);
	}
	else
	{
		SetGuest(client, reason, g_sSource[client]);
	}
}

void HandleBadTicket(int client, const char[] reason)
{
	g_iStatRejected++;
	LogMessage("%s client %d (%N): ticket rejected (%s) [%s…]", TAG, client, client, reason, g_sTicketHint[client]);

	/* a used ticket on a manual reconnect is the classic innocent case */
	int accountId;
	char dname[CHOGAN_MAX_DISPLAYNAME];
	if (CacheLookup(client, accountId, dname, sizeof(dname)))
	{
		strcopy(g_sSource[client], sizeof(g_sSource[]), "cache");
		BindClient(client, accountId, dname, "ok_cache");
		return;
	}

	if (g_cvInvalidGuest.BoolValue)
	{
		SetGuest(client, reason, g_sSource[client]);
	}
	else
	{
		KickForAuth(client, reason);
	}
}

void BindClient(int client, int accountId, const char[] displayName, const char[] reason)
{
	delete g_hWatchdog[client];
	delete g_hPollTimer[client];
	delete g_hGraceTimer[client];

	g_State[client] = ChoganAuth_Bound;
	g_iAccountId[client] = accountId;
	strcopy(g_sDisplayName[client], sizeof(g_sDisplayName[]), displayName);
	strcopy(g_sReason[client], sizeof(g_sReason[]), reason);

	if (StrContains(reason, "cache") != -1) g_iStatRedeemCached++; else g_iStatRedeemOk++;

	CacheStore(client, accountId, displayName);

	LogMessage("%s client %d (%N): BOUND account_id=%d display=\"%s\" source=%s (%s) in %.2fs",
		TAG, client, client, accountId, displayName, g_sSource[client], reason,
		GetEngineTime() - g_fRedeemStart[client]);

	Call_StartForward(g_fwdBound);
	Call_PushCell(client);
	Call_PushCell(accountId);
	Call_PushString(displayName);
	Call_Finish();

	FireResolved(client, ChoganAuth_Bound, reason);

	PostEvent(client, "join");
	g_bJoinEventSent[client] = true;
}

void SetGuest(int client, const char[] reason, const char[] source)
{
	delete g_hWatchdog[client];
	delete g_hPollTimer[client];
	delete g_hGraceTimer[client];

	g_State[client] = ChoganAuth_Guest;
	g_iAccountId[client] = 0;
	g_sDisplayName[client][0] = '\0';
	strcopy(g_sSource[client], sizeof(g_sSource[]), source);
	strcopy(g_sReason[client], sizeof(g_sReason[]), reason);
	g_iStatGuests++;

	LogMessage("%s client %d (%N): GUEST (%s)", TAG, client, client, reason);
	FireResolved(client, ChoganAuth_Guest, reason);
}

void KickForAuth(int client, const char[] reason)
{
	delete g_hWatchdog[client];
	delete g_hPollTimer[client];
	delete g_hGraceTimer[client];

	g_State[client] = ChoganAuth_Rejected;
	g_iAccountId[client] = 0;
	strcopy(g_sReason[client], sizeof(g_sReason[]), reason);
	g_iStatKicks++;

	char msg[192];
	g_cvKickMsg.GetString(msg, sizeof(msg));

	LogMessage("%s client %d (%N): KICK (%s)", TAG, client, client, reason);
	FireResolved(client, ChoganAuth_Rejected, reason);

	if (IsClientConnected(client) && !IsClientInKickQueue(client))
	{
		/* KickClient() is queued by SourceMod and executed on the next game frame
		 * (core: gamehelpers->AddDelayedKick), so it is safe from a connect forward,
		 * a timer, an HTTP or an SQL callback alike. No RequestFrame needed. */
		KickClient(client, "%s (%s)", msg, reason);
	}
}

void FireResolved(int client, ChoganAuthState state, const char[] reason)
{
	Call_StartForward(g_fwdResolved);
	Call_PushCell(client);
	Call_PushCell(view_as<int>(state));
	Call_PushString(reason);
	Call_Finish();
}

/* ============================================================================ */
/* events (fire and forget)                                                      */

void PostEvent(int client, const char[] event)
{
	if (!g_cvEvents.BoolValue || g_iAccountId[client] <= 0)
	{
		return;
	}
	char ip[48], authid[64], name[MAX_NAME_LENGTH], map[64];
	GetIdentity(client, ip, sizeof(ip), authid, sizeof(authid), name, sizeof(name));
	GetCurrentMap(map, sizeof(map));

	if (g_Transport == Transport_RipExt && g_bRipExt)
	{
		char url[512];
		BuildUrl(url, sizeof(url), "/v1/event");
		JSONObject body = new JSONObject();
		body.SetString("server_id", g_sServerId);
		body.SetString("event", event);
		body.SetInt("account_id", g_iAccountId[client]);
		body.SetString("authid", authid);
		body.SetString("ip", ip);
		body.SetString("name", name);
		body.SetString("map", map);
		HTTPRequest req = new HTTPRequest(url);
		req.ConnectTimeout = 2;
		req.Timeout = 5;
		req.Post(body, OnEventResponse, 0);
		delete body;
	}
	else if (g_Transport == Transport_Sql && g_hDb != null)
	{
		char query[1024];
		g_hDb.Format(query, sizeof(query),
			"INSERT INTO cg_events (server_id, event, account_id, authid, ip, name, map, created_at) VALUES ('%s', '%s', %d, '%s', '%s', '%s', '%s', NOW())",
			g_sServerId, event, g_iAccountId[client], authid, ip, name, map);
		g_hDb.Query(OnSqlFireAndForget, query, 0, DBPrio_Low);
	}
}

public void OnEventResponse(HTTPResponse response, any value, const char[] error)
{
	if (error[0] != '\0')
	{
		Debug("event post failed: %s", error);
	}
}

public void OnSqlFireAndForget(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
	{
		Debug("event insert failed: %s", error);
	}
}

/* ============================================================================ */
/* reconnect cache                                                               */

void CacheKey(int client, char[] key, int maxlen)
{
	char ip[48], authid[64], name[MAX_NAME_LENGTH];
	GetIdentity(client, ip, sizeof(ip), authid, sizeof(authid), name, sizeof(name));
	FormatEx(key, maxlen, "%s|%s", ip, authid);
}

void CacheStore(int client, int accountId, const char[] displayName)
{
	int ttl = g_cvCacheTtl.IntValue;
	if (ttl <= 0 || accountId <= 0)
	{
		return;
	}
	char key[128];
	CacheKey(client, key, sizeof(key));

	int val[2];
	val[0] = accountId;
	val[1] = GetTime() + ttl;
	g_hCacheAcct.SetArray(key, val, sizeof(val));
	g_hCacheName.SetString(key, displayName);

	/* also store under the ip-only key: at reconnect time the auth id is usually not
	 * known yet, so the lookup key would be "<ip>|" */
	char ipOnly[128];
	char ip[48];
	if (GetClientIP(client, ip, sizeof(ip)))
	{
		FormatEx(ipOnly, sizeof(ipOnly), "%s|", ip);
		if (!StrEqual(ipOnly, key))
		{
			g_hCacheAcct.SetArray(ipOnly, val, sizeof(val));
			g_hCacheName.SetString(ipOnly, displayName);
		}
	}
}

bool CacheLookup(int client, int &accountId, char[] displayName, int maxlen)
{
	if (g_cvCacheTtl.IntValue <= 0)
	{
		return false;
	}
	char key[128];
	CacheKey(client, key, sizeof(key));

	int val[2];
	if (!g_hCacheAcct.GetArray(key, val, sizeof(val)))
	{
		return false;
	}
	if (val[1] < GetTime())
	{
		g_hCacheAcct.Remove(key);
		g_hCacheName.Remove(key);
		return false;
	}
	accountId = val[0];
	if (!g_hCacheName.GetString(key, displayName, maxlen))
	{
		displayName[0] = '\0';
	}
	return accountId > 0;
}

public Action Timer_PruneCache(Handle timer)
{
	if (g_hCacheAcct.Size == 0)
	{
		return Plugin_Continue;
	}
	int now = GetTime();
	StringMapSnapshot snap = g_hCacheAcct.Snapshot();
	char key[128];
	int val[2];
	for (int i = 0; i < snap.Length; i++)
	{
		snap.GetKey(i, key, sizeof(key));
		if (g_hCacheAcct.GetArray(key, val, sizeof(val)) && val[1] < now)
		{
			g_hCacheAcct.Remove(key);
			g_hCacheName.Remove(key);
		}
	}
	delete snap;
	return Plugin_Continue;
}

/* ============================================================================ */
/* circuit breaker                                                               */

bool BreakerIsOpen()
{
	if (g_cvBreakerFails.IntValue <= 0)
	{
		return false;
	}
	return GetEngineTime() < g_fBreakerOpenUntil;
}

void BreakerFailure()
{
	int threshold = g_cvBreakerFails.IntValue;
	if (threshold <= 0)
	{
		return;
	}
	g_iBreakerFails++;
	if (g_iBreakerFails >= threshold)
	{
		bool wasOpen = BreakerIsOpen();
		g_fBreakerOpenUntil = GetEngineTime() + g_cvBreakerOpen.FloatValue;
		if (!wasOpen)
		{
			g_iBreakerTrips++;
			LogMessage("%s circuit breaker OPEN for %.0fs after %d consecutive failures — agent will not be called, fallback path applies immediately",
				TAG, g_cvBreakerOpen.FloatValue, g_iBreakerFails);
		}
	}
}

void BreakerSuccess()
{
	if (g_iBreakerFails > 0 || g_fBreakerOpenUntil > 0.0)
	{
		if (g_iBreakerFails >= g_cvBreakerFails.IntValue && g_cvBreakerFails.IntValue > 0)
		{
			LogMessage("%s circuit breaker CLOSED (agent answered)", TAG);
		}
	}
	g_iBreakerFails = 0;
	g_fBreakerOpenUntil = 0.0;
}

/* ============================================================================ */
/* admin                                                                         */

public Action Cmd_Status(int client, int args)
{
	char tname[16];
	TransportNameCopy(g_Transport, tname, sizeof(tname));
	ReplyToCommand(client, "%s v%s mode=%d transport=%s ripext=%d db=%s server_id=\"%s\" breaker=%s(fails=%d trips=%d) cache=%d entries",
		TAG, PLUGIN_VERSION, g_cvMode.IntValue, tname, g_bRipExt, (g_hDb != null) ? "connected" : "no",
		g_sServerId, BreakerIsOpen() ? "OPEN" : "closed", g_iBreakerFails, g_iBreakerTrips, g_hCacheAcct.Size);
	ReplyToCommand(client, "%s totals: ok=%d ok_cache=%d rejected=%d api_down=%d guests=%d kicks=%d",
		TAG, g_iStatRedeemOk, g_iStatRedeemCached, g_iStatRejected, g_iStatApiDown, g_iStatGuests, g_iStatKicks);
	ReplyToCommand(client, "  #userid  name                              state     account  display           source    reason");

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i))
		{
			continue;
		}
		char name[MAX_NAME_LENGTH];
		GetClientName(i, name, sizeof(name));
		ReplyToCommand(client, "  #%-7d %-33s %-9s %-8d %-17s %-9s %s",
			GetClientUserId(i), name, StateName(g_State[i]), g_iAccountId[i],
			g_sDisplayName[i], g_sSource[i], g_sReason[i]);
	}
	return Plugin_Handled;
}

public Action Cmd_Health(int client, int args)
{
	if (!g_bRipExt)
	{
		ReplyToCommand(client, "%s RIPExt not loaded — cannot GET /health (SQL transport db=%s)", TAG, (g_hDb != null) ? "connected" : "no");
		return Plugin_Handled;
	}
	char url[512];
	BuildUrl(url, sizeof(url), "/health");
	HTTPRequest req = new HTTPRequest(url);
	req.ConnectTimeout = 2;
	req.Timeout = 5;
	req.Get(OnHealthResponse, (client > 0) ? GetClientSerial(client) : 0);
	ReplyToCommand(client, "%s GET %s dispatched…", TAG, url);
	return Plugin_Handled;
}

public void OnHealthResponse(HTTPResponse response, any serial, const char[] error)
{
	int status = view_as<int>(response.Status);
	char line[256];
	if (error[0] != '\0' || status == 0)
	{
		FormatEx(line, sizeof(line), "%s /health FAILED: %s", TAG, error);
	}
	else
	{
		FormatEx(line, sizeof(line), "%s /health -> HTTP %d", TAG, status);
	}
	LogMessage("%s", line);
	int client = (serial != 0) ? GetClientFromSerial(serial) : 0;
	if (client > 0 && IsClientInGame(client))
	{
		PrintToConsole(client, "%s", line);
	}
	else
	{
		PrintToServer("%s", line);
	}
}

/* ============================================================================ */
/* natives                                                                       */

public int Native_GetAccountId(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	}
	return g_iAccountId[client];
}

public int Native_GetDisplayName(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	}
	int maxlen = GetNativeCell(3);
	if (g_State[client] != ChoganAuth_Bound)
	{
		SetNativeString(2, "", maxlen);
		return 0;
	}
	SetNativeString(2, g_sDisplayName[client], maxlen);
	return 1;
}

public int Native_GetAuthState(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	}
	return view_as<int>(g_State[client]);
}

public int Native_IsGuest(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);
	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	}
	return (g_State[client] == ChoganAuth_Guest) ? 1 : 0;
}

public int Native_GetServerId(Handle plugin, int numParams)
{
	int maxlen = GetNativeCell(2);
	int bytes;
	SetNativeString(1, g_sServerId, maxlen, true, bytes);
	return bytes;
}

/* ============================================================================ */
/* helpers                                                                       */

char g_sStateNameBuf[12];
char[] StateName(ChoganAuthState s)
{
	switch (s)
	{
		case ChoganAuth_Skipped:  strcopy(g_sStateNameBuf, sizeof(g_sStateNameBuf), "skipped");
		case ChoganAuth_Waiting:  strcopy(g_sStateNameBuf, sizeof(g_sStateNameBuf), "waiting");
		case ChoganAuth_Pending:  strcopy(g_sStateNameBuf, sizeof(g_sStateNameBuf), "pending");
		case ChoganAuth_Bound:    strcopy(g_sStateNameBuf, sizeof(g_sStateNameBuf), "bound");
		case ChoganAuth_Guest:    strcopy(g_sStateNameBuf, sizeof(g_sStateNameBuf), "guest");
		case ChoganAuth_Rejected: strcopy(g_sStateNameBuf, sizeof(g_sStateNameBuf), "rejected");
		default:                  strcopy(g_sStateNameBuf, sizeof(g_sStateNameBuf), "none");
	}
	char out[12];
	strcopy(out, sizeof(out), g_sStateNameBuf);
	return out;
}

void Debug(const char[] fmt, any ...)
{
	if (!g_cvDebug.BoolValue)
	{
		return;
	}
	char buf[512];
	VFormat(buf, sizeof(buf), fmt, 2);
	LogMessage("%s [debug] %s", TAG, buf);
}
