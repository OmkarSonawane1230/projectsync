#!/bin/bash
# Project Sync - incremental project mirror between two Replit accounts.
# No third-party accounts, no remote services. Peer-to-peer via croc.
#
# Sync state lives in a hidden .sync-state/ directory so the receiver
# never sees the sender's commit history - only the latest files.

# ----- safety -----
# We deliberately don't use 'set -e' because we need to inspect exit codes
# from piped commands (PIPESTATUS) and tolerate non-zero from informational
# git checks. Errors are handled explicitly throughout.
set -u

BUNDLE="/tmp/project_sync.bundle"
SYNC_DIR=".sync-state"
LAST_SENT_REF="refs/sync/last-sent"
DEFAULT_BRANCH="main"
CROC_VERSION="v10.4.2"
CROC_BIN="$HOME/.local/bin/croc"

# ----- output helpers -----

banner() {
    echo "=================================================="
    echo "  PROJECT SYNC"
    echo "=================================================="
}

info()  { echo "[$1] $2"; }
err()   { echo "ERROR: $*" >&2; }
fatal() { err "$*"; exit 1; }

# ----- private git wrapper -----
# All sync bookkeeping uses .sync-state/ as the git dir, with the project
# root as the work tree. This way the user never sees a .git/ planted by
# us, and 'git log' in their project shows nothing of ours.
sgit() {
    GIT_DIR="$PWD/$SYNC_DIR" GIT_WORK_TREE="$PWD" git "$@"
}

# ----- prerequisite setup -----

ensure_croc() {
    if command -v croc >/dev/null 2>&1; then
        return 0
    fi
    if [ -x "$CROC_BIN" ]; then
        export PATH="$HOME/.local/bin:$PATH"
        return 0
    fi

    info setup "croc not found, installing (one-time, ~8 MB)..."

    mkdir -p "$HOME/.local/bin" || fatal "Could not create $HOME/.local/bin"

    local arch asset
    arch=$(uname -m)
    case "$arch" in
        x86_64)  asset="Linux-64bit" ;;
        aarch64) asset="Linux-ARM64" ;;
        *) fatal "Unsupported CPU architecture: $arch" ;;
    esac

    local url="https://github.com/schollz/croc/releases/download/${CROC_VERSION}/croc_${CROC_VERSION}_${asset}.tar.gz"
    local tmp="/tmp/croc-install.$$"
    mkdir -p "$tmp" || fatal "Could not create $tmp"

    if ! curl -L --fail --silent --show-error --max-time 60 "$url" -o "$tmp/croc.tar.gz" 2>"$tmp/curl.err"; then
        err "Failed to download croc:"
        sed 's/^/       /' "$tmp/curl.err" >&2
        rm -rf "$tmp"
        exit 1
    fi
    if ! tar -xzf "$tmp/croc.tar.gz" -C "$tmp" croc 2>/dev/null; then
        rm -rf "$tmp"
        fatal "Failed to extract croc archive"
    fi
    if ! mv "$tmp/croc" "$CROC_BIN" || ! chmod +x "$CROC_BIN"; then
        rm -rf "$tmp"
        fatal "Failed to install croc to $CROC_BIN"
    fi
    rm -rf "$tmp"
    export PATH="$HOME/.local/bin:$PATH"
    info setup "croc installed: $(croc --version 2>/dev/null | awk '{print $NF}')"
}

ensure_sync_state() {
    if [ ! -d "$SYNC_DIR" ]; then
        info setup "initializing sync state on this Replit..."
        if ! sgit init -q -b "$DEFAULT_BRANCH" 2>/dev/null; then
            # Older git without -b
            sgit init -q || fatal "sync state init failed"
            sgit symbolic-ref HEAD "refs/heads/$DEFAULT_BRANCH"
        fi
    fi

    sgit config user.email "sync@replit.local"
    sgit config user.name  "Project Sync"

    # Private excludes - never synced regardless of user's .gitignore.
    mkdir -p "$SYNC_DIR/info"
    cat > "$SYNC_DIR/info/exclude" <<'EOF'
# Project Sync private excludes - managed by sync.sh, do not edit.
.sync-state/
.git/
project_sync.bundle
project_sync.tar.gz
EOF

    # Friendly default user-editable .gitignore (only if absent).
    if [ ! -f ".gitignore" ]; then
        cat > .gitignore <<'EOF'
# Project Sync default ignores - edit to control what gets synced.
node_modules/
.cache/
.local/
.agents/
.upm/
__pycache__/
*.pyc
.venv/
venv/
dist/
build/
.next/
.nuxt/
out/
target/
.DS_Store
*.log
EOF
        info setup "created default .gitignore (edit it to control what gets synced)"
    fi
}

# ----- code generation -----

