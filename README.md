# Project Sync

Single-script peer-to-peer project mirror between two Replit accounts.
No GitHub, no third-party accounts, no relay configuration.

## Files in this Replit

- `sync.sh` — the only project file. Production script (~330 lines).
- `replit.md` — this file.

## How it works

1. **Hidden `.sync-state/` git dir** is used as a snapshot engine — `GIT_DIR`
   and `GIT_WORK_TREE` are set explicitly so the user's project root never
   gets a `.git/` planted by us. The user can keep their own `.git/`
   alongside without any conflict.
2. **`git bundle`** packages the latest changes (full or incremental) into a
   single binary file: `/tmp/project_sync.bundle`.
3. **`croc`** transfers that bundle peer-to-peer between the two Replits
   using a one-time code phrase. (Public croc relay `204.168.131.42:9009`.)
4. The receiver verifies the bundle and applies it via `git fetch` +
   `git checkout -fB` against its own `.sync-state/`. Files are written to
   the working tree, but the sender's commit log is **not** exposed —
   `git log` from the receiver's project root shows nothing of ours.

The very first send transfers the whole snapshot. Subsequent sends transfer
only what changed since the last successful send.

## Usage

```
./sync.sh send              # snapshot + send; prints copy-paste receive line
./sync.sh send --full       # force a full re-send (use after receiver wipe)
./sync.sh receive <code>    # apply the bundle the sender shipped
```

`./sync.sh` with no args prints usage.

## Workflow

There is one workflow, `Sync Help`, that runs `bash sync.sh` so the usage text
is visible in the workspace console without typing.

## Design decisions / invariants

- **Code phrase is generated locally** by the script (`sync-XXXX-XXXX-XXXX`,
  16 random hex chars). This lets the script print the receive line *before*
  croc starts, so the user can copy-paste immediately.
- **`croc` quirks (v10.4.2):** the `--code` flag is broken in v10's `send`,
  so the code is passed via the `CROC_SECRET` environment variable. The
  receiver also uses `CROC_SECRET=<code> croc --yes --overwrite` (no
  positional code).
- **Git fetch namespace:** bundles are fetched into `refs/sync/incoming/*`
  (not `refs/heads/*`) so we don't trip "refusing to fetch into checked-out
  branch". A subsequent `git checkout -fB` is what advances the working tree.
- **Marker safety:** the ref `refs/sync/last-sent` (inside `.sync-state/`)
  only advances when croc itself reports a successful transfer
  (`PIPESTATUS[0] == 0`). On any failure or interrupt (SIGINT/SIGTERM trap),
  the marker is preserved so the user can safely retry.

- **No commit history exposed to receiver:** all sync git operations use
  `GIT_DIR=$PWD/.sync-state GIT_WORK_TREE=$PWD git ...` via the `sgit()`
  wrapper. The user never sees a `.git/` planted by us. From the receiver's
  perspective `git log` reports "not a git repository" — they get a clean
  snapshot of files only.

- **Private excludes** (`.sync-state/info/exclude`) always exclude
  `.sync-state/`, `.git/`, and the bundle file from being synced, regardless
  of what the user puts in `.gitignore`. So the user can have their own
  `.git/` for their own version control without it leaking across Replits.
- **Output filtering:** croc's "On the other computer run..." block is grepped
  out so the only copy-paste line the user sees is the one the script prints.
- **Croc auto-install:** `~/.local/bin/croc` is downloaded on first run and
  re-used silently after that (idempotent on both ends).
- **Default `.gitignore`** excludes `node_modules/`, `.cache/`, `.local/`,
  `.agents/`, `.upm/`, `__pycache__/`, `.venv/`, `dist/`, `build/`, `.next/`,
  `.nuxt/`, `out/`, `target/`, `*.log`, `.DS_Store`, and the bundle file
  itself. Users edit `.gitignore` to control what gets synced.
- **No emojis.** Pure ASCII output. Section headers are `[stage N/4]` style.

## Tested scenarios (all green)

1. Full send + receive (clean repo on both ends)
2. `node_modules/` and `*.log` are excluded by default `.gitignore`
3. Croc already installed -> no reinstall on either side
4. Send with no changes -> "Nothing new since last successful send"
5. `send --full` clears marker and rebuilds full bundle
6. Receive with a code that nobody is sending -> clean error + non-zero exit
7. Incremental bundle to a fresh receiver -> "missing earlier history" with
   "run `./sync.sh send --full`" hint
8. SIGINT mid-handshake on sender -> marker NOT advanced, clean message,
   exit 130
9. `./sync.sh` with no args prints usage; unknown command exits 2
