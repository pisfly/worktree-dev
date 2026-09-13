# dev.sh — multi-worktree dev orchestrator

Run multiple coding agents (or just multiple feature branches) in parallel on the same monorepo — with full hot reload, no port collisions, and no Docker.

Designed for the case where you want to give each Claude Code / Cursor / human session its own isolated dev environment that's instantly ready to play with — and that an autonomous agent can start, query, and tear down without guessing.

## The problem

When two branches run at the same time, everything wants to bind the same default ports — backend on 9000, web on 3000, Metro on 8081. `node_modules` gets stepped on, CocoaPods generates broken symlinks, the simulator loads the wrong JS bundle. You end up spending more time plumbing environments than actually coding.

Containers solve isolation but kill the dev loop: filesystem watchers across volume mounts get flaky on macOS, HMR latency creeps up, every code change waits on image rebuilds. The whole point of running multiple agents in parallel is moving faster, so containers are the wrong tradeoff.

## The approach

Use **git worktrees** instead. Each worktree is a checkout of a different branch in its own folder, sharing the same `.git` underneath — free isolation on the filesystem with native fs and native hot reload.

`dev.sh` handles the rest, docker-compose style:

- Hashes the worktree name into a deterministic port slot (0–19): backend on `9000 + slot`, web on `3000 + slot`, Metro on `8081 + slot` — never collides between worktrees
- `up` is an idempotent, health-gated **converge**: it attaches to services that are already healthy, restarts dead ones, and refuses (loudly) if a foreign process squats on a port
- Services detach into their own sessions and log to `.dev/logs/<svc>.log` — they keep running after your terminal (or your agent's shell) exits
- `status --json` gives machine-readable per-service state with meaningful exit codes, so agents can script against it
- Auto-writes a host/port config file the mobile app reads at runtime, so the simulator always points at *this* worktree's backend
- Concurrent `up`/`stop` runs are serialized with locks (with stale-lock recovery), so two agents racing to start the stack can't corrupt it

Zero dependencies beyond stock macOS.

## Commands

```
./dev.sh up [ios|device|android] [sim-name]   # start/converge the stack (idempotent, health-gated)
./dev.sh status [--json]    # per-service state; exit 0 healthy / 1 down / 2 partial / 3 conflict
./dev.sh stop [--force]     # tear down this worktree's stack (--force: reap by port, ignores state)
./dev.sh logs <svc> [-f]    # svc: backend | web | metro | mobile | build
./dev.sh                    # up + follow combined logs (Ctrl+C detaches — does NOT stop the stack)
./dev.sh ios [sim-name]     # shorthand for: up ios
```

Flags:

```
--force / -f      with up: nuke mobile node_modules/Pods/DerivedData, reinstall, rebuild
--timeout <sec>   with up: health-gate timeout (default 300)
--own-sim         with up ios: build onto a per-worktree simulator clone (side-by-side worktrees)
--json            with status: machine-readable output
```

`up` returns only when every service actually answers its health probe (the docker `--wait` contract) — including the backend's first compile. If a service dies while starting, `up` says so immediately with the last log lines instead of waiting out the timeout.

## Metro is per-worktree too

React Native bakes the Metro port into the native build at compile time (`RCT_METRO_PORT`), which is exactly why each worktree gets its **own** Metro on `8081 + slot`: the app built from a worktree talks to that worktree's Metro, and can never silently load another branch's JS bundle.

By default all worktrees build onto the same simulator (last build wins). With `--own-sim`, each worktree clones the base simulator once (`wt-<worktree-name>`) and builds onto its clone, so two agents can run their apps side by side.

## Agent-friendliness

The state model is what makes this usable by autonomous agents:

- `./dev.sh status --json` reports each service's state (`stopped | starting | healthy | stale | conflict`), port, pid, URL, and log path, plus the simulator UDID and app bundle id when known — no `lsof`/`simctl` archaeology needed.
- Exit codes are contractual: `0` healthy, `1` down, `2` partial, `3` port conflict.
- State lives in `.dev/state.env` (bash-parseable key=value). The script never trusts it blindly — process identity is verified via start-time (defeats PID reuse) and port ownership via `lsof` before anything is reaped.
- The app's own `console.log` output lands in `.dev/logs/mobile.log` (RN 0.76+ routes JS logs to DevTools, not Metro's stdout; a small helper subscribes to Metro's inspector to capture them — drop `metro-console-tail.js` into `mobile/scripts/` to enable it).
- Native builds serialize on a separate lock from server startup, so one agent's long xcodebuild never blocks another agent's server-only `up`.

## Configuration

Everything project-specific lives in the `CONFIGURATION` block at the top of the script:

| Variable              | Default                          | What it is                                        |
|-----------------------|----------------------------------|---------------------------------------------------|
| `BACKEND_DIR`         | `backend`                        | Backend subdir (template assumes Scala + Play)    |
| `WEB_DIR`             | `web`                            | Web subdir (template assumes Next.js)             |
| `MOBILE_DIR`          | `mobile`                         | Mobile subdir (template assumes React Native)     |
| `BACKEND_HEALTH_PATH` | `/api/health`                    | Backend endpoint the health gate probes           |
| `DEV_PORTS_REL_PATH`  | `src/config/devPorts.local.ts`   | Where the generated host/port config is written   |
| `BACKEND_PORT_BASE`   | `9000`                           | Backend port = base + slot                        |
| `WEB_PORT_BASE`       | `3000`                           | Web port = base + slot                            |
| `METRO_PORT_BASE`     | `8081`                           | Metro port = base + slot                          |
| `SLOT_COUNT`          | `20`                             | Number of port slots                              |
| `DEFAULT_IOS_SIM`     | `iPhone 17 Pro`                  | Simulator when `$IOS_SIM` isn't set               |

The dev-server commands themselves (sbt / next / react-native) live in `start_service()` — adapt them if your stack differs.

## Quick start

1. Copy `dev.sh` into the root of your monorepo and make it executable:
   ```
   chmod +x dev.sh
   ```
2. Edit the `CONFIGURATION` block at the top (subdir names, health path, port bases, simulator).
3. Edit the commands in `start_service()` if your stack isn't Scala + Next.js + RN.
4. Gitignore the generated files:
   ```
   .dev/
   devPorts.local.ts
   ```
5. From any worktree:
   ```
   ./dev.sh up        # backend + web + metro, health-gated
   ./dev.sh up ios    # also build & run iOS sim
   ./dev.sh status    # is it up?
   ./dev.sh stop      # tear it down
   ```

## Mobile app integration

On every `up`, the script writes `$MOBILE_DIR/$DEV_PORTS_REL_PATH` (default `mobile/src/config/devPorts.local.ts`):

```ts
// AUTO-GENERATED by dev.sh — do not edit by hand. Gitignored.
export const DEV_HOST = '192.168.1.42';
export const DEV_API_PORT = 9007;
export const DEV_WEB_PORT = 3007;
```

Your mobile app should read from this file at runtime to know where its backend lives. Recommended pattern: commit a `devPorts.ts` with safe defaults, and have your `constants.ts` (or equivalent) import from `devPorts.local` first, falling back to `devPorts` if `.local` is missing. A postinstall script can bootstrap the `.local` file on fresh checkouts.

## Why git worktrees instead of multiple clones

A worktree is a separate checkout of a branch sharing the same underlying `.git`. Compared to multiple clones:

- No re-fetching object data
- Git objects are deduplicated on disk
- Branch state stays in sync across worktrees
- Quick to spin up

```
git worktree add ../feature-x feature-x
cd ../feature-x
./dev.sh up
```

## How port slots work

```
slot     = cksum(worktree-name) % 20
backend  = 9000 + slot
web      = 3000 + slot
metro    = 8081 + slot
```

20 slots is arbitrary — bump `SLOT_COUNT` if you regularly run more than ~10 worktrees and start hitting hash collisions. Two worktrees that hash to the same slot can't run simultaneously; easiest fix is renaming one of them.

## Caveats

- **macOS only** for the iOS pieces (and the script currently assumes macOS primitives — `lsof`, `stat -f`, `mkdir` locks). Linux users can adapt the worktree + port-slot logic for backend + web.
- **`mobile/node_modules` is duplicated per worktree** (~1GB each). Required because CocoaPods generates broken header symlinks if `node_modules` is itself a symlink. `web/node_modules` is symlinked from the main checkout (Next.js handles this fine).
- **`pod install` runs once per worktree** the first time you build iOS, takes 1–2 min. CocoaPods bakes worktree-absolute paths into its xcconfig, so it can't be shared.
- **DerivedData per workspace path.** A `--force` clean only nukes this worktree's caches (including its Watchman watch root), not anyone else's.
- **Shared simulator by default.** Without `--own-sim`, two worktrees building iOS target the same simulator and the last build wins. `--own-sim` costs a one-time simulator clone (~30s) per worktree.

## License

MIT
