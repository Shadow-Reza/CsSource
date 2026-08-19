/**
 * probe_ripext.sp — MISSION §5 probe 2.
 *
 * Question: does RIPExt (ErikMinekus/sm-ripext, rip.ext.so) load on SourceMod 1.12
 * on this CS:S v92 server and complete an *async* HTTPS request?
 *
 * On plugin start (2 s later, so the extension list is settled) it fires three
 * async GETs and logs status code, content-type, content-length, JSON body length,
 * elapsed time and — on failure — the cURL error string:
 *   #1 https://api.github.com/zen           TLS + CA bundle check (plain-text body)
 *   #2 https://api.github.com/rate_limit    TLS + JSON body decode check
 *   #3 http://127.0.0.1:8480/health         local cg-agent reachability (JSON)
 * Admin commands: sm_probe_http <url> (GET) and sm_probe_post <url> (POST {"probe":true}).
 *
 * Notes on RIPExt semantics (verified against the 1.3.2 sources — see
 * https://github.com/ErikMinekus/sm-ripext/blob/main/http_natives.cpp and
 * httprequestcontext.cpp):
 *  - the callback is ALWAYS invoked, also on transport failure; then
 *    response.Status == HTTPStatus_Invalid (0) and `error` holds the cURL message.
 *  - HTTPResponse exposes no raw body. `.Data` runs json_loads() on the body and
 *    THROWS a native error when the body is not JSON (e.g. /zen is text/plain), so
 *    this probe only touches .Data when Content-Type says json. Body length is
 *    reported from Content-Length when present (may be the *compressed* length,
 *    because RIPExt sends Accept-Encoding for all encodings), else from the
 *    re-serialised JSON.
 *  - HTTPS uses the CA bundle at addons/sourcemod/configs/ripext/ca-bundle.crt
 *    shipped in the RIPExt release zip. Missing bundle => "SSL peer certificate"
 *    error here => probe FAIL for #1/#2 but not for #3.
 *
 * All log lines are prefixed "[probe2]".
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

/* RIPExt is OPTIONAL at load time on purpose: if rip.ext fails to load, this probe must
 * still come up and log WHY (GetExtensionFileStatus error string) instead of failing
 * silently with "required extension ... failed". All RIPExt natives are marked optional
 * below and only called after LibraryExists("ripext"). */
#undef REQUIRE_EXTENSIONS
#include <ripext>
#define REQUIRE_EXTENSIONS

#define PLUGIN_VERSION "0.1.0"

#define URL_ZEN     "https://api.github.com/zen"
#define URL_JSON    "https://api.github.com/rate_limit"
#define URL_AGENT   "http://127.0.0.1:8480/health"

#define MAX_INFLIGHT 16

public Plugin myinfo =
{
	name        = "[Chogan] Probe 2: RIPExt async HTTPS",
	author      = "Chogan build (autonomous run)",
	description = "Async GET to api.github.com and the local cg-agent; logs status/body length/errors",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/Shadow-Reza/CsSource"
};

/* per-request bookkeeping, indexed by a small tag passed through `any value` */
char  g_sUrl[MAX_INFLIGHT][256];
float g_fStart[MAX_INFLIGHT];
bool  g_bBusy[MAX_INFLIGHT];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	/* names as registered in sm-ripext 1.3.2 http_natives.cpp / json_natives.cpp */
	MarkNativeAsOptional("HTTPRequest.HTTPRequest");
	MarkNativeAsOptional("HTTPRequest.SetHeader");
	MarkNativeAsOptional("HTTPRequest.Get");
	MarkNativeAsOptional("HTTPRequest.Post");
	MarkNativeAsOptional("HTTPRequest.ConnectTimeout.get");
	MarkNativeAsOptional("HTTPRequest.ConnectTimeout.set");
	MarkNativeAsOptional("HTTPRequest.Timeout.get");
	MarkNativeAsOptional("HTTPRequest.Timeout.set");
	MarkNativeAsOptional("HTTPResponse.Status.get");
	MarkNativeAsOptional("HTTPResponse.Data.get");
	MarkNativeAsOptional("HTTPResponse.GetHeader");
	MarkNativeAsOptional("JSONObject.JSONObject");
	MarkNativeAsOptional("JSONObject.SetBool");
	MarkNativeAsOptional("JSONObject.SetString");
	MarkNativeAsOptional("JSON.ToString");
	return APLRes_Success;
}

