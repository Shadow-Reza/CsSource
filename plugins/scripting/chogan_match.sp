/**
 * chogan_match.sp — minimal competitive match controller for CS:Source v92 (MISSION §6.6).
 *
 * WHY THIS EXISTS
 *   There is no maintained match / PUG / mix system built for Counter-Strike: Source
 *   in 2026. get5, MatchZy and csgo-pug-setup are CS:GO / CS2 only and will not load
 *   on the CS:S (Engine_CSS / orangebox_valve) game DLL. CSSMatch is a dead 2013 Valve
 *   Server Plugin (not Metamod/SourceMod) and does not build for v92 without a port.
 *   (A community fork, ZxYdzero/CS-S-Mixmod, is maintained and is the fuller option —
 *   see docs/match-system-research.md — but the MISSION verdict is to ship a minimal,
 *   self-contained plugin we fully control. This is that plugin.)
 *
 * WHAT IT DOES
 *   - Ready-up system: !ready / !unready (also !r / !nr, sm_ready / sm_unready) with a
 *     live "X/Y players ready" chat + HUD count. When every in-game, non-spectator
 *     player on both teams is ready (and at least cg_match_min_ready per side), the
 *     match starts automatically.
 *   - Knife round (cg_match_knife 1): the first round is a knife round (players are
 *     stripped to knife on spawn). The winning team's captain picks side with
 *     !stay / !switch (captain = first player who readied on that team; any player on
 *     that team may pick if cg_match_anyone_picks 1).
 *   - Live-on-3 (cg_match_lo3 1): the game is restarted 3 times with a chat countdown,
 *     then goes LIVE.
 *   - Score tracking keyed by a STABLE side token (SIDE_A / SIDE_B), not by CS team
 *     index, so the halftime team swap does not scramble the score. At half
 *     (cg_match_maxrounds / 2) the plugin swaps both teams with ChangeClientTeam and
 *     re-maps the side<->team relation. Match ends when a side reaches
 *     (maxrounds / 2) + 1 round wins, or maxrounds are played (draw possible).
 *   - Tactical timeout: !pause / !unpause (also !tech / !tac, sm_pause / sm_unpause),
 *     gated by cg_match_pause_enabled. See the LIMITATION note below — this is a
 *     movement freeze, not an engine pause.
 *   - Result output: on match end it writes a machine-readable line to the game log
 *     (LogToGame) that leaves the box through the server's normal logaddress_add UDP
 *     stream, so an external collector can read the result without the plugin ever
 *     making a network call:
 *         CHOGAN_MATCH_RESULT map="de_dust2" teamA=16 teamB=12 rounds=28 winner=A ...
 *     plus CHOGAN_MATCH_LIVE and CHOGAN_MATCH_HALFTIME transition lines.
 *   - Admin: sm_match_start / sm_match_stop / sm_match_restart (ADMFLAG_GENERIC).
 *
 * WHAT IT DOES *NOT* DO (deliberately — this is a MINIMAL plugin)
 *   - No round backup / restore (no engine round-restore exists on CS:S; a disconnect
 *     mid-match cannot be rewound).
 *   - No per-player stats database, no ADR / rating / MVP tracking.
 *   - No overtime. At maxrounds/2 all-square it reports a draw.
 *   - No veto / map pick / bo3, no team names / player locking, no SourceTV auto-record.
 *   - PAUSE IS AN EMULATION. CS:S has no usable native match-pause. This "pause" freezes
 *     players by setting MOVETYPE_NONE; players can still aim and fire, and the round
 *     timer keeps running. It is a tactical-timeout stand-in, not a true freeze. This is
 *     a documented limitation of the engine, not a bug.
 *   - No respawning. This plugin is NOT a respawn authority (MISSION §6.5); it is only
 *     ever loaded on the two Match servers, never alongside the DM or GunGame plugins.
 *   - It does not itself call any HTTP/API. Results go out only via the game log.
 *
 * Target: CS:S v92 (build 6953255), SourceMod pinned 1.12.0-git7179, Metamod 1.12.
 * Engine = Engine_CSS. SourcePawn 1.12 syntax.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

#define PLUGIN_VERSION "0.1.0"
#define TAG           "[Chogan Match]"
#define LOG_TAG       "[match]"

/* stable side tokens — the score is keyed by these, never by CS team index */
#define SIDE_A 0
#define SIDE_B 1

