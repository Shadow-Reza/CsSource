/**
 * chogan_auth.sp — Chogan phone-account authentication for CS:Source (MISSION §6.3).
 *
 * Where the ticket comes from (engine fact, docs/source-connect-protocol.md §3):
 *   On this engine the client's userinfo (setinfo keys, incl. `lt`) is NOT in the
 *   connect packet. It arrives as the first net_SetConVar on the netchannel right
 *   after SIGNONSTATE_CONNECTED, i.e. AFTER OnClientConnect/OnClientConnected fired.
 *   So GetClientInfo(client,"lt") is empty in OnClientConnected and becomes readable
 *   at the first OnClientSettingsChanged (certainly by OnClientPutInServer).
 *
 *   Therefore: OnClientConnected arms a grace timer (cg_auth_grace) and TryRedeem()
 *   is attempted at OnClientConnected (completeness/logging), OnClientSettingsChanged,
 *   OnClientAuthorized, OnClientPutInServer and OnClientPostAdminCheck. The first
 *   hook where `lt` is non-empty wins; the `cg_ticket <token>` console command
 *   (MISSION §5 probe 1 fallback (b)) is a second channel. A ticket is NEVER
 *   redeemed twice on one connection (g_bTicketTried).
 *
 * Flow:
 *   ticket ─► POST {cg_agent_url}/v1/redeem (RIPExt, async) or INSERT+poll
 *   cg_auth_requests (threaded MySQL, async) ─► callback resolves the client by
 *   SERIAL (MISSION §4.5) ─► bind account (natives + Chogan_OnAccountBound) or
 *   KickClient() (SM queues the kick to the next frame; from inside a client
 *   forward / command we additionally go through RequestFrame).
 *
 * Modes (cg_auth_mode): 0 off · 1 soft (agent failure ⇒ cache ⇒ guest) · 2 hard
 * (agent failure ⇒ cache ⇒ kick). A REJECTED ticket (invalid/used/expired/scope) is
 * not an agent failure: it kicks in both modes unless cg_auth_allow_invalid_as_guest 1.
 * No ticket within cg_auth_grace: soft ⇒ guest, hard ⇒ kick. No answer within
 * cg_auth_timeout ⇒ treated as api_down. Fail open, not closed (MISSION §6.3).
 *
 * Reconnect: authid+ip → account cache (cg_auth_cache_ttl, default 600 s) on top of
 * the agent's own cache, so a manual reconnect that re-presents an already-redeemed
 * ticket is not kicked. Circuit breaker: after cg_auth_breaker_fails consecutive
 * transport failures the agent is not called for cg_auth_breaker_open seconds and
 * the fallback path applies immediately (half-open after that: one trial request).
 *
 * NEVER blocking: no SQL_Query/SQL_FastQuery, no synchronous HTTP (MISSION §4.4).
 *
 * Contract with cg-agent (cg-agent/types.go, cg-agent/server.go in this repo):
 *   POST /v1/redeem {"ticket","server_id","ip","authid","name"}
 *     200 {"ok":true,"account_id":N,"display_name":"…","source":"api|cache|stub|local","cache_hit":b,"api_down":b}
 *     200 {"ok":false,"reason":"invalid|expired|used|scope|api_down","cache_hit":b,"api_down":b}
 *     400 = plugin bug (malformed / missing server_id), 5xx = agent bug ⇒ both api_down here
 *   POST /v1/event  {"server_id","account_id","type":"join|leave","payload":{…}} → 202
 *   GET  /health    → 200 always; .status "ok" | "degraded"
 *   SQL transport (plugins/sql/chogan_auth.sql): plugin INSERTs cg_auth_requests
 *     (ticket, server_id, ip, authid, name, created_at); agent sets verdict 'ok'|'fail',
 *     account_id, display_name, reason, api_down, resolved_at; plugin polls by id.
 *
 * Config file: cfg/sourcemod/chogan.cfg (AutoExecConfig name "chogan" — the same file
 * css-genconf renders per instance with cg_server_id / cg_agent_url / cg_auth_mode /
 * cg_auth_transport; missing cvars keep their defaults).
 *
 * SourceMod 1.12 (pinned 1.12.0-git7179, docs/decisions.md D-005), RIPExt 1.3.2
 * (optional at load time; required for transport "ripext").
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

/* RIPExt is optional at load time so the SQL transport works on a box where rip.ext is
 * absent or broken. Every RIPExt native we use is marked optional in AskPluginLoad2
 * and only called when LibraryExists("ripext") is true. */
#undef REQUIRE_EXTENSIONS
#include <ripext>
#define REQUIRE_EXTENSIONS

/* we ARE chogan_auth: do not declare a SharedPlugin dependency on ourselves */
#define CHOGAN_AUTH_IMPLEMENTATION
#include <chogan>

#define PLUGIN_VERSION  CHOGAN_AUTH_VERSION
#define CG_TAG          "[chogan_auth]"
#define CG_CFG_NAME     "chogan"   /* cfg/sourcemod/chogan.cfg */
#define TICKET_MAX      512        /* userinfo values are capped at 260 bytes; cg_ticket may carry more */

