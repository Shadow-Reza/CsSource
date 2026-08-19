# Probes (MISSION §5) — answers and branches taken

| # | Probe | Answer | Branch taken | Evidence |
|---|---|---|---|---|
| 1 | `setinfo lt` visible via `GetClientInfo()` in `OnClientConnected`? | **pending — needs a connecting client** (engine code says: NOT in OnClientConnected; arrives with the first `net_SetConVar` right after SIGNONSTATE_CONNECTED, i.e. at the first `OnClientSettingsChanged`; see `docs/source-connect-protocol.md` §3) | auth plugin reads the token at OnClientConnected *and* OnClientSettingsChanged/OnClientAuthorized/OnClientPutInServer, first non-empty wins; fallback (b) `cg_ticket` console command with grace timer also implemented | `docs/evidence/06-probe1-*.txt` (when run) |
| 2 | RIPExt loads on SM 1.12 and completes async HTTPS? | **YES.** RIPExt 1.3.2 (`rip.ext.so`) loads on SM 1.12.0.**7179**; async GET to `https://api.github.com/zen` → 200 in 1.08 s, `https://api.github.com/rate_limit` → 200 (JSON parsed), `http://127.0.0.1:8480/health` → 200 in 14 ms. | RIPExt is the plugin↔sidecar transport. SQL transport kept as switchable fallback (`cg_auth_transport sql`). | `docs/evidence/05-probe2-ripext.txt` |
| 3 | srcdslab `smac_wallhack` loads and activates on v92 (incl. CS:S FarESP radar)? | **Loads and runs.** SMAC 0.8.8.1 core + `smac_wallhack` "Status: running", `smac_wallhack 1`, `smac_wallhack_maxtraces 1280`; Lilac 1.7.11 running with `lilac_ban 0`. No SM errors. FarESP has no separate switch — it is part of `smac_wallhack` on `Engine_CSS`. Activation against a real wallhacking client is not something this run can observe. | keep it, tune `smac_wallhack_maxtraces` after the load test | `docs/evidence/04-probe3-smac-lilac-loaded.txt` |
| 4 | Load test | pending | — | — |

Notes
- Probe 2 also confirms the **pinned** SM build (7179) + current RIPExt (built against 1.12-dev mid-2025) are ABI compatible.