/* match state machine */
enum
{
	STATE_WARMUP = 0,   /* free play, collecting readies                     */
	STATE_KNIFE,        /* knife round in progress                           */
	STATE_KNIFE_DECISION,/* knife won, waiting for !stay / !switch            */
	STATE_LO3,          /* live-on-3 restart sequence running                */
	STATE_LIVE,         /* match live, scoring rounds                        */
	STATE_ENDED         /* match decided                                     */
}

public Plugin myinfo =
{
	name        = "[Chogan] Match",
	author      = "Chogan build (autonomous run)",
	description = "Minimal CS:S competitive match: ready-up, knife round, LO3, side swap, tactical timeout, log result",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/Shadow-Reza/CsSource"
};

/* cvars */
ConVar g_cvMinReady;      /* cg_match_min_ready    */
ConVar g_cvKnife;         /* cg_match_knife        */
ConVar g_cvLo3;           /* cg_match_lo3          */
ConVar g_cvMaxRounds;     /* cg_match_maxrounds    */
ConVar g_cvAnyonePicks;   /* cg_match_anyone_picks */
ConVar g_cvPauseEnabled;  /* cg_match_pause_enabled*/
ConVar g_cvWarmup;        /* cg_match_warmup       */

/* runtime state */
int    g_iState               = STATE_WARMUP;
bool   g_bLateLoad            = false;

bool   g_bReady[MAXPLAYERS + 1];
int    g_iReadyOrder[MAXPLAYERS + 1];   /* order in which a client readied (captain = lowest) */
int    g_iReadyCounter        = 0;

int    g_iScore[2];                     /* score keyed by SIDE_A / SIDE_B                      */
int    g_iCSTeamForSide[2];             /* which CS team a side currently occupies             */
int    g_iSideForCSTeam[4];             /* reverse map: CS team (0..3) -> side, or -1          */
bool   g_bSwapped            = false;   /* halftime swap already done this match               */

/* knife */
bool   g_bAwaitKnifeStart    = false;   /* between restart and the first knife round_start     */
bool   g_bKnifeLive          = false;   /* knife round actually in progress                    */
int    g_iKnifeWinnerTeam    = 0;       /* CS team that won the knife round                     */
int    g_iCaptainSerial      = -1;      /* serial of the picking captain                        */

/* pause */
bool   g_bPaused             = false;

/* timing / handles */
int    g_iStartTime          = 0;
Handle g_hHud                = null;    /* HUD synchronizer                                     */
Handle g_hHudTimer           = null;    /* repeating HUD/announce timer (per map)               */
Handle g_hDecisionTimeout    = null;    /* auto-stay fallback during KNIFE_DECISION             */