enum CgTransport
{
	CgTransport_None = 0,
	CgTransport_RipExt,
	CgTransport_Sql
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

/* ------------------------------------------------------------------------- per-client state */
ChoganAuthState g_State[MAXPLAYERS + 1];
int    g_iSerial[MAXPLAYERS + 1];                          /* captured at OnClientConnected */
int    g_iAccountId[MAXPLAYERS + 1];
char   g_sDisplayName[MAXPLAYERS + 1][CHOGAN_MAX_DISPLAYNAME];
char   g_sSource[MAXPLAYERS + 1][16];                      /* setinfo | cmd | cache | lateload | none | - */
char   g_sReason[MAXPLAYERS + 1][48];
char   g_sTicketHint[MAXPLAYERS + 1][12];                  /* first chars of the ticket, logs only */
bool   g_bTicketTried[MAXPLAYERS + 1];                     /* a ticket was sent for redemption on this connection */
bool   g_bLateLoadClient[MAXPLAYERS + 1];                  /* already connected when the plugin loaded: never kick */
bool   g_bLateVerdict[MAXPLAYERS + 1];                     /* watchdog resolved; a late callback may still apply */
float  g_fConnectedAt[MAXPLAYERS + 1];
float  g_fRedeemStart[MAXPLAYERS + 1];
Handle g_hGraceTimer[MAXPLAYERS + 1];
Handle g_hWatchdog[MAXPLAYERS + 1];
Handle g_hPollTimer[MAXPLAYERS + 1];
int    g_iSqlRowId[MAXPLAYERS + 1];
bool   g_bSqlInFlight[MAXPLAYERS + 1];
int    g_iSqlPollErrors[MAXPLAYERS + 1];
bool   g_bJoinEventSent[MAXPLAYERS + 1];

/* ------------------------------------------------------------------------- globals */
CgTransport g_Transport = CgTransport_None;
bool        g_bRipExt = false;
Database    g_hDb = null;
bool        g_bDbConnecting = false;
char        g_sServerId[64];
bool        g_bLateLoad = false;
int         g_iSyncDepth = 0;   /* > 0 while inside a client forward / client command: kick via RequestFrame */

/* circuit breaker */
int   g_iBreakerFails = 0;
float g_fBreakerOpenUntil = 0.0;
int   g_iBreakerTrips = 0;

/* reconnect cache: key "<ip>|<authid>" (and "<ip>|") -> {account_id, expires_at(unix)} + display name */
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
	description = "Redeems the launcher ticket (setinfo lt / cg_ticket) against cg-agent; binds account or kicks",
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

	/* RIPExt natives used below — optional so the plugin loads without rip.ext.
	 * Names as registered in sm-ripext 1.3.2 http_natives.cpp / json_natives.cpp. */
	MarkNativeAsOptional("HTTPRequest.HTTPRequest");
	MarkNativeAsOptional("HTTPRequest.SetHeader");
	MarkNativeAsOptional("HTTPRequest.Get");
	MarkNativeAsOptional("HTTPRequest.Post");
	MarkNativeAsOptional("HTTPRequest.ConnectTimeout.get");
	MarkNativeAsOptional("HTTPRequest.ConnectTimeout.set");
	MarkNativeAsOptional("HTTPRequest.Timeout.get");
	MarkNativeAsOptional("HTTPRequest.Timeout.set");
	MarkNativeAsOptional("HTTPRequest.MaxRedirects.get");
	MarkNativeAsOptional("HTTPRequest.MaxRedirects.set");
	MarkNativeAsOptional("HTTPResponse.Status.get");
	MarkNativeAsOptional("HTTPResponse.Data.get");
	MarkNativeAsOptional("HTTPResponse.GetHeader");
	MarkNativeAsOptional("JSONObject.JSONObject");
	MarkNativeAsOptional("JSONObject.Set");
	MarkNativeAsOptional("JSONObject.SetString");
	MarkNativeAsOptional("JSONObject.SetInt");
	MarkNativeAsOptional("JSONObject.SetBool");
	MarkNativeAsOptional("JSONObject.GetBool");
	MarkNativeAsOptional("JSONObject.GetInt");
	MarkNativeAsOptional("JSONObject.GetInt64");
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
		"0 = off, 1 = soft (agent failure -> cache -> guest), 2 = hard (agent failure -> cache -> kick)",
		FCVAR_NONE, true, 0.0, true, 2.0);
	g_cvAgentUrl = CreateConVar("cg_agent_url", "http://127.0.0.1:8480",
		"Base URL of the local cg-agent (no trailing slash)", FCVAR_NONE);
	g_cvServerId = CreateConVar("cg_server_id", "",
		"REQUIRED. Server id the launcher tickets are scoped to (pub1, pub2, dm, gg, awp, m1, m2)", FCVAR_NONE);
	g_cvTimeout = CreateConVar("cg_auth_timeout", "4.0",
		"Seconds to wait for the agent (HTTP timeout / SQL poll deadline) before taking the api_down path",
		FCVAR_NONE, true, 0.5, true, 60.0);
	g_cvGrace = CreateConVar("cg_auth_grace", "8.0",
		"Seconds after connect the client has to present a ticket (setinfo lt or cg_ticket) before the no-ticket policy applies",
		FCVAR_NONE, true, 1.0, true, 120.0);
	g_cvTransport = CreateConVar("cg_auth_transport", "ripext",
		"Transport to cg-agent: \"ripext\" (async HTTP, default) or \"sql\" (threaded MySQL via databases.cfg section \"chogan\")",
		FCVAR_NONE);
	g_cvKickMsg = CreateConVar("cg_auth_kick_msg", "Chogan: login required - please start the game from the Chogan launcher",
		"Kick reason shown to the client (the engine appends a period)", FCVAR_NONE);
	g_cvInvalidGuest = CreateConVar("cg_auth_allow_invalid_as_guest", "0",
		"1 = a rejected ticket (invalid/used/expired/scope) lets the client in as guest instead of kicking",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvCacheTtl = CreateConVar("cg_auth_cache_ttl", "600",
		"Seconds an authid+ip -> account cache entry stays valid (reconnect / agent-down fallback); 0 disables",
		FCVAR_NONE, true, 0.0, true, 86400.0);
	g_cvBreakerFails = CreateConVar("cg_auth_breaker_fails", "3",
		"Consecutive transport failures that open the circuit breaker (0 = disabled)",
		FCVAR_NONE, true, 0.0, true, 100.0);
	g_cvBreakerOpen = CreateConVar("cg_auth_breaker_open", "20.0",
		"Seconds the breaker stays open (agent not called, fallback path applies immediately); then one trial request",
		FCVAR_NONE, true, 1.0, true, 600.0);
	g_cvEvents = CreateConVar("cg_auth_events", "1",
		"1 = post join/leave events for bound accounts to the agent (fire and forget)",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvDebug = CreateConVar("cg_auth_debug", "0",
		"1 = verbose logging of every step", FCVAR_NONE, true, 0.0, true, 1.0);

	g_cvTransport.AddChangeHook(OnTransportCvarChanged);
	g_cvServerId.AddChangeHook(OnServerIdCvarChanged);

	/* cfg/sourcemod/chogan.cfg — rendered per instance by css-genconf; created with
	 * defaults if it does not exist. */
	AutoExecConfig(true, CG_CFG_NAME);

	RegConsoleCmd("cg_ticket", Cmd_Ticket,
		"Present the Chogan login ticket by console command (fallback to setinfo lt): cg_ticket <token>");
	RegAdminCmd("sm_cgauth", Cmd_Status, ADMFLAG_GENERIC,
		"Show Chogan auth status of every client (account, source, guest) and plugin health");
	RegAdminCmd("sm_cgauth_health", Cmd_Health, ADMFLAG_GENERIC,
		"Async GET {cg_agent_url}/health and log the result");
	RegAdminCmd("sm_cgauth_flushcache", Cmd_FlushCache, ADMFLAG_RCON,
		"Drop the in-plugin authid+ip -> account reconnect cache");

	g_fwdBound    = new GlobalForward("Chogan_OnAccountBound", ET_Ignore, Param_Cell, Param_Cell, Param_String);
	g_fwdResolved = new GlobalForward("Chogan_OnAuthResolved", ET_Ignore, Param_Cell, Param_Cell, Param_String);

	g_hCacheAcct = new StringMap();
	g_hCacheName = new StringMap();

	for (int i = 1; i <= MaxClients; i++)
	{
		ResetClient(i);
	}

	g_bRipExt = LibraryExists("ripext");
	g_cvServerId.GetString(g_sServerId, sizeof(g_sServerId));
	TrimString(g_sServerId);

	CreateTimer(60.0, Timer_PruneCache, _, TIMER_REPEAT);

	LogMessage("%s v%s loaded (late=%d, ripext=%d)", CG_TAG, PLUGIN_VERSION, g_bLateLoad, g_bRipExt);
}

public void OnAllPluginsLoaded()
{
	if (g_bLateLoad)
	{
		/* give AutoExecConfig / OnConfigsExecuted one moment to settle the transport,
		 * then deal with everybody who is already connected */
		CreateTimer(1.0, Timer_LateLoad);
	}
}

public Action Timer_LateLoad(Handle timer)
{
	int n = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i) || IsFakeClient(i))
		{
			continue;
		}
		if (g_State[i] != ChoganAuth_None)
		{
			continue; /* connected after we loaded: handled by OnClientConnected */
		}
		/* Late load (plugin (re)load mid-session). Their `lt` is still in the userinfo,
		 * so we try to redeem it once more: the agent answers from its ticket cache for
		 * a recent redemption (ok), or "used" when that cache expired. A late-load
		 * client is NEVER kicked — every failure path becomes guest. They re-auth on
		 * their next connect. */
		ResetClient(i);
		g_bLateLoadClient[i] = true;
		g_iSerial[i] = GetClientSerial(i);
		g_fConnectedAt[i] = GetEngineTime();
		if (g_cvMode.IntValue == 0)
		{
			g_State[i] = ChoganAuth_Skipped;
			strcopy(g_sReason[i], sizeof(g_sReason[]), "mode_off");
			continue;
		}
		g_State[i] = ChoganAuth_Waiting;
		strcopy(g_sSource[i], sizeof(g_sSource[]), "lateload");
		g_hGraceTimer[i] = CreateTimer(g_cvGrace.FloatValue, Timer_Grace, g_iSerial[i]);
		TryRedeem(i, "lateload");
		n++;
	}
	if (n > 0)
	{
		LogMessage("%s late load: %d already-connected client(s) re-evaluated (never kicked; failures => guest)", CG_TAG, n);
	}
	return Plugin_Stop;
}