public void OnPluginStart()
{
	RegAdminCmd("sm_probe_http", Cmd_ProbeGet, ADMFLAG_RCON,
		"sm_probe_http <url> — async GET via RIPExt, logs status/body length");
	RegAdminCmd("sm_probe_post", Cmd_ProbePost, ADMFLAG_RCON,
		"sm_probe_post <url> — async POST {\"probe\":true} via RIPExt");

	char err[256];
	int st = GetExtensionFileStatus("rip.ext", err, sizeof(err));
	if (st == 1)
	{
		strcopy(err, sizeof(err), "running");
	}
	PLog("plugin loaded v%s — GetExtensionFileStatus(\"rip.ext\")=%d (%s) LibraryExists(ripext)=%d",
		PLUGIN_VERSION, st, err, LibraryExists("ripext"));

	/* give the server a moment after load, then fire the three built-in probes */
	CreateTimer(2.0, Timer_Kickoff);
}

public Action Timer_Kickoff(Handle timer)
{
	PLog("kickoff: firing 3 async GETs (%s, %s, %s)", URL_ZEN, URL_JSON, URL_AGENT);
	DoGet(URL_ZEN);
	DoGet(URL_JSON);
	DoGet(URL_AGENT);
	return Plugin_Stop;
}

/* ---------------------------------------------------------------------------- */

public Action Cmd_ProbeGet(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[probe2] usage: sm_probe_http <url>");
		return Plugin_Handled;
	}
	char url[256];
	GetCmdArg(1, url, sizeof(url));
	int tag = DoGet(url);
	ReplyToCommand(client, "[probe2] GET %s dispatched (tag %d) — watch the server console / SM log.", url, tag);
	return Plugin_Handled;
}

public Action Cmd_ProbePost(int client, int args)
{
	if (args < 1)
	{
		ReplyToCommand(client, "[probe2] usage: sm_probe_post <url>");
		return Plugin_Handled;
	}
	char url[256];
	GetCmdArg(1, url, sizeof(url));
	int tag = DoPost(url);
	ReplyToCommand(client, "[probe2] POST %s dispatched (tag %d) — watch the server console / SM log.", url, tag);
	return Plugin_Handled;
}

/* ---------------------------------------------------------------------------- */

int AllocTag(const char[] url)
{
	for (int i = 0; i < MAX_INFLIGHT; i++)
	{
		if (!g_bBusy[i])
		{
			g_bBusy[i] = true;
			strcopy(g_sUrl[i], sizeof(g_sUrl[]), url);
			g_fStart[i] = GetEngineTime();
			return i;
		}
	}
	return -1;
}

int DoGet(const char[] url)
{
	if (!LibraryExists("ripext"))
	{
		PLog("RESULT url=%s verdict=FAIL error=\"RIPExt (rip.ext) is not loaded - see GetExtensionFileStatus line above and addons/sourcemod/logs/errors_*.log\"", url);
		return -1;
	}
	int tag = AllocTag(url);
	if (tag < 0)
	{
		PLog("too many requests in flight, dropping GET %s", url);
		return -1;
	}

	HTTPRequest req = new HTTPRequest(url);
	req.ConnectTimeout = 10;
	req.Timeout = 20;
	req.SetHeader("Accept", "application/json, text/plain, */*");
	/* GitHub's API insists on a User-Agent; RIPExt already sends "sm-ripext/<ver>". */
	req.Get(OnResponse, tag);       /* handle is freed by RIPExt once performed */
	return tag;
}