/* ------------------------------------------------------------------------- */

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	CreateConVar("cg_match_version", PLUGIN_VERSION, "Chogan match plugin version",
		FCVAR_NOTIFY | FCVAR_DONTRECORD | FCVAR_SPONLY);

	g_cvMinReady = CreateConVar("cg_match_min_ready", "1",
		"Minimum ready, non-spectator players required per side before the match can start (1 = testing, 5 = intended)",
		FCVAR_NONE, true, 1.0, true, 16.0);
	g_cvKnife = CreateConVar("cg_match_knife", "1",
		"1 = first round is a knife round with a side pick, 0 = skip knife and go straight to LO3",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvLo3 = CreateConVar("cg_match_lo3", "1",
		"1 = live-on-3 (restart the game 3 times before going live), 0 = single restart",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvMaxRounds = CreateConVar("cg_match_maxrounds", "30",
		"Max rounds for the match. Half is maxrounds/2; a side wins at (maxrounds/2)+1 round wins",
		FCVAR_NONE, true, 2.0, true, 120.0);
	g_cvAnyonePicks = CreateConVar("cg_match_anyone_picks", "0",
		"0 = only the winning team's captain (first to ready) may pick side, 1 = any player on the winning team",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvPauseEnabled = CreateConVar("cg_match_pause_enabled", "1",
		"1 = allow !pause / !tech / !tac tactical timeouts (movement freeze), 0 = disable",
		FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvWarmup = CreateConVar("cg_match_warmup", "1",
		"1 = show the ready-up HUD/reminders during warmup, 0 = quiet warmup",
		FCVAR_NONE, true, 0.0, true, 1.0);

	/* player commands (chat !cmd is routed to sm_cmd by SourceMod) */
	RegConsoleCmd("sm_ready",    Cmd_Ready,   "Mark yourself ready");
	RegConsoleCmd("sm_r",        Cmd_Ready,   "Mark yourself ready (alias)");
	RegConsoleCmd("sm_unready",  Cmd_Unready, "Mark yourself not ready");
	RegConsoleCmd("sm_nr",       Cmd_Unready, "Mark yourself not ready (alias)");
	RegConsoleCmd("sm_stay",     Cmd_Stay,    "Knife winner: keep current sides");
	RegConsoleCmd("sm_switch",   Cmd_Switch,  "Knife winner: switch sides");
	RegConsoleCmd("sm_pause",    Cmd_Pause,   "Call a tactical timeout");
	RegConsoleCmd("sm_tech",     Cmd_Pause,   "Call a tactical timeout (alias)");
	RegConsoleCmd("sm_tac",      Cmd_Pause,   "Call a tactical timeout (alias)");
	RegConsoleCmd("sm_unpause",  Cmd_Unpause, "Resume after a tactical timeout");

	/* admin commands */
	RegAdminCmd("sm_match_start",   Cmd_MatchStart,   ADMFLAG_GENERIC, "Force the match to start now (skips ready-up)");
	RegAdminCmd("sm_match_stop",    Cmd_MatchStop,    ADMFLAG_GENERIC, "Abort the match back to warmup");
	RegAdminCmd("sm_match_restart", Cmd_MatchRestart, ADMFLAG_GENERIC, "Reset the score and re-run the go-live (LO3) sequence");

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("round_end",   Event_RoundEnd,   EventHookMode_Post);
	HookEvent("player_spawn",Event_PlayerSpawn,EventHookMode_Post);
	HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);

	g_hHud = CreateHudSynchronizer();

	AutoExecConfig(true, "chogan_match");

	if (g_bLateLoad)
	{
		MapSetup();
	}
}

public void OnMapStart()
{
	MapSetup();
}

public void OnMapEnd()
{
	/* all timers are auto-killed at map end; drop our references so MapSetup does not
	 * touch dead handles */
	g_hHudTimer        = null;
	g_hDecisionTimeout = null;
}

/* (re)initialise per-map state and the HUD timer. Safe to call twice (late load). */
void MapSetup()
{
	ResetMatchState();

	if (g_hHudTimer != null)
	{
		KillTimer(g_hHudTimer);
		g_hHudTimer = null;
	}
	g_hHudTimer = CreateTimer(1.0, Timer_Hud, _, TIMER_REPEAT);
}

void ResetMatchState()
{
	g_iState            = STATE_WARMUP;
	g_bAwaitKnifeStart  = false;
	g_bKnifeLive        = false;
	g_iKnifeWinnerTeam  = 0;
	g_iCaptainSerial    = -1;
	g_bSwapped          = false;
	g_bPaused           = false;
	g_iScore[SIDE_A]    = 0;
	g_iScore[SIDE_B]    = 0;
	g_iReadyCounter     = 0;

	for (int i = 1; i <= MAXPLAYERS; i++)
	{
		g_bReady[i]      = false;
		g_iReadyOrder[i] = 0;
	}

	AssignSidesFromTeams();

	if (g_hDecisionTimeout != null)
	{
		KillTimer(g_hDecisionTimeout);
		g_hDecisionTimeout = null;
	}
}

public void OnClientDisconnect(int client)
{
	g_bReady[client]      = false;
	g_iReadyOrder[client] = 0;
}

/* ------------------------------------------------------------------------- */
/* Ready-up                                                                   */
/* ------------------------------------------------------------------------- */

public Action Cmd_Ready(int client, int args)
{
	if (client < 1)
	{
		return Plugin_Handled;
	}
	if (g_iState != STATE_WARMUP)
	{
		ReplyToCommand(client, "%s A match is already in progress.", TAG);
		return Plugin_Handled;
	}
	int team = GetClientTeam(client);
	if (team != CS_TEAM_T && team != CS_TEAM_CT)
	{
		ReplyToCommand(client, "%s Join Terrorists or Counter-Terrorists first, then type !ready.", TAG);
		return Plugin_Handled;
	}
	if (g_bReady[client])
	{
		ReplyToCommand(client, "%s You are already ready. Type !unready to cancel.", TAG);
		return Plugin_Handled;
	}

	g_bReady[client]      = true;
	g_iReadyOrder[client] = ++g_iReadyCounter;

	int rdy, total;
	GetReadyTotals(rdy, total);
	Announce("%N is ready (%d/%d).", client, rdy, total);

	CheckAutoStart();
	return Plugin_Handled;
}

public Action Cmd_Unready(int client, int args)
{
	if (client < 1)
	{
		return Plugin_Handled;
	}
	if (g_iState != STATE_WARMUP)
	{
		ReplyToCommand(client, "%s A match is already in progress.", TAG);
		return Plugin_Handled;
	}
	if (!g_bReady[client])
	{
		ReplyToCommand(client, "%s You were not marked ready.", TAG);
		return Plugin_Handled;
	}

	g_bReady[client]      = false;
	g_iReadyOrder[client] = 0;

	int rdy, total;
	GetReadyTotals(rdy, total);
	Announce("%N is NOT ready (%d/%d).", client, rdy, total);
	return Plugin_Handled;
}

/* count ready and total eligible (in-game, human, on T/CT) players across both teams */
void GetReadyTotals(int &ready, int &total)
{
	ready = 0;
	total = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
		{
			continue;
		}
		int team = GetClientTeam(i);
		if (team != CS_TEAM_T && team != CS_TEAM_CT)
		{
			continue;
		}
		total++;
		if (g_bReady[i])
		{
			ready++;
		}
	}
}

/* start when every eligible player on both sides is ready and each side has >= min */
bool AllReadyToStart()
{
	int need = g_cvMinReady.IntValue;
	int tTotal = 0, tReady = 0, ctTotal = 0, ctReady = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
		{
			continue;
		}
		int team = GetClientTeam(i);
		if (team == CS_TEAM_T)
		{
			tTotal++;
			if (g_bReady[i]) tReady++;
		}
		else if (team == CS_TEAM_CT)
		{
			ctTotal++;
			if (g_bReady[i]) ctReady++;
		}
	}

	if (tTotal < need || ctTotal < need)
	{
		return false;
	}
	if (tReady != tTotal || ctReady != ctTotal)
	{
		return false;
	}
	return true;
}