public void OnConfigsExecuted()
{
	g_cvServerId.GetString(g_sServerId, sizeof(g_sServerId));
	TrimString(g_sServerId);
	if (g_sServerId[0] == '\0')
	{
		LogError("%s cg_server_id is EMPTY - set it in cfg/sourcemod/%s.cfg. Every redeem takes the api_down path (soft mode => guests).",
			CG_TAG, CG_CFG_NAME);
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

	CgTransport before = g_Transport;

	if (StrEqual(want, "sql", false))
	{
		g_Transport = CgTransport_Sql;
		if (g_hDb == null)
		{
			ConnectDb();
		}
	}
	else
	{
		if (!StrEqual(want, "ripext", false))
		{
			LogError("%s cg_auth_transport \"%s\" unknown - using \"ripext\"", CG_TAG, want);
		}
		if (g_bRipExt)
		{
			g_Transport = CgTransport_RipExt;
		}
		else if (SQL_CheckConfig("chogan"))
		{
			LogError("%s RIPExt (rip.ext) is not loaded - falling back to the SQL transport (databases.cfg \"chogan\")", CG_TAG);
			g_Transport = CgTransport_Sql;
			if (g_hDb == null)
			{
				ConnectDb();
			}
		}
		else
		{
			LogError("%s RIPExt is not loaded and databases.cfg has no \"chogan\" section - NO TRANSPORT. Every redeem takes the api_down path.", CG_TAG);
			g_Transport = CgTransport_None;
		}
	}

	if (before != g_Transport)
	{
		char tname[16];
		TransportNameCopy(g_Transport, tname, sizeof(tname));
		LogMessage("%s transport = %s", CG_TAG, tname);
	}
}

void TransportNameCopy(CgTransport t, char[] buf, int maxlen)
{
	switch (t)
	{
		case CgTransport_RipExt: strcopy(buf, maxlen, "ripext");
		case CgTransport_Sql:    strcopy(buf, maxlen, "sql");
		default:                 strcopy(buf, maxlen, "none");
	}
}

/* ============================================================================ */
/* client lifecycle                                                              */

public void OnClientConnected(int client)
{
	ResetClient(client);
	g_iSerial[client] = GetClientSerial(client);
	g_fConnectedAt[client] = GetEngineTime();

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
	g_hGraceTimer[client] = CreateTimer(g_cvGrace.FloatValue, Timer_Grace, g_iSerial[client]);

	DbgLog("client %d serial %d (%N) connected: waiting for ticket (grace %.1fs)",
		client, g_iSerial[client], client, g_cvGrace.FloatValue);

	/* Expected to find nothing here (userinfo not received yet, see header) — logged
	 * for completeness so docs/probes.md can cite it. */
	SyncTryRedeem(client, "OnClientConnected");
}

public void OnClientSettingsChanged(int client)
{
	if (client >= 1 && client <= MaxClients)
	{
		SyncTryRedeem(client, "OnClientSettingsChanged");
	}
}

public void OnClientAuthorized(int client, const char[] auth)
{
	SyncTryRedeem(client, "OnClientAuthorized");
}

public void OnClientPutInServer(int client)
{
	SyncTryRedeem(client, "OnClientPutInServer");
}

public void OnClientPostAdminCheck(int client)
{
	SyncTryRedeem(client, "OnClientPostAdminCheck");

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
			g_hWatchdog[i] = CreateTimer(g_cvTimeout.FloatValue + 1.0, Timer_Watchdog, GetClientSerial(i));
		}
	}
}