# Generate a random, easy-to-type code phrase.
# Format: sync-XXXX-XXXX-XXXX  (16 hex chars total)
generate_code() {
    local h
    if h=$(head -c 12 /dev/urandom 2>/dev/null | od -An -txC | tr -d ' \n'); then
        printf 'sync-%s-%s-%s' "${h:0:4}" "${h:8:4}" "${h:16:4}"
    else
        # Extremely unlikely fallback
        printf 'sync-%04x-%04x-%04x' \
            $((RANDOM*RANDOM%65536)) $((RANDOM*RANDOM%65536)) $((RANDOM*RANDOM%65536))
    fi
}

# ----- output filters for croc -----

# Strip croc's own "Code is..." / "On the other computer run..." block.
# We print our own copy-paste line above instead.
filter_croc_send() {
    grep -v -E '^(Code is: |On the other computer run:|\(For Windows\)|\(For Linux/macOS\)|    croc |    CROC_SECRET=)' \
        || true
}

# Strip git bundle verify chatter.
filter_bundle_chatter() {
    grep -v -E '^(The bundle (contains|requires|records|uses)|[a-f0-9]{40} )' \
        || true
}

# ----- send -----

_send_interrupted() {
    echo ""
    err "Send was interrupted before completion."
    err "The 'last sent' marker was NOT advanced; safe to retry."
    exit 130
}

send() {
    local force_full=0
    [ "${1:-}" = "--full" ] && force_full=1

    trap _send_interrupted INT TERM

    banner
    ensure_croc
    ensure_sync_state

    info "1/4" "Snapshotting project files..."
    if ! sgit add -A; then
        fatal "snapshot failed"
    fi
    if sgit diff --cached --quiet; then
        echo "       (no file changes since last snapshot)"
    else
        if ! sgit commit -q -m "snapshot: $(date -u +%Y-%m-%dT%H:%M:%SZ)"; then
            fatal "snapshot commit failed"
        fi
        echo "       snapshot saved"
    fi

    if ! sgit rev-parse --verify HEAD >/dev/null 2>&1; then
        fatal "Project is empty - add some files first."
    fi

    if [ "$force_full" -eq 1 ] && sgit rev-parse --verify "$LAST_SENT_REF" >/dev/null 2>&1; then
        sgit update-ref -d "$LAST_SENT_REF"
        info "1/4" "--full given: cleared previous send marker"
    fi

    info "2/4" "Building bundle..."
    rm -f "$BUNDLE"
    if sgit rev-parse --verify "$LAST_SENT_REF" >/dev/null 2>&1; then
        if sgit diff --quiet "$LAST_SENT_REF" HEAD; then
            echo "       Nothing new since last successful send."
            echo "       (use './sync.sh send --full' to re-send everything)"
            exit 0
        fi
        local branch
        branch=$(sgit symbolic-ref --short HEAD 2>/dev/null || echo "$DEFAULT_BRANCH")
        if ! sgit bundle create "$BUNDLE" "${LAST_SENT_REF}..HEAD" "$branch" >/dev/null 2>&1; then
            fatal "Failed to build incremental bundle"
        fi
        echo "       built incremental bundle: $(du -h "$BUNDLE" | cut -f1)"
    else
        if ! sgit bundle create "$BUNDLE" --all >/dev/null 2>&1; then
            fatal "Failed to build full bundle"
        fi
        echo "       built full bundle: $(du -h "$BUNDLE" | cut -f1)"
    fi

    local code
    code=$(generate_code)

    info "3/4" "Waiting for receiver..."
    echo ""
    echo "    --------------------------------------------------"
    echo "    On the OTHER Replit, run this command:"
    echo ""
    echo "        ./sync.sh receive $code"
    echo ""
    echo "    Keep THIS terminal open until the transfer finishes."
    echo "    --------------------------------------------------"
    echo ""

    # Run croc with our pre-shared code. Filter out its redundant
    # "On the other computer run..." block since we showed our own.
    # We capture the real exit code via PIPESTATUS so the marker only
    # advances when croc itself reports a successful transfer.
    CROC_SECRET="$code" croc --yes send "$BUNDLE" 2>&1 | filter_croc_send
    local croc_rc="${PIPESTATUS[0]}"

    if [ "$croc_rc" -ne 0 ]; then
        echo ""
        err "Transfer did not complete (croc exit code $croc_rc)."
        err "The 'last sent' marker was NOT advanced; safe to retry."
        exit 1
    fi

    if ! sgit update-ref "$LAST_SENT_REF" HEAD; then
        fatal "Transfer succeeded but failed to update sync marker"
    fi

    info "4/4" "Done."
    echo ""
    echo "  SEND COMPLETE - the receiver has the latest files."
    echo "  Future sends will only ship what changed."
}

# ----- receive -----

_RECV_DL_DIR=""
_recv_cleanup() {
    if [ -n "${_RECV_DL_DIR:-}" ] && [ -d "$_RECV_DL_DIR" ]; then
        rm -rf "$_RECV_DL_DIR"
    fi
}