void CheckAutoStart()
{
	if (g_iState == STATE_WARMUP && AllReadyToStart())
	{
		StartMatch();
	}
}

/* ------------------------------------------------------------------------- */
/* Match flow                                                                 */
/* ------------------------------------------------------------------------- */

void StartMatch()
{
	g_iScore[SIDE_A] = 0;
	g_iScore[SIDE_B] = 0;
	g_bSwapped       = false;
	SetPaused(false);

	if (g_cvKnife.BoolValue)
	{
		BeginKnife();
	}
	else
	{
		BeginGoLive();
	}
}

void BeginKnife()
{
	g_iState           = STATE_KNIFE;
	g_bAwaitKnifeStart = true;
	g_bKnifeLive       = false;
	Announce("All players ready! KNIFE ROUND next — winner picks side.");
	LogMessage("%s starting knife round", LOG_TAG);
	ServerCommand("mp_restartgame 1");
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	if (g_iState == STATE_KNIFE && g_bAwaitKnifeStart)
	{
		g_bAwaitKnifeStart = false;
		g_bKnifeLive       = true;
		Announce("KNIFE ROUND — knives only! Winning team will choose sides.");
	}
	return Plugin_Continue;
}

public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if (g_iState != STATE_KNIFE)
	{
		return Plugin_Continue;
	}
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1)
	{
		return Plugin_Continue;
	}
	/* weapons are handed out just after the spawn event; strip on the next frame */
	RequestFrame(Frame_StripToKnife, GetClientSerial(client));
	return Plugin_Continue;
}