void ResetClient(int client)
{
	g_State[client] = ChoganAuth_None;
	g_iSerial[client] = 0;
	g_iAccountId[client] = 0;
	g_sDisplayName[client][0] = '\0';
	strcopy(g_sSource[client], sizeof(g_sSource[]), "-");
	g_sReason[client][0] = '\0';
	g_sTicketHint[client][0] = '\0';
	g_bTicketTried[client] = false;
	g_bLateLoadClient[client] = false;
	g_bLateVerdict[client] = false;
	g_fConnectedAt[client] = 0.0;
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

/** TryRedeem from a synchronous client forward / client command: kicks decided in
 *  here are deferred with RequestFrame (see KickForAuth). */
void SyncTryRedeem(int client, const char[] where)
{
	g_iSyncDepth++;
	TryRedeem(client, where);
	g_iSyncDepth--;
}

/** May a (new) redemption start for this client right now? */
bool CanStartRedeem(int client)
{
	if (client < 1 || client > MaxClients || !IsClientConnected(client))
	{
		return false;
	}
	if (g_bTicketTried[client])
	{
		return false; /* never redeem twice on one connection */
	}
	if (g_State[client] == ChoganAuth_Waiting)
	{
		return true;
	}
	/* soft-mode guest who never presented a ticket (grace expired): a late
	 * cg_ticket may still bind the account */
	if (g_State[client] == ChoganAuth_Guest)
	{
		return true;
	}
	return false;
}

/** Read `lt` from the userinfo; start the redemption the first time it is non-empty. */
void TryRedeem(int client, const char[] where)
{
	if (!CanStartRedeem(client))
	{
		return;
	}
	char token[TICKET_MAX];
	if (!GetClientInfo(client, "lt", token, sizeof(token)))
	{
		DbgLog("client %d: lt not readable at %s", client, where);
		return;
	}
	TrimString(token);
	if (token[0] == '\0')
	{
		DbgLog("client %d: lt empty at %s", client, where);
		return;
	}
	StartRedeem(client, token, "setinfo", where);
}

public Action Cmd_Ticket(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%s cg_ticket is a client command.", CG_TAG);
		return Plugin_Handled;
	}
	if (!IsClientConnected(client))
	{
		return Plugin_Handled;
	}
	if (IsFakeClient(client))
	{
		return Plugin_Handled;
	}
	if (!CanStartRedeem(client))
	{
		char st[12];
		StateNameCopy(g_State[client], st, sizeof(st));
		ReplyToCommand(client, "%s ticket ignored (state=%s, tried=%d).", CG_TAG, st, g_bTicketTried[client]);
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
		ReplyToCommand(client, "%s usage: cg_ticket <token>", CG_TAG);
		return Plugin_Handled;
	}

	g_iSyncDepth++;
	StartRedeem(client, token, "cmd", "cg_ticket");
	g_iSyncDepth--;

	ReplyToCommand(client, "%s ticket received, verifying...", CG_TAG);
	return Plugin_Handled;
}