int DoPost(const char[] url)
{
	if (!LibraryExists("ripext"))
	{
		PLog("RESULT url=%s verdict=FAIL error=\"RIPExt (rip.ext) is not loaded\"", url);
		return -1;
	}
	int tag = AllocTag(url);
	if (tag < 0)
	{
		PLog("too many requests in flight, dropping POST %s", url);
		return -1;
	}

	JSONObject body = new JSONObject();
	body.SetBool("probe", true);
	body.SetString("from", "probe_ripext");

	HTTPRequest req = new HTTPRequest(url);
	req.ConnectTimeout = 10;
	req.Timeout = 20;
	req.SetHeader("Accept", "application/json");
	req.Post(body, OnResponse, tag);   /* body is serialised now — safe to delete */
	delete body;
	return tag;
}

/**
 * Three-argument form of HTTPRequestCallback (typeset in ripext/http.inc):
 * `error` is the cURL error string, empty on success.
 */
public void OnResponse(HTTPResponse response, any tag, const char[] error)
{
	float elapsed = GetEngineTime() - g_fStart[tag];
	char url[256];
	strcopy(url, sizeof(url), g_sUrl[tag]);
	g_bBusy[tag] = false;

	int status = view_as<int>(response.Status);

	if (error[0] != '\0' || status == view_as<int>(HTTPStatus_Invalid))
	{
		if (error[0] != '\0')
		{
			PLog("RESULT url=%s verdict=FAIL status=%d elapsed=%.3fs error=\"%s\"", url, status, elapsed, error);
		}
		else
		{
			PLog("RESULT url=%s verdict=FAIL status=%d elapsed=%.3fs error=(no cURL message; status 0)", url, status, elapsed);
		}
		return;
	}

	char ctype[128], clen[32], server[64];
	bool hasType = response.GetHeader("Content-Type", ctype, sizeof(ctype));
	bool hasLen  = response.GetHeader("Content-Length", clen, sizeof(clen));
	bool hasSrv  = response.GetHeader("Server", server, sizeof(server));
	if (!hasType) strcopy(ctype, sizeof(ctype), "(none)");
	if (!hasSrv)  strcopy(server, sizeof(server), "(none)");

	int bodyLen = -1;
	char how[24] = "unknown";
	char preview[161];

	if (!hasLen)
	{
		strcopy(clen, sizeof(clen), "(none)");
	}
	strcopy(preview, sizeof(preview), "(n/a)");

	if (hasType && StrContains(ctype, "json", false) != -1)
	{
		/* Only now is it safe to touch .Data (it throws on non-JSON bodies; if the
		 * server lied about the content type this callback aborts right here — the
		 * "parsing" line below then tells you where it died). */
		PLog("url=%s: content-type is JSON, parsing body via response.Data", url);
		JSON data = response.Data;
		char buf[4096];
		if (data != null && data.ToString(buf, sizeof(buf), JSON_COMPACT))
		{
			bodyLen = strlen(buf);
			if (bodyLen >= sizeof(buf) - 1)
			{
				strcopy(how, sizeof(how), "json(truncated)");
			}
			else
			{
				strcopy(how, sizeof(how), "json");
			}
			strcopy(preview, sizeof(preview), buf);
		}
	}
	else if (hasLen)
	{
		bodyLen = StringToInt(clen);
		strcopy(how, sizeof(how), "content-length");
	}

	/* For probe 2 the question is "did the async TLS/HTTP round trip complete" — any
	 * HTTP status > 0 answers yes. A 4xx (e.g. GitHub 403 rate limit) is therefore
	 * still a transport PASS, just flagged. */
	char verdict[24];
	if (status >= 200 && status < 400)
	{
		strcopy(verdict, sizeof(verdict), "OK");
	}
	else
	{
		strcopy(verdict, sizeof(verdict), "OK-TRANSPORT/HTTP-ERR");
	}

	PLog("RESULT url=%s verdict=%s status=%d elapsed=%.3fs content-type=%s content-length=%s body_len=%d (%s) server=%s preview=%s",
		url, verdict, status, elapsed, ctype, clen, bodyLen, how, server, preview);
}

/* ---------------------------------------------------------------------------- */

void PLog(const char[] fmt, any ...)
{
	char buf[1200];
	VFormat(buf, sizeof(buf), fmt, 2);
	LogMessage("[probe2] %s", buf);
	PrintToServer("[probe2] %s", buf);
}
