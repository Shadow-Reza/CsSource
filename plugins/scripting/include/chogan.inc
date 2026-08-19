/**
 * chogan.inc — public API of chogan_auth.smx (Chogan phone-account auth for CS:S).
 *
 * MISSION §6.3: the SourceMod plugin reads the launcher ticket from `setinfo lt`
 * (or the `cg_ticket <token>` console command), redeems it against the local
 * cg-agent asynchronously and then either binds the account or kicks. Other
 * plugins (stats, match, admin) consume the result through these natives /
 * forwards instead of touching SteamIDs (MISSION §3: never key identity, bans or
 * admin on SteamID — the phone account is the identity).
 *
 * Usage from another plugin:
 *   #include <chogan>
 *   public void Chogan_OnAccountBound(int client, int accountId, const char[] displayName) { ... }
 *   int acct = Chogan_GetAccountId(client);   // 0 => guest / pending / bot
 *
 * Optional dependency: `#undef REQUIRE_PLUGIN` before the include and check
 * LibraryExists("chogan_auth") at runtime.
 *
 * Timing: the ticket is usually redeemed between OnClientConnected and
 * OnClientPutInServer, but the decision is asynchronous (HTTP/SQL round trip, up to
 * cg_auth_grace + cg_auth_timeout seconds). A stats plugin should therefore key its
 * rows on Chogan_OnAccountBound / Chogan_OnAuthResolved, not on OnClientPutInServer.
 *
 * SourceMod 1.12, `#pragma newdecls required` compatible.
 */

#if defined _chogan_included
 #endinput
#endif
#define _chogan_included

#define CHOGAN_AUTH_VERSION "0.2.0"

/** Maximum display-name length (bytes, incl. NUL) exposed by Chogan_GetDisplayName. */
#define CHOGAN_MAX_DISPLAYNAME 64

/**
 * Per-client authentication state as tracked by chogan_auth.
 */
enum ChoganAuthState
{
	ChoganAuth_None = 0,   /**< Slot unused / client not connected. */
	ChoganAuth_Skipped,    /**< Not subject to auth (bot, SourceTV, or cg_auth_mode 0). */
	ChoganAuth_Waiting,    /**< Connected, no ticket presented yet, grace timer running. */
	ChoganAuth_Pending,    /**< Ticket presented, redemption in flight (HTTP or SQL). */
	ChoganAuth_Bound,      /**< Redeemed OK — Chogan_GetAccountId() > 0. */
	ChoganAuth_Guest,      /**< Let in without an account (soft-mode fallback, no ticket, late load...). */
	ChoganAuth_Rejected    /**< Kick has been queued (bad ticket, or hard-mode failure). */
};

/**
 * Returns the Chogan account id bound to a client.
 *
 * @param client        Client index.
 * @return              Account id (> 0) if the client is bound, 0 otherwise
 *                      (guest, pending, bot, not connected).
 * @error               Invalid client index.
 */
native int Chogan_GetAccountId(int client);

/**
 * Copies the display name of the bound account.
 *
 * @param client        Client index.
 * @param buffer        Destination buffer.
 * @param maxlength     Size of the destination buffer.
 * @return              True if the client is bound and a name was copied, false otherwise
 *                      (buffer is set to "" in that case).
 * @error               Invalid client index.
 */
native bool Chogan_GetDisplayName(int client, char[] buffer, int maxlength);

/**
 * Returns the auth state of a client.
 *
 * @param client        Client index.
 * @return              ChoganAuthState value.
 * @error               Invalid client index.
 */
native ChoganAuthState Chogan_GetAuthState(int client);

/**
 * Convenience: true when the client is in game as a guest (no account bound).
 *
 * @param client        Client index.
 * @return              True if state == ChoganAuth_Guest.
 * @error               Invalid client index.
 */
native bool Chogan_IsGuest(int client);

/**
 * Returns the configured server id (cvar cg_server_id) — the scope a ticket is
 * bound to. Useful for stats plugins that tag rows by server.
 *
 * @param buffer        Destination buffer.
 * @param maxlength     Size of the destination buffer.
 * @return              Number of bytes written.
 */
native int Chogan_GetServerId(char[] buffer, int maxlength);

/**
 * Fired once when a client's ticket has been redeemed and the account is bound.
 * The client is guaranteed to be connected at this point; it may or may not be
 * in game yet (redemption usually completes before OnClientPutInServer, but do
 * not rely on it — check IsClientInGame() before touching entity data).
 *
 * @param client        Client index.
 * @param accountId     Chogan account id (> 0).
 * @param displayName   Display name returned by the agent (may be empty).
 */
forward void Chogan_OnAccountBound(int client, int accountId, const char[] displayName);

/**
 * Fired once per connection when the auth decision is final: Bound, Guest or
 * Rejected. For Rejected the kick is already queued (KickClient), so treat the
 * client as gone. A Guest may later be upgraded to Bound (late agent answer or a
 * late cg_ticket in soft mode) — then Chogan_OnAccountBound and this forward fire
 * again with ChoganAuth_Bound.
 *
 * @param client        Client index.
 * @param state         ChoganAuth_Bound, ChoganAuth_Guest or ChoganAuth_Rejected.
 * @param reason        Short machine-readable reason, e.g. "ok", "ok_cache",
 *                      "ok_agent_cache", "ok_stub", "no_ticket", "api_down:<why>",
 *                      "invalid", "used", "expired", "scope".
 */
forward void Chogan_OnAuthResolved(int client, ChoganAuthState state, const char[] reason);

/* The implementing plugin (chogan_auth.sp) defines CHOGAN_AUTH_IMPLEMENTATION before
 * including this file so that it does not declare a dependency on itself. */
#if !defined CHOGAN_AUTH_IMPLEMENTATION

/* Do not edit below this line! */
public SharedPlugin __pl_chogan_auth =
{
	name = "chogan_auth",
	file = "chogan_auth.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_chogan_auth_SetNTVOptional()
{
	MarkNativeAsOptional("Chogan_GetAccountId");
	MarkNativeAsOptional("Chogan_GetDisplayName");
	MarkNativeAsOptional("Chogan_GetAuthState");
	MarkNativeAsOptional("Chogan_IsGuest");
	MarkNativeAsOptional("Chogan_GetServerId");
}
#endif

#endif /* CHOGAN_AUTH_IMPLEMENTATION */