public Action Timer_Grace(Handle timer, any serial)
{
	int client = GetClientFromSerial(serial);
	if (client <= 0)
	{
		return Plugin_Stop; /* client gone; ResetClient already dropped our handle */
	}
	g_hGraceTimer[client] = null;

	if (g_State[client] != ChoganAuth_Waiting)
	{
		return Plugin_Stop; /* ticket arrived meanwhile */
	}

	/* one last look at the userinfo before deciding */
	TryRedeem(client, "grace-expiry");
	if (g_State[client] != ChoganAuth_Waiting)
	{
		return Plugin_Stop;
	}

	LogMessage("%s client %d (%N): no ticket within %.1fs (neither setinfo lt nor cg_ticket) - mode=%d",
		CG_TAG, client, client, g_cvGrace.FloatValue, g_cvMode.IntValue);

	if (g_bLateLoadClient[client])
	{
		SetGuest(client, "no_ticket", "lateload");
	}
	else if (g_cvMode.IntValue >= 2)
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

void StartRedeem(int client, const char[] ticket, const char[] source, const char[] where)
{
	g_bTicketTried[client] = true;
	g_bLateVerdict[client] = false;
	g_State[client] = ChoganAuth_Pending;
	strcopy(g_sSource[client], sizeof(g_sSource[]), source);
	strcopy(g_sTicketHint[client], sizeof(g_sTicketHint[]), ticket); /* truncates to 11 chars */
	g_fRedeemStart[client] = GetEngineTime();

	delete g_hGraceTimer[client];
	/* the watchdog is the safety net for a callback that never fires or throws */
	delete g_hWatchdog[client];
	g_hWatchdog[client] = CreateTimer(g_cvTimeout.FloatValue + 1.0, Timer_Watchdog, GetClientSerial(client));

	char tname[16];
	TransportNameCopy(g_Transport, tname, sizeof(tname));
	LogMessage("%s client %d (%N): ticket via %s at %s (%d bytes, %.3fs after connect) -> redeem [transport=%s]",
		CG_TAG, client, client, source, where, strlen(ticket),
		GetEngineTime() - g_fConnectedAt[client], tname);

	if (g_sServerId[0] == '\0')
	{
		HandleApiDown(client, "no_server_id", false);
		return;
	}
	if (BreakerIsOpen())
	{
		DbgLog("client %d: breaker open, skipping agent", client);
		HandleApiDown(client, "breaker_open", false);
		return;
	}

	switch (g_Transport)
	{
		case CgTransport_RipExt: SendRedeemHttp(client, ticket);
		case CgTransport_Sql:    SendRedeemSql(client, ticket);
		default:                 HandleApiDown(client, "no_transport", false);
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
		LogMessage("%s client %d (%N): redeem still pending after %.1fs - watchdog takes the api_down path",
			CG_TAG, client, client, GetEngineTime() - g_fRedeemStart[client]);
		g_bLateVerdict[client] = true;
		HandleApiDown(client, "timeout", true);
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
	 * false while the client is not authorized yet (SM has no auth string before
	 * OnClientAuthorized) — that is normal early in the connect. */
	if (!GetClientAuthId(client, AuthId_Steam2, authid, authlen))
	{
		if (!GetClientAuthId(client, AuthId_Engine, authid, authlen))
		{
			authid[0] = '\0';
		}
	}
	if (StrEqual(authid, "STEAM_ID_PENDING") || StrEqual(authid, "STEAM_ID_LAN") || StrEqual(authid, "BOT"))
	{
		authid[0] = '\0';
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
	if (!g_bRipExt)
	{
		HandleApiDown(client, "ripext_missing", false);
		return;
	}

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

	HTTPRequest req = new HTTPRequest(url);
	req.ConnectTimeout = 2;
	req.Timeout = RoundToCeil(g_cvTimeout.FloatValue);
	req.SetHeader("Accept", "application/json");
	req.Post(body, OnRedeemResponse, GetClientSerial(client)); /* request handle is freed by RIPExt */
	delete body;                                                /* body was serialised inside Post() */

	DbgLog("client %d: POST %s (authid=\"%s\" ip=%s)", client, url, authid, ip);
}

/**
 * RIPExt always invokes the callback (also on transport failure: then Status == 0 and
 * `error` holds the cURL message). HTTPResponse.Data throws on a non-JSON body, so
 * the content type is checked first. Runs on the game thread (RIPExt frame hook).
 */
public void OnRedeemResponse(HTTPResponse response, any serial, const char[] error)
{
	int client = GetClientFromSerial(serial);
	if (client <= 0)
	{
		return; /* slot reused or client gone - never touch by index (MISSION §4.5) */
	}

	bool late = (g_State[client] != ChoganAuth_Pending);
	if (late && !(g_State[client] == ChoganAuth_Guest && g_bLateVerdict[client]))
	{
		return; /* already resolved by something else (disconnect, kick, lateload guest) */
	}

	int status = view_as<int>(response.Status);

	if (error[0] != '\0' || status == 0)
	{
		char why[128];
		if (error[0] != '\0')
		{
			FormatEx(why, sizeof(why), "transport:%s", error);
		}
		else
		{
			strcopy(why, sizeof(why), "transport:status0");
		}
		if (!late)
		{
			HandleApiDown(client, why, true);
		}
		else
		{
			DbgLog("client %d: late transport failure ignored (%s)", client, why);
		}
		return;
	}
	if (status >= 500 || status == 400)
	{
		char why[32];
		FormatEx(why, sizeof(why), "http_%d", status);
		if (!late)
		{
			HandleApiDown(client, why, true);
		}
		return;
	}

	char ctype[96];
	if (!response.GetHeader("Content-Type", ctype, sizeof(ctype)) || StrContains(ctype, "json", false) == -1)
	{
		char why[64];
		FormatEx(why, sizeof(why), "non_json_http_%d", status);
		if (!late)
		{
			HandleApiDown(client, why, true);
		}
		return;
	}

	JSONObject data = view_as<JSONObject>(response.Data); /* owned by RIPExt, do not delete */
	if (data == null || !data.HasKey("ok"))
	{
		char why[64];
		FormatEx(why, sizeof(why), "bad_body_http_%d", status);
		if (!late)
		{
			HandleApiDown(client, why, true);
		}
		return;
	}

	if (data.GetBool("ok"))
	{
		int accountId = 0;
		if (data.HasKey("account_id") && !data.IsNull("account_id"))
		{
			accountId = data.GetInt("account_id");
			if (accountId <= 0)
			{
				char tmp[32];
				if (data.GetInt64("account_id", tmp, sizeof(tmp)))
				{
					accountId = StringToInt(tmp);
				}
			}
		}
		char dname[CHOGAN_MAX_DISPLAYNAME];
		if (!data.GetString("display_name", dname, sizeof(dname)))
		{
			dname[0] = '\0';
		}
		char src[16];
		if (!data.GetString("source", src, sizeof(src)))
		{
			src[0] = '\0';
		}
		bool cacheHit = data.HasKey("cache_hit") && !data.IsNull("cache_hit") && data.GetBool("cache_hit");

		if (accountId <= 0)
		{
			if (!late)
			{
				HandleApiDown(client, "ok_without_account_id", true);
			}
			return;
		}
		BreakerSuccess();

		char reason[32];
		if (cacheHit || StrEqual(src, "cache"))
		{
			strcopy(reason, sizeof(reason), "ok_agent_cache");
		}
		else if (src[0] != '\0')
		{
			FormatEx(reason, sizeof(reason), "ok_%s", src);
		}
		else
		{
			strcopy(reason, sizeof(reason), "ok");
		}
		if (late)
		{
			LogMessage("%s client %d (%N): late agent answer after watchdog - upgrading guest to account", CG_TAG, client, client);
		}
		BindClient(client, accountId, dname, reason);
		return;
	}

	char reason[32];
	if (!data.GetString("reason", reason, sizeof(reason)) || reason[0] == '\0')
	{
		strcopy(reason, sizeof(reason), "rejected");
	}
	bool apiDown = data.HasKey("api_down") && !data.IsNull("api_down") && data.GetBool("api_down");

	if (apiDown || IsApiFailureReason(reason))
	{
		if (!late)
		{
			HandleApiDown(client, reason, true);
		}
	}
	else
	{
		BreakerSuccess(); /* the agent answered - transport is healthy */
		if (late)
		{
			LogMessage("%s client %d (%N): late agent verdict after watchdog: %s", CG_TAG, client, client, reason);
		}
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
		LogError("%s databases.cfg has no \"chogan\" section - SQL transport unavailable", CG_TAG);
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
		LogError("%s database connect failed: %s (retry in 30s)", CG_TAG, error);
		CreateTimer(30.0, Timer_DbRetry);
		return;
	}
	delete g_hDb;
	g_hDb = db;
	g_hDb.SetCharset("utf8mb4");
	LogMessage("%s database \"chogan\" connected (SQL transport ready)", CG_TAG);
}

public Action Timer_DbRetry(Handle timer)
{
	if (g_hDb == null && g_Transport == CgTransport_Sql)
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
		HandleApiDown(client, "sql_not_connected", true);
		return;
	}

	char ip[48], authid[64], name[MAX_NAME_LENGTH];
	GetIdentity(client, ip, sizeof(ip), authid, sizeof(authid), name, sizeof(name));

	/* Database.Format escapes every %s argument (SM 1.10+), so this is injection-safe. */
	char query[1400];
	g_hDb.Format(query, sizeof(query),
		"INSERT INTO cg_auth_requests (ticket, server_id, ip, authid, name, created_at) VALUES ('%s', '%s', '%s', '%s', '%s', NOW())",
		ticket, g_sServerId, ip, authid, name);
	g_hDb.Query(OnSqlInsert, query, GetClientSerial(client));
	DbgLog("client %d: SQL request row inserting", client);
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
		LogError("%s SQL insert failed: %s", CG_TAG, error);
		HandleApiDown(client, "sql_insert_failed", true);
		return;
	}
	g_iSqlRowId[client] = results.InsertId;
	g_bSqlInFlight[client] = false;
	g_iSqlPollErrors[client] = 0;
	delete g_hPollTimer[client];
	g_hPollTimer[client] = CreateTimer(0.5, Timer_SqlPoll, serial, TIMER_REPEAT);
	DbgLog("client %d: SQL request row id=%d, polling every 0.5s", client, g_iSqlRowId[client]);
}

public Action Timer_SqlPoll(Handle timer, any serial)
{
	int client = GetClientFromSerial(serial);
	if (client <= 0)
	{
		return Plugin_Stop; /* ResetClient already dropped our handle */
	}
	if (g_State[client] != ChoganAuth_Pending)
	{
		g_hPollTimer[client] = null;
		return Plugin_Stop;
	}
	if (GetEngineTime() - g_fRedeemStart[client] > g_cvTimeout.FloatValue)
	{
		g_hPollTimer[client] = null;
		g_bLateVerdict[client] = true;
		HandleApiDown(client, "sql_timeout", true);
		return Plugin_Stop;
	}
	if (g_bSqlInFlight[client] || g_hDb == null)
	{
		return Plugin_Continue;
	}
	g_bSqlInFlight[client] = true;

	char query[256];
	FormatEx(query, sizeof(query),
		"SELECT verdict, account_id, display_name, reason, api_down, source, cache_hit FROM cg_auth_requests WHERE id = %d AND verdict IS NOT NULL",
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

	bool late = (g_State[client] != ChoganAuth_Pending);
	if (late && !(g_State[client] == ChoganAuth_Guest && g_bLateVerdict[client]))
	{
		return;
	}
	if (results == null)
	{
		g_iSqlPollErrors[client]++;
		LogError("%s SQL poll failed (%d): %s", CG_TAG, g_iSqlPollErrors[client], error);
		if (!late && g_iSqlPollErrors[client] >= 3)
		{
			delete g_hPollTimer[client];
			HandleApiDown(client, "sql_poll_failed", true);
		}
		return;
	}
	if (!results.FetchRow())
	{
		return; /* no verdict yet - keep polling */
	}

	delete g_hPollTimer[client];

	char verdict[16], dname[CHOGAN_MAX_DISPLAYNAME], reason[32];
	results.FetchString(0, verdict, sizeof(verdict));
	int accountId = 0;
	if (!results.IsFieldNull(1))
	{
		accountId = results.FetchInt(1);
	}
	dname[0] = '\0';
	if (!results.IsFieldNull(2))
	{
		results.FetchString(2, dname, sizeof(dname));
	}
	reason[0] = '\0';
	if (!results.IsFieldNull(3))
	{
		results.FetchString(3, reason, sizeof(reason));
	}
	bool apiDown = false;
	if (!results.IsFieldNull(4))
	{
		apiDown = (results.FetchInt(4) != 0);
	}
	char src[16];
	src[0] = ' ';
	if (!results.IsFieldNull(5))
	{
		results.FetchString(5, src, sizeof(src));
	}
	bool cacheHit = false;
	if (!results.IsFieldNull(6))
	{
		cacheHit = (results.FetchInt(6) != 0);
	}

	if (StrEqual(verdict, "ok", false) && accountId > 0)
	{
		BreakerSuccess();
		char why[32];
		if (cacheHit || StrEqual(src, "cache", false))
		{
			strcopy(why, sizeof(why), "ok_agent_cache");
		}
		else if (src[0] != ' ')
		{
			FormatEx(why, sizeof(why), "ok_%s", src);
		}
		else
		{
			strcopy(why, sizeof(why), "ok");
		}
		BindClient(client, accountId, dname, why);
	}
	else if (StrEqual(verdict, "ok", false))
	{
		if (!late)
		{
			HandleApiDown(client, "ok_without_account_id", true);
		}
	}
	else if (reason[0] == '\0')
	{
		if (!late)
		{
			HandleApiDown(client, "sql_verdict_without_reason", true);
		}
	}
	else if (apiDown || IsApiFailureReason(reason))
	{
		if (!late)
		{
			HandleApiDown(client, reason, true);
		}
	}
	else
	{
		BreakerSuccess();
		HandleBadTicket(client, reason);
	}
}

/* ============================================================================ */
/* decisions                                                                     */

/**
 * Agent unreachable / no verdict. `transportFailure` feeds the circuit breaker; the
 * synthetic cases (breaker already open, no transport configured, no server id) do not,
 * otherwise the breaker would never half-open while clients keep connecting.
 */
void HandleApiDown(int client, const char[] why, bool transportFailure)
{
	g_iStatApiDown++;
	if (transportFailure)
	{
		BreakerFailure();
	}
	LogMessage("%s client %d (%N): agent unavailable (%s) after %.2fs - mode=%d",
		CG_TAG, client, client, why, GetEngineTime() - g_fRedeemStart[client], g_cvMode.IntValue);

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
	if (g_bLateLoadClient[client])
	{
		SetGuest(client, reason, "lateload");
	}
	else if (g_cvMode.IntValue >= 2)
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
	LogMessage("%s client %d (%N): ticket rejected (%s) [%s...]", CG_TAG, client, client, reason, g_sTicketHint[client]);

	/* a used ticket on a manual reconnect is the classic innocent case */
	int accountId;
	char dname[CHOGAN_MAX_DISPLAYNAME];
	if (CacheLookup(client, accountId, dname, sizeof(dname)))
	{
		strcopy(g_sSource[client], sizeof(g_sSource[]), "cache");
		BindClient(client, accountId, dname, "ok_cache");
		return;
	}

	if (g_bLateLoadClient[client])
	{
		SetGuest(client, reason, "lateload");
	}
	else if (g_cvInvalidGuest.BoolValue)
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
	g_bLateVerdict[client] = false;
	g_iAccountId[client] = accountId;
	strcopy(g_sDisplayName[client], sizeof(g_sDisplayName[]), displayName);
	strcopy(g_sReason[client], sizeof(g_sReason[]), reason);

	if (StrContains(reason, "cache") != -1)
	{
		g_iStatRedeemCached++;
	}
	else
	{
		g_iStatRedeemOk++;
	}

	CacheStore(client, accountId, displayName);

	LogMessage("%s client %d (%N): BOUND account_id=%d display=\"%s\" source=%s (%s) in %.2fs",
		CG_TAG, client, client, accountId, displayName, g_sSource[client], reason,
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

	LogMessage("%s client %d (%N): GUEST (%s)", CG_TAG, client, client, reason);
	FireResolved(client, ChoganAuth_Guest, reason);
}

void KickForAuth(int client, const char[] reason)
{
	delete g_hWatchdog[client];
	delete g_hPollTimer[client];
	delete g_hGraceTimer[client];

	g_State[client] = ChoganAuth_Rejected;
	g_bLateVerdict[client] = false;
	g_iAccountId[client] = 0;
	strcopy(g_sReason[client], sizeof(g_sReason[]), reason);
	g_iStatKicks++;

	LogMessage("%s client %d (%N): KICK (%s)", CG_TAG, client, client, reason);
	FireResolved(client, ChoganAuth_Rejected, reason);

	if (g_iSyncDepth > 0)
	{
		/* inside OnClientConnected / OnClientSettingsChanged / ... / a client command:
		 * leave the forward first, kick on the next frame */
		RequestFrame(Frame_Kick, GetClientSerial(client));
	}
	else
	{
		/* timer / HTTP / SQL callback: KickClient() itself is queued by SourceMod to
		 * the next game frame (core: AddDelayedKick), so this is safe here */
		DoKick(client);
	}
}

public void Frame_Kick(any serial)
{
	int client = GetClientFromSerial(serial);
	if (client > 0 && g_State[client] == ChoganAuth_Rejected)
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
	char msg[192];
	g_cvKickMsg.GetString(msg, sizeof(msg));
	char full[256];
	FormatEx(full, sizeof(full), "%s (%s)", msg, g_sReason[client]);
	KickClient(client, "%s", full);
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

void PostEvent(int client, const char[] type)
{
	if (!g_cvEvents.BoolValue || g_iAccountId[client] <= 0)
	{
		return;
	}
	char ip[48], authid[64], name[MAX_NAME_LENGTH], map[64];
	GetIdentity(client, ip, sizeof(ip), authid, sizeof(authid), name, sizeof(name));
	GetCurrentMap(map, sizeof(map));

	if (g_Transport == CgTransport_RipExt && g_bRipExt)
	{
		char url[512];
		BuildUrl(url, sizeof(url), "/v1/event");

		JSONObject payload = new JSONObject();
		payload.SetString("authid", authid);
		payload.SetString("ip", ip);
		payload.SetString("name", name);
		payload.SetString("map", map);
		payload.SetInt("userid", GetClientUserId(client));
		payload.SetString("source", g_sSource[client]);

		JSONObject body = new JSONObject();
		body.SetString("server_id", g_sServerId);
		body.SetInt("account_id", g_iAccountId[client]);
		body.SetString("type", type);
		body.Set("payload", payload);

		HTTPRequest req = new HTTPRequest(url);
		req.ConnectTimeout = 2;
		req.Timeout = 5;
		req.Post(body, OnEventResponse, 0);
		delete payload;
		delete body;
	}
	else if (g_Transport == CgTransport_Sql && g_hDb != null)
	{
		char eName[MAX_NAME_LENGTH * 2], eMap[128];
		JsonEscape(name, eName, sizeof(eName));
		JsonEscape(map, eMap, sizeof(eMap));
		char payload[512];
		FormatEx(payload, sizeof(payload),
			"{\"authid\":\"%s\",\"ip\":\"%s\",\"name\":\"%s\",\"map\":\"%s\",\"userid\":%d,\"source\":\"%s\"}",
			authid, ip, eName, eMap, GetClientUserId(client), g_sSource[client]);

		char query[1024];
		g_hDb.Format(query, sizeof(query),
			"INSERT INTO cg_events (server_id, account_id, type, payload, created_at) VALUES ('%s', %d, '%s', '%s', NOW())",
			g_sServerId, g_iAccountId[client], type, payload);
		g_hDb.Query(OnSqlFireAndForget, query, 0, DBPrio_Low);
	}
}

public void OnEventResponse(HTTPResponse response, any value, const char[] error)
{
	if (error[0] != '\0')
	{
		DbgLog("event post failed: %s", error);
	}
}

public void OnSqlFireAndForget(Database db, DBResultSet results, const char[] error, any data)
{
	if (results == null)
	{
		DbgLog("event insert failed: %s", error);
	}
}

/** Minimal JSON string escaping (quotes, backslashes, control chars). UTF-8 bytes pass through. */
void JsonEscape(const char[] in, char[] out, int maxlen)
{
	int o = 0;
	for (int i = 0; in[i] != '\0' && o < maxlen - 8; i++)
	{
		int c = in[i] & 0xFF;
		if (c == 0x22 || c == 0x5C)          /* double quote or backslash */
		{
			out[o++] = '\\';
			out[o++] = in[i];
		}
		else if (c == 0x0A)
		{
			out[o++] = '\\';
			out[o++] = 'n';
		}
		else if (c == 0x0D)
		{
			out[o++] = '\\';
			out[o++] = 'r';
		}
		else if (c == 0x09)
		{
			out[o++] = '\\';
			out[o++] = 't';
		}
		else if (c < 0x20)
		{
			o += FormatEx(out[o], maxlen - o, "\\u%04x", c);
		}
		else
		{
			out[o++] = in[i];
		}
	}
	out[o] = '\0';
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

	/* also store under the ip-only key: at reconnect time the auth id may not be
	 * known yet, so the lookup key would be "<ip>|" */
	char ip[48];
	if (GetClientIP(client, ip, sizeof(ip)))
	{
		char ipOnly[128];
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
	accountId = 0;
	displayName[0] = '\0';
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
	/* once the open window elapsed the breaker is half-open: the next redeem is a
	 * trial request; a failure re-opens it immediately (counter is still >= threshold) */
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
		bool wasOpen = (GetEngineTime() < g_fBreakerOpenUntil);
		g_fBreakerOpenUntil = GetEngineTime() + g_cvBreakerOpen.FloatValue;
		if (!wasOpen)
		{
			g_iBreakerTrips++;
			LogMessage("%s circuit breaker OPEN for %.0fs after %d consecutive failures - agent will not be called, fallback path applies immediately",
				CG_TAG, g_cvBreakerOpen.FloatValue, g_iBreakerFails);
		}
	}
}

void BreakerSuccess()
{
	if (g_cvBreakerFails.IntValue > 0 && g_iBreakerFails >= g_cvBreakerFails.IntValue)
	{
		LogMessage("%s circuit breaker CLOSED (agent answered)", CG_TAG);
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
	ReplyToCommand(client, "%s v%s mode=%d transport=%s ripext=%d db=%s server_id=\"%s\" breaker=%s (fails=%d trips=%d) cache=%d entries",
		CG_TAG, PLUGIN_VERSION, g_cvMode.IntValue, tname, g_bRipExt, (g_hDb != null) ? "connected" : "no",
		g_sServerId, BreakerIsOpen() ? "OPEN" : "closed", g_iBreakerFails, g_iBreakerTrips, g_hCacheAcct.Size);
	ReplyToCommand(client, "%s totals: ok=%d ok_cache=%d rejected=%d api_down=%d guests=%d kicks=%d",
		CG_TAG, g_iStatRedeemOk, g_iStatRedeemCached, g_iStatRejected, g_iStatApiDown, g_iStatGuests, g_iStatKicks);
	ReplyToCommand(client, "  #userid  name                              state     account  display           source    guest reason");

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i))
		{
			continue;
		}
		char name[MAX_NAME_LENGTH], st[12];
		GetClientName(i, name, sizeof(name));
		StateNameCopy(g_State[i], st, sizeof(st));
		ReplyToCommand(client, "  #%-7d %-33s %-9s %-8d %-17s %-9s %-5d %s",
			GetClientUserId(i), name, st, g_iAccountId[i],
			g_sDisplayName[i], g_sSource[i], (g_State[i] == ChoganAuth_Guest) ? 1 : 0, g_sReason[i]);
	}
	return Plugin_Handled;
}

public Action Cmd_Health(int client, int args)
{
	if (!g_bRipExt)
	{
		ReplyToCommand(client, "%s RIPExt not loaded - cannot GET /health (SQL transport db=%s)", CG_TAG, (g_hDb != null) ? "connected" : "no");
		return Plugin_Handled;
	}
	char url[512];
	BuildUrl(url, sizeof(url), "/health");
	HTTPRequest req = new HTTPRequest(url);
	req.ConnectTimeout = 2;
	req.Timeout = 5;
	req.Get(OnHealthResponse, (client > 0) ? GetClientSerial(client) : 0);
	ReplyToCommand(client, "%s GET %s dispatched...", CG_TAG, url);
	return Plugin_Handled;
}

public void OnHealthResponse(HTTPResponse response, any serial, const char[] error)
{
	int status = view_as<int>(response.Status);
	char line[512];
	if (error[0] != '\0' || status == 0)
	{
		FormatEx(line, sizeof(line), "%s /health FAILED: %s", CG_TAG, error);
	}
	else
	{
		char ctype[96], body[320];
		body[0] = '\0';
		if (response.GetHeader("Content-Type", ctype, sizeof(ctype)) && StrContains(ctype, "json", false) != -1)
		{
			JSON data = response.Data;
			if (data != null)
			{
				data.ToString(body, sizeof(body), JSON_COMPACT);
			}
		}
		FormatEx(line, sizeof(line), "%s /health -> HTTP %d %s", CG_TAG, status, body);
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

public Action Cmd_FlushCache(int client, int args)
{
	int n = g_hCacheAcct.Size;
	g_hCacheAcct.Clear();
	g_hCacheName.Clear();
	ReplyToCommand(client, "%s reconnect cache flushed (%d entries)", CG_TAG, n);
	return Plugin_Handled;
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

void StateNameCopy(ChoganAuthState s, char[] buf, int maxlen)
{
	switch (s)
	{
		case ChoganAuth_Skipped:  strcopy(buf, maxlen, "skipped");
		case ChoganAuth_Waiting:  strcopy(buf, maxlen, "waiting");
		case ChoganAuth_Pending:  strcopy(buf, maxlen, "pending");
		case ChoganAuth_Bound:    strcopy(buf, maxlen, "bound");
		case ChoganAuth_Guest:    strcopy(buf, maxlen, "guest");
		case ChoganAuth_Rejected: strcopy(buf, maxlen, "rejected");
		default:                  strcopy(buf, maxlen, "none");
	}
}

void DbgLog(const char[] fmt, any ...)
{
	if (!g_cvDebug.BoolValue)
	{
		return;
	}
	char buf[512];
	VFormat(buf, sizeof(buf), fmt, 2);
	LogMessage("%s [debug] %s", CG_TAG, buf);
}