public void Frame_StripToKnife(any data)
{
	int client = GetClientFromSerial(data);
	if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client))
	{
		return;
	}
	int team = GetClientTeam(client);
	if (team != CS_TEAM_T && team != CS_TEAM_CT)
	{
		return;
	}

	int slots[4];
	slots[0] = CS_SLOT_PRIMARY;
	slots[1] = CS_SLOT_SECONDARY;
	slots[2] = CS_SLOT_GRENADE;
	slots[3] = CS_SLOT_C4;

	for (int s = 0; s < sizeof(slots); s++)
	{
		int weapon = GetPlayerWeaponSlot(client, slots[s]);
		if (weapon != -1)
		{
			RemovePlayerItem(client, weapon);
			RemoveEntity(weapon);
		}
	}

	if (GetPlayerWeaponSlot(client, CS_SLOT_KNIFE) == -1)
	{
		GivePlayerItem(client, "weapon_knife");
	}
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	int winner = event.GetInt("winner");

	if (g_iState == STATE_KNIFE && g_bKnifeLive)
	{
		g_bKnifeLive = false;
		KnifeDecided(winner);
		return Plugin_Continue;
	}

	if (g_iState != STATE_LIVE)
	{
		return Plugin_Continue;
	}

	if (winner == CS_TEAM_T || winner == CS_TEAM_CT)
	{
		int side = g_iSideForCSTeam[winner];
		if (side == SIDE_A || side == SIDE_B)
		{
			g_iScore[side]++;
		}
	}
	UpdateScoreboardScores();

	int played = g_iScore[SIDE_A] + g_iScore[SIDE_B];
	int half   = g_cvMaxRounds.IntValue / 2;

	if (!g_bSwapped && half > 0 && played == half)
	{
		HalfTimeSwap();
	}

	int winThreshold = half + 1;
	if (g_iScore[SIDE_A] >= winThreshold || g_iScore[SIDE_B] >= winThreshold
		|| played >= g_cvMaxRounds.IntValue)
	{
		EndMatch();
	}
	return Plugin_Continue;
}

/* ------------------------------------------------------------------------- */
/* Knife decision                                                             */
/* ------------------------------------------------------------------------- */

void KnifeDecided(int winner)
{
	if (winner != CS_TEAM_T && winner != CS_TEAM_CT)
	{
		Announce("Knife round was a draw — keeping sides. Going live...");
		BeginGoLive();
		return;
	}

	g_iKnifeWinnerTeam = winner;
	g_iState           = STATE_KNIFE_DECISION;

	int captain = FindCaptain(winner);
	g_iCaptainSerial = (captain != -1) ? GetClientSerial(captain) : -1;

	char teamName[8];
	TeamName(winner, teamName, sizeof(teamName));

	if (g_cvAnyonePicks.BoolValue)
	{
		Announce("%s won the knife round! Any %s player: type !stay or !switch.", teamName, teamName);
	}
	else if (captain != -1)
	{
		Announce("%s won the knife round! %N (captain): type !stay or !switch.", teamName, captain);
	}
	else
	{
		Announce("%s won the knife round! Type !stay or !switch.", teamName);
	}

	if (g_hDecisionTimeout != null)
	{
		KillTimer(g_hDecisionTimeout);
	}
	g_hDecisionTimeout = CreateTimer(60.0, Timer_DecisionTimeout);
}

/* captain = the winning-team player who readied first; fall back to any winning-team player */
int FindCaptain(int team)
{
	int best = -1;
	int bestOrder = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || IsFakeClient(i))
		{
			continue;
		}
		if (GetClientTeam(i) != team)
		{
			continue;
		}
		if (g_iReadyOrder[i] > 0 && (best == -1 || g_iReadyOrder[i] < bestOrder))
		{
			best      = i;
			bestOrder = g_iReadyOrder[i];
		}
	}
	if (best != -1)
	{
		return best;
	}
	/* nobody on that team had a ready order (e.g. forced start) — pick the first one */
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == team)
		{
			return i;
		}
	}
	return -1;
}

bool CanPick(int client)
{
	if (GetClientTeam(client) != g_iKnifeWinnerTeam)
	{
		return false;
	}
	if (g_cvAnyonePicks.BoolValue)
	{
		return true;
	}
	if (g_iCaptainSerial == -1)
	{
		return true; /* no captain resolved — allow any winner-team player */
	}
	return GetClientSerial(client) == g_iCaptainSerial;
}

public Action Cmd_Stay(int client, int args)
{
	if (client < 1)
	{
		return Plugin_Handled;
	}
	if (g_iState != STATE_KNIFE_DECISION)
	{
		return Plugin_Handled;
	}
	if (!CanPick(client))
	{
		ReplyToCommand(client, "%s Only the winning team's captain may pick the side.", TAG);
		return Plugin_Handled;
	}
	ClearDecisionTimeout();
	Announce("%N chose to STAY. Going live...", client);
	BeginGoLive();
	return Plugin_Handled;
}

public Action Cmd_Switch(int client, int args)
{
	if (client < 1)
	{
		return Plugin_Handled;
	}
	if (g_iState != STATE_KNIFE_DECISION)
	{
		return Plugin_Handled;
	}
	if (!CanPick(client))
	{
		ReplyToCommand(client, "%s Only the winning team's captain may pick the side.", TAG);
		return Plugin_Handled;
	}
	ClearDecisionTimeout();
	Announce("%N chose to SWITCH sides. Going live...", client);
	SwapAllPlayers();
	BeginGoLive();
	return Plugin_Handled;
}

