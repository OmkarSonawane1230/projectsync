#!/bin/bash
# Project Sync - incremental project mirror between machines.
# Transport: transfer.sh over HTTPS with AES-256-CBC client-side encryption.
# No relay servers, no extra installs beyond curl and openssl.
#
# Sync state lives in a hidden .sync-state/ directory so the receiver
# never sees the sender's commit history - only the latest files.

# ----- safety -----
# We deliberately don't use 'set -e' because we need to inspect exit codes
# from piped commands (PIPESTATUS) and tolerate non-zero from informational
# git checks. Errors are handled explicitly throughout.
set -u

BUNDLE="/tmp/project_sync.bundle"
BUNDLE_ENC="/tmp/project_sync.bundle.enc"
SYNC_DIR=".sync-state"
LAST_SENT_REF="refs/sync/last-sent"
DEFAULT_BRANCH="main"
LITTERBOX_API="https://litterbox.catbox.moe/resources/internals/api.php"

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

# ----- prerequisite check -----
# curl and openssl ship pre-installed on Replit, Codespaces, macOS,
# and every major Linux distribution - no install step needed.

ensure_deps() {
    local missing=""
    command -v curl    >/dev/null 2>&1 || missing="$missing curl"
    command -v openssl >/dev/null 2>&1 || missing="$missing openssl"
    if [ -n "$missing" ]; then
        fatal "Required tools not found:$missing — install them and retry."
    fi
}

# ----- sync state init -----