receive() {
    local code="${1:-}"
    if [ -z "$code" ]; then
        err "Provide the code shown by the sender."
        echo "Usage: ./sync.sh receive <code>"
        exit 2
    fi

    banner
    ensure_croc
    ensure_sync_state

    info "1/4" "Connecting to sender (code: $code)..."

    _RECV_DL_DIR=$(mktemp -d) || fatal "Could not create temp dir"
    trap _recv_cleanup EXIT
    local dl_dir="$_RECV_DL_DIR"

    # Run croc inside the temp dir; pipe through filter to drop noise.
    ( cd "$dl_dir" && CROC_SECRET="$code" croc --yes --overwrite ) 2>&1 | filter_croc_send
    local croc_rc="${PIPESTATUS[0]}"
    if [ "$croc_rc" -ne 0 ]; then
        err "Did not receive any file (croc exit code $croc_rc)."
        err "Make sure the sender's './sync.sh send' is still running with the same code."
        exit 1
    fi

    local bundle_path="$dl_dir/project_sync.bundle"
    if [ ! -s "$bundle_path" ]; then
        # croc may have placed it under a different name - pick the only file
        bundle_path=$(find "$dl_dir" -type f -size +0c | head -1)
    fi
    if [ -z "$bundle_path" ] || [ ! -s "$bundle_path" ]; then
        fatal "Connection succeeded but no file was received."
    fi

    info "2/4" "Verifying bundle..."
    local verify_out verify_rc
    verify_out=$(sgit bundle verify "$bundle_path" 2>&1)
    verify_rc=$?
    if [ $verify_rc -ne 0 ]; then
        if echo "$verify_out" | grep -q -iE "lacks these prerequisite|needs these|missing prerequisite"; then
            err "Bundle is incremental, but this Replit is missing earlier history."
            echo "       Ask the sender to run a full re-send:"
            echo ""
            echo "           ./sync.sh send --full"
            echo ""
        else
            err "Received file is not a valid bundle."
            echo "$verify_out" | sed 's/^/       /' >&2
        fi
        exit 1
    fi
    echo "       bundle verified ok"

    local incoming_branch
    incoming_branch=$(sgit bundle list-heads "$bundle_path" \
                      | awk '/refs\/heads\// {sub("refs/heads/","",$2); print $2; exit}')
    [ -z "$incoming_branch" ] && incoming_branch="$DEFAULT_BRANCH"

    info "3/4" "Applying snapshot..."
    if ! sgit fetch "$bundle_path" "+refs/heads/*:refs/sync/incoming/*" 2>&1 | filter_bundle_chatter; then
        local fetch_rc="${PIPESTATUS[0]}"
        [ "$fetch_rc" -ne 0 ] && fatal "fetch from bundle failed"
    fi

    # Force checkout of the sender's branch, overwriting working-tree files.
    # This is the intended "receive overrides project" behavior.
    if ! sgit checkout -q -f -B "$incoming_branch" "refs/sync/incoming/$incoming_branch" 2>/dev/null; then
        fatal "Failed to apply snapshot"
    fi
    if ! sgit reset -q --hard "refs/sync/incoming/$incoming_branch"; then
        fatal "Failed to reset working tree"
    fi

    local file_count
    file_count=$(sgit ls-files | wc -l | tr -d ' ')

    info "4/4" "Done."
    echo ""
    echo "  SYNC COMPLETE - $file_count files in sync with the sender."
    echo "  (No commit history was transferred - this is a clean snapshot.)"
}

# ----- usage -----

usage() {
    cat <<'EOF'
==================================================
  PROJECT SYNC
==================================================

Usage:
  ./sync.sh send              Snapshot this project and start a transfer.
                              Prints a copy-paste command for the receiver.

  ./sync.sh send --full       Force a full re-send (ignore "already sent"
                              marker). Use when the receiver is fresh or
                              when sender and receiver got out of sync.

  ./sync.sh receive <code>    Pull a snapshot using the sender's code.

How it works:
  - Sync bookkeeping lives in a hidden .sync-state/ directory.
  - The receiver gets only the latest files, NOT the sender's commit log.
  - First send transfers everything; later sends only ship what changed.
  - .gitignore controls which files get synced (.sync-state/ and .git/
    are always excluded automatically).
  - Transfer is peer-to-peer via croc (auto-installed on first run).
  - The send command must stay running until the receiver finishes.
  - The "last sent" marker only advances when the transfer fully succeeds,
    so a failed send is always safe to retry.
EOF
}

# ----- entry -----

case "${1:-}" in
    send)    send "${2:-}" ;;
    receive) receive "${2:-}" ;;
    "")      usage ;;
    *)       err "Unknown command: $1"; echo ""; usage; exit 2 ;;
esac