public Action Timer_DecisionTimeout(Handle timer)
{
	g_hDecisionTimeout = null;
	if (g_iState == STATE_KNIFE_DECISION)
	{
		Announce("No side pick in time — keeping sides. Going live...");
		BeginGoLive();
	}
	return Plugin_Stop;
}

void ClearDecisionTimeout()
{
	if (g_hDecisionTimeout != null)
	{
		KillTimer(g_hDecisionTimeout);
		g_hDecisionTimeout = null;
	}
}

/* ------------------------------------------------------------------------- */
/* Live-on-3 and go-live                                                      */
/* ------------------------------------------------------------------------- */

void BeginGoLive()
{
	if (g_cvLo3.BoolValue)
	{
		g_iState = STATE_LO3;
		Announce("Live on 3...");
		DoRestart(1);
	}
	else
	{
		g_iState = STATE_LO3;
		Announce("Restarting — going live...");
		ServerCommand("mp_restartgame 1");
		CreateTimer(2.0, Timer_GoLiveNow);
	}
}

void DoRestart(int n)
{
	Announce("Restart %d/3...", n);
	ServerCommand("mp_restartgame 1");
	if (n < 3)
	{
		CreateTimer(2.0, Timer_NextRestart, n);
	}
	else
	{
		CreateTimer(2.0, Timer_GoLiveNow);
	}
}

public Action Timer_NextRestart(Handle timer, any data)
{
	if (g_iState == STATE_LO3)
	{
		DoRestart(data + 1);
	}
	return Plugin_Stop;
}

public Action Timer_GoLiveNow(Handle timer)
{
	if (g_iState == STATE_LO3)
	{
		GoLive();
	}
	return Plugin_Stop;
}

void GoLive()
{
	g_iState         = STATE_LIVE;
	g_iScore[SIDE_A] = 0;
	g_iScore[SIDE_B] = 0;
	g_bSwapped       = false;
	g_iStartTime     = GetTime();

	AssignSidesFromTeams();
	UpdateScoreboardScores();

	/* We own match end ourselves (early clinch + our own halftime swap), so stop the
	 * engine from changing the level or swapping under us mid-match. */
	ServerCommand("mp_maxrounds 0");
	ServerCommand("mp_winlimit 0");
	ServerCommand("mp_timelimit 0");

	Announce("LIVE! LIVE! LIVE!");

	char map[64];
	GetCurrentMap(map, sizeof(map));
	LogToGame("CHOGAN_MATCH_LIVE map=\"%s\" maxrounds=%d knife=%d", map, g_cvMaxRounds.IntValue, g_cvKnife.IntValue);
	LogMessage("%s match is live on %s", LOG_TAG, map);
}

/* SIDE_A occupies whatever CS_TEAM_CT is now; SIDE_B occupies CS_TEAM_T */
void AssignSidesFromTeams()
{
	g_iCSTeamForSide[SIDE_A] = CS_TEAM_CT;
	g_iCSTeamForSide[SIDE_B] = CS_TEAM_T;
	RebuildReverseMap();
}

void RebuildReverseMap()
{
	for (int t = 0; t < 4; t++)
	{
		g_iSideForCSTeam[t] = -1;
	}
	g_iSideForCSTeam[g_iCSTeamForSide[SIDE_A]] = SIDE_A;
	g_iSideForCSTeam[g_iCSTeamForSide[SIDE_B]] = SIDE_B;
}

void UpdateScoreboardScores()
{
	CS_SetTeamScore(g_iCSTeamForSide[SIDE_A], g_iScore[SIDE_A]);
	CS_SetTeamScore(g_iCSTeamForSide[SIDE_B], g_iScore[SIDE_B]);
}

/* ------------------------------------------------------------------------- */
/* Halftime / team swap                                                       */
/* ------------------------------------------------------------------------- */