ensure_sync_state() {
    if [ ! -d "$SYNC_DIR" ]; then
        info setup "initializing sync state on this machine..."
        if ! sgit init -q -b "$DEFAULT_BRANCH" 2>/dev/null; then
            # Older git without -b
            sgit init -q || fatal "sync state init failed"
            sgit symbolic-ref HEAD "refs/heads/$DEFAULT_BRANCH"
        fi
    fi

    sgit config user.email "sync@local"
    sgit config user.name  "Project Sync"

    # Private excludes - never synced regardless of user's .gitignore.
    mkdir -p "$SYNC_DIR/info"
    cat > "$SYNC_DIR/info/exclude" <<'EOF'
# Project Sync private excludes - managed by sync.sh, do not edit.
.sync-state/
.git/
project_sync.bundle
project_sync.bundle.enc
project_sync.tar.gz
EOF

    # Friendly default user-editable .gitignore (only if absent).
    if [ ! -f ".gitignore" ]; then
        cat > .gitignore <<'EOF'
# Project Sync default ignores - edit to control what gets synced.
node_modules/
.cache/
.local/
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

# ----- encryption key generation -----
# Produces 64 hex characters (256 bits) of randomness.

generate_key() {
    head -c 32 /dev/urandom | od -An -txC | tr -d ' \n'
}

# ----- send -----

_send_cancel() {
    echo ""
    rm -f "$BUNDLE" "$BUNDLE_ENC"
    # No delete API on litterbox - but the key was never shared, so the
    # encrypted file on the server is permanently inaccessible to anyone.
    # It auto-deletes in 24 h regardless.
    err "Send was cancelled. The 'last sent' marker was NOT advanced; safe to retry."
    exit 130
}

send() {
    local force_full=0
    [ "${1:-}" = "--full" ] && force_full=1

    trap _send_cancel INT TERM

    banner
    ensure_deps
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

    info "3/4" "Encrypting and uploading..."

    # Generate a 256-bit random key for this transfer only.
    local key
    key=$(generate_key)

    # Encrypt the bundle before it leaves this machine.
    # Litterbox never sees plaintext - only AES-256 ciphertext.
    if ! openssl enc -aes-256-cbc -pbkdf2 \
            -pass "pass:$key" -in "$BUNDLE" -out "$BUNDLE_ENC" 2>/dev/null; then
        fatal "Encryption failed"
    fi

    # Upload ciphertext to litterbox.catbox.moe (1 GB limit, 24 h expiry).
    local url
    url=$(curl -sS --fail \
        -F 'reqtype=fileupload' \
        -F 'time=24h' \
        -F "fileToUpload=@$BUNDLE_ENC" \
        "$LITTERBOX_API" 2>&1)
    local curl_rc=$?
    rm -f "$BUNDLE_ENC"

    if [ "$curl_rc" -ne 0 ] || [ -z "$url" ]; then
        fatal "Upload failed (curl exit $curl_rc). Check your connection and retry."
    fi

    echo "       encrypted and uploaded ($(du -h "$BUNDLE" | cut -f1))"

    # The code is the URL fused with the decryption key.
    # Without both halves the ciphertext on the server is permanently useless.
    local code="${url}::${key}"

    info "4/4" "Waiting for receiver..."
    echo ""
    echo "    --------------------------------------------------"
    echo "    On the OTHER machine, run:"
    echo ""
    echo "        ./sync.sh receive $code"
    echo ""
    echo "    - File is AES-256 encrypted - server never sees your code."
    echo "    - Auto-deletes from server in 24 hours regardless."
    echo "    - Press Ctrl+C to cancel (key never shared = file unreadable by anyone)."
    echo "    --------------------------------------------------"
    echo ""
    echo "    Press ENTER once the receiver confirms success:"

    # Block here so Ctrl+C can still trigger _send_cancel above.
    # Reading from /dev/tty works even when stdin is redirected.
    read -r _confirm </dev/tty || true

    # Receiver confirmed - clear the cancel trap.
    trap - INT TERM

    # Only advance the marker now that the receiver has confirmed.
    if ! sgit update-ref "$LAST_SENT_REF" HEAD; then
        fatal "Receiver confirmed but failed to update sync marker"
    fi

    rm -f "$BUNDLE"

    echo ""
    echo "  SEND COMPLETE - the receiver has the latest files."
    echo "  Future sends will only ship what changed."
}

# ----- receive -----

receive() {
    local full_code="${1:-}"
    if [ -z "$full_code" ]; then
        err "Provide the code shown by the sender."
        echo "Usage: ./sync.sh receive <code>"
        exit 2
    fi

    # Split <url>::<key>
    local url key
    url="${full_code%%::*}"
    key="${full_code##*::}"

    if [ -z "$url" ] || [ -z "$key" ] || [ "$url" = "$full_code" ]; then
        fatal "Invalid code format. Expected the full string printed by the sender."
    fi

    banner
    ensure_deps
    ensure_sync_state

    info "1/4" "Downloading bundle..."

    local enc_file
    enc_file=$(mktemp /tmp/sync_recv.XXXXXX) || fatal "Could not create temp file"
    trap "rm -f '$enc_file'" EXIT

    if ! curl -sS --fail -L -o "$enc_file" "$url"; then
        err "Download failed. The code may have already been used or expired."
        exit 1
    fi
    echo "       downloaded"

    info "2/4" "Decrypting bundle..."

    local bundle_file
    bundle_file=$(mktemp /tmp/sync_bundle.XXXXXX) || fatal "Could not create temp file"
    trap "rm -f '$enc_file' '$bundle_file'" EXIT

    if ! openssl enc -d -aes-256-cbc -pbkdf2 \
            -pass "pass:$key" -in "$enc_file" -out "$bundle_file" 2>/dev/null; then
        err "Decryption failed. The code may be wrong or the download corrupted."
        exit 1
    fi
    rm -f "$enc_file"
    echo "       decrypted"

    info "3/4" "Verifying bundle..."

    local verify_out verify_rc
    verify_out=$(sgit bundle verify "$bundle_file" 2>&1)
    verify_rc=$?
    if [ $verify_rc -ne 0 ]; then
        if echo "$verify_out" | grep -q -iE "lacks these prerequisite|needs these|missing prerequisite"; then
            err "Bundle is incremental but this machine is missing earlier history."
            echo "       Ask the sender to run a full re-send:"
            echo ""
            echo "           ./sync.sh send --full"
            echo ""
        else
            err "Bundle verification failed."
            echo "$verify_out" | sed 's/^/       /' >&2
        fi
        exit 1
    fi
    echo "       bundle verified ok"

    local incoming_branch
    incoming_branch=$(sgit bundle list-heads "$bundle_file" \
                      | awk '/refs\/heads\// {sub("refs/heads/","",$2); print $2; exit}')
    [ -z "$incoming_branch" ] && incoming_branch="$DEFAULT_BRANCH"

    info "4/4" "Applying snapshot..."

    if ! sgit fetch "$bundle_file" "+refs/heads/*:refs/sync/incoming/*" 2>/dev/null; then
        fatal "fetch from bundle failed"
    fi

    # Force checkout of the sender's branch, overwriting working-tree files.
    # This is the intended "receive overrides project" behaviour.
    if ! sgit checkout -q -f -B "$incoming_branch" \
            "refs/sync/incoming/$incoming_branch" 2>/dev/null; then
        fatal "Failed to apply snapshot"
    fi
    if ! sgit reset -q --hard "refs/sync/incoming/$incoming_branch"; then
        fatal "Failed to reset working tree"
    fi

    rm -f "$bundle_file"

    local file_count
    file_count=$(sgit ls-files | wc -l | tr -d ' ')

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
  - The bundle is AES-256 encrypted before upload. The server never
    sees plaintext - only someone with the full code can decrypt it.
  - The code is <url>::<key>. Without both halves the file is unreadable.
  - Ctrl+C on the sender cancels without sharing the key - the encrypted
    file on the server becomes permanently inaccessible to anyone and
    auto-deletes within 24 hours.
  - Files auto-delete from the server after 24 h (1 GB max per transfer).
  - The "last sent" marker only advances after the receiver confirms,
    so a failed or cancelled send is always safe to retry.

Requirements:
  - curl and openssl (pre-installed on Replit, Codespaces, macOS, Linux)
  - No relay servers, no accounts, no extra installs.
EOF
}

# ----- entry -----

case "${1:-}" in
    send)    send "${2:-}" ;;
    receive) receive "${2:-}" ;;
    "")      usage ;;
    *)       err "Unknown command: $1"; echo ""; usage; exit 2 ;;
esac