void HalfTimeSwap()
{
	SwapAllPlayers();

	/* the side<->CS-team mapping flips so the stable score follows the players */
	int tmp = g_iCSTeamForSide[SIDE_A];
	g_iCSTeamForSide[SIDE_A] = g_iCSTeamForSide[SIDE_B];
	g_iCSTeamForSide[SIDE_B] = tmp;
	RebuildReverseMap();

	g_bSwapped = true;
	UpdateScoreboardScores();

	Announce("HALFTIME — switching sides. Score A %d : %d B.", g_iScore[SIDE_A], g_iScore[SIDE_B]);

	char map[64];
	GetCurrentMap(map, sizeof(map));
	LogToGame("CHOGAN_MATCH_HALFTIME map=\"%s\" teamA=%d teamB=%d", map, g_iScore[SIDE_A], g_iScore[SIDE_B]);
}

/* swap every in-game player (humans and bots) between T and CT; spectators untouched */
void SwapAllPlayers()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i))
		{
			continue;
		}
		int team = GetClientTeam(i);
		if (team == CS_TEAM_T)
		{
			ChangeClientTeam(i, CS_TEAM_CT);
		}
		else if (team == CS_TEAM_CT)
		{
			ChangeClientTeam(i, CS_TEAM_T);
		}
	}
}

/* reset ready state when a client changes team during warmup */
public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	if (g_iState != STATE_WARMUP)
	{
		return Plugin_Continue;
	}
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client < 1)
	{
		return Plugin_Continue;
	}
	if (g_bReady[client])
	{
		g_bReady[client]      = false;
		g_iReadyOrder[client] = 0;
	}
	return Plugin_Continue;
}

/* ------------------------------------------------------------------------- */
/* Match end                                                                  */
/* ------------------------------------------------------------------------- */

void EndMatch()
{
	g_iState = STATE_ENDED;
	SetPaused(false);

	char winner[8];
	if (g_iScore[SIDE_A] > g_iScore[SIDE_B])
	{
		strcopy(winner, sizeof(winner), "A");
	}
	else if (g_iScore[SIDE_B] > g_iScore[SIDE_A])
	{
		strcopy(winner, sizeof(winner), "B");
	}
	else
	{
		strcopy(winner, sizeof(winner), "draw");
	}

	int rounds   = g_iScore[SIDE_A] + g_iScore[SIDE_B];
	int duration = (g_iStartTime > 0) ? (GetTime() - g_iStartTime) : 0;

	char map[64];
	GetCurrentMap(map, sizeof(map));

	/* machine-readable result — leaves the box via logaddress_add (MISSION §6.6) */
	LogToGame("CHOGAN_MATCH_RESULT map=\"%s\" teamA=%d teamB=%d rounds=%d winner=%s maxrounds=%d duration=%d",
		map, g_iScore[SIDE_A], g_iScore[SIDE_B], rounds, winner, g_cvMaxRounds.IntValue, duration);
	LogMessage("%s match ended: A %d - %d B (winner=%s) on %s",
		LOG_TAG, g_iScore[SIDE_A], g_iScore[SIDE_B], winner, map);

	if (StrEqual(winner, "draw"))
	{
		Announce("MATCH OVER — DRAW %d : %d.", g_iScore[SIDE_A], g_iScore[SIDE_B]);
	}
	else
	{
		Announce("MATCH OVER — Team %s wins %d : %d.", winner, g_iScore[SIDE_A], g_iScore[SIDE_B]);
	}
	Announce("Admin: sm_match_restart to replay, or change the map.");
}

/* ------------------------------------------------------------------------- */
/* Pause (tactical timeout emulation)                                         */
/* ------------------------------------------------------------------------- */

public Action Cmd_Pause(int client, int args)
{
	if (client < 1)
	{
		return Plugin_Handled;
	}
	if (!g_cvPauseEnabled.BoolValue)
	{
		ReplyToCommand(client, "%s Pauses are disabled on this server.", TAG);
		return Plugin_Handled;
	}
	if (g_iState != STATE_LIVE)
	{
		ReplyToCommand(client, "%s You can only call a timeout while the match is live.", TAG);
		return Plugin_Handled;
	}
	int team = GetClientTeam(client);
	if (team != CS_TEAM_T && team != CS_TEAM_CT)
	{
		ReplyToCommand(client, "%s Only players in the match can call a timeout.", TAG);
		return Plugin_Handled;
	}
	if (g_bPaused)
	{
		ReplyToCommand(client, "%s The match is already paused.", TAG);
		return Plugin_Handled;
	}

	SetPaused(true);
	Announce("TACTICAL TIMEOUT by %N. Players frozen. Type !unpause to resume.", client);
	Announce("(Note: this freezes movement only — aim/fire and the round timer still run.)");
	return Plugin_Handled;
}

public Action Cmd_Unpause(int client, int args)
{
	if (client < 1)
	{
		return Plugin_Handled;
	}
	if (!g_bPaused)
	{
		ReplyToCommand(client, "%s The match is not paused.", TAG);
		return Plugin_Handled;
	}
	SetPaused(false);
	Announce("Timeout ended by %N — resuming.", client);
	return Plugin_Handled;
}

void SetPaused(bool paused)
{
	g_bPaused = paused;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i))
		{
			continue;
		}
		int team = GetClientTeam(i);
		if (team != CS_TEAM_T && team != CS_TEAM_CT)
		{
			continue;
		}
		SetEntityMoveType(i, paused ? MOVETYPE_NONE : MOVETYPE_WALK);
	}
}

/* ------------------------------------------------------------------------- */
/* Admin commands                                                             */
/* ------------------------------------------------------------------------- */

public Action Cmd_MatchStart(int client, int args)
{
	if (g_iState != STATE_WARMUP)
	{
		ReplyToCommand(client, "%s A match is already in progress (sm_match_stop first).", TAG);
		return Plugin_Handled;
	}
	Announce("Admin forced the match to start.");
	StartMatch();
	return Plugin_Handled;
}

public Action Cmd_MatchStop(int client, int args)
{
	AbortToWarmup();
	Announce("Admin aborted the match — back to warmup. Type !ready when ready.");
	return Plugin_Handled;
}

public Action Cmd_MatchRestart(int client, int args)
{
	if (g_iState == STATE_WARMUP)
	{
		ReplyToCommand(client, "%s No match running. Use sm_match_start.", TAG);
		return Plugin_Handled;
	}
	g_iScore[SIDE_A] = 0;
	g_iScore[SIDE_B] = 0;
	g_bSwapped       = false;
	SetPaused(false);
	ClearDecisionTimeout();
	Announce("Admin restarted the match — resetting score and going live again.");
	BeginGoLive();
	return Plugin_Handled;
}

void AbortToWarmup()
{
	ClearDecisionTimeout();
	SetPaused(false);
	ResetMatchState();
	ServerCommand("mp_restartgame 1");
}

/* ------------------------------------------------------------------------- */
/* HUD                                                                        */
/* ------------------------------------------------------------------------- */

public Action Timer_Hud(Handle timer)
{
	char line[128];

	if (g_bPaused)
	{
		Format(line, sizeof(line), "*** MATCH PAUSED ***\n!unpause to resume");
	}
	else if (g_iState == STATE_WARMUP)
	{
		if (!g_cvWarmup.BoolValue)
		{
			return Plugin_Continue;
		}
		int rdy, total;
		GetReadyTotals(rdy, total);
		Format(line, sizeof(line), "WARMUP  —  READY %d/%d\nType !ready", rdy, total);
	}
	else if (g_iState == STATE_KNIFE_DECISION)
	{
		char teamName[8];
		TeamName(g_iKnifeWinnerTeam, teamName, sizeof(teamName));
		Format(line, sizeof(line), "%s won the knife round\n!stay  or  !switch", teamName);
	}
	else if (g_iState == STATE_LIVE)
	{
		Format(line, sizeof(line), "LIVE   A %d : %d B", g_iScore[SIDE_A], g_iScore[SIDE_B]);
	}
	else
	{
		return Plugin_Continue;
	}

	SetHudTextParams(-1.0, 0.15, 1.3, 0, 200, 255, 255);
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			ShowSyncHudText(i, g_hHud, "%s", line);
		}
	}
	return Plugin_Continue;
}

/* ------------------------------------------------------------------------- */
/* Helpers                                                                    */
/* ------------------------------------------------------------------------- */

void TeamName(int team, char[] buffer, int maxlen)
{
	if (team == CS_TEAM_CT)
	{
		strcopy(buffer, maxlen, "CT");
	}
	else if (team == CS_TEAM_T)
	{
		strcopy(buffer, maxlen, "T");
	}
	else if (team == CS_TEAM_SPECTATOR)
	{
		strcopy(buffer, maxlen, "SPEC");
	}
	else
	{
		strcopy(buffer, maxlen, "none");
	}
}

void Announce(const char[] format, any ...)
{
	char buffer[256];
	VFormat(buffer, sizeof(buffer), format, 2);
	PrintToChatAll("%s %s", TAG, buffer);
}
