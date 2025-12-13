#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SAFEEXEC: Destructive Command Interceptor + Toggle
#
# - Gates: rm -rf
# - Gates: git reset/revert/checkout/restore (+ clean -f, switch -f, stash drop/clear/pop)
# - Installs shims:
#     /usr/local/bin/rm  -> /usr/local/safeexec/bin/rm
#     /usr/local/bin/git -> /usr/local/safeexec/bin/git
#   and on macOS/Homebrew:
#     /opt/homebrew/bin/git shim (backs up original to git.safeexec.real) so gating works
# - Toggle:
#     safeexec -on | -off | status   (per-user)
#     also supports: on/off/status, OFF/ON, -status
# =============================================================================

SAFEEXEC_DIR="/usr/local/safeexec/bin"
LOCALBIN="/usr/local/bin"

PROFILED="/etc/profile.d/safeexec.sh"
SUDOERS_FILE="/etc/sudoers.d/safeexec"

HOMEBREW_BIN="/opt/homebrew/bin"
HOMEBREW_GIT="$HOMEBREW_BIN/git"
HOMEBREW_GIT_REAL="$HOMEBREW_BIN/git.safeexec.real"

MARK_BEGIN="# SAFEEXEC BEGIN"
MARK_END="# SAFEEXEC END"

die() { echo "safeexec: $*" >&2; exit 1; }
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (sudo)"; }

is_darwin() { [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; }

usage() {
  cat >&2 <<'EOF'
Usage:
  safeexec.sh install
  safeexec.sh uninstall
  safeexec.sh status
  safeexec.sh on|off|toggle|st    # per-user toggle (no sudo required)
EOF
  exit 2
}

# -----------------------------
# Helpers
# -----------------------------

ensure_dir_0755() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    mkdir -p "$d"
    chmod 0755 "$d" 2>/dev/null || true
  fi
}

symlink_points_to() {
  local link="$1" target="$2"
  [[ -L "$link" ]] || return 1
  local got=""
  got="$(readlink "$link" 2>/dev/null || true)"
  [[ "$got" == "$target" ]]
}

file_contains_marker() {
  local f="$1" marker="$2"
  [[ -f "$f" ]] || return 1
  grep -q "$marker" "$f" 2>/dev/null
}

# -----------------------------
# Wrappers (installed into SAFEEXEC_DIR)
# -----------------------------

write_wrapper_rm() {
  ensure_dir_0755 "$SAFEEXEC_DIR"
  local dst="$SAFEEXEC_DIR/rm"

  cat >"$dst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE_USER="${XDG_CONFIG_HOME:-$HOME/.config}/safeexec/disabled"
STATE_FILE_GLOBAL="/usr/local/safeexec/disabled"

is_disabled() {
  [[ "${SAFEEXEC_DISABLED:-}" == "1" ]] && return 0
  [[ -f "$STATE_FILE_GLOBAL" ]] && return 0

  if [[ -n "${SUDO_USER:-}" ]]; then
    local h=""
    h="$(eval "echo ~$SUDO_USER" 2>/dev/null || true)"
    [[ -n "$h" && -f "$h/.config/safeexec/disabled" ]] && return 0
  fi

  [[ -f "$STATE_FILE_USER" ]] && return 0
  return 1
}

log_audit() {
  if command -v logger >/dev/null 2>&1; then
    logger -t safeexec "$*" || true
  fi
}

confirm_or_die() {
  local cmd="$1"
  log_audit "BLOCKED: rm $cmd"

  if [[ ! -e /dev/tty ]]; then
    echo "safeexec: BLOCKED (no /dev/tty): rm $cmd" >&2
    exit 126
  fi

  local reply=""
  printf '\n\033[0;31m[SAFEEXEC] DESTRUCTIVE COMMAND INTERCEPTED:\033[0m\n  rm %s\n' "$cmd" > /dev/tty
  printf 'Type "confirm" to execute: ' > /dev/tty
  IFS= read -r reply < /dev/tty || true
  printf '\n' > /dev/tty

  if [[ "$reply" != "confirm" ]]; then
    echo "safeexec: cancelled" >&2
    exit 130
  fi

  log_audit "CONFIRMED: rm $cmd"
}

# Real rm
REAL_RM=""
for cand in /bin/rm /usr/bin/rm; do
  if [[ -x "$cand" ]] && ! [[ "$cand" -ef "$0" ]]; then
    REAL_RM="$cand"
    break
  fi
done
if [[ -z "$REAL_RM" ]]; then
  REAL_RM="$(command -p -v rm 2>/dev/null || echo '/bin/rm')"
fi

# Disabled => passthrough
if is_disabled; then
  exec "$REAL_RM" "$@"
fi

force=0
rec=0

for arg in "$@"; do
  case "$arg" in
    --) break ;;
    --force) force=1 ;;
    --recursive) rec=1 ;;
    -*)
      [[ "$arg" == "-" ]] && continue
      [[ "$arg" == "--" ]] && break
      opts="${arg#-}"
      [[ "$opts" == *f* ]] && force=1
      [[ "$opts" == *r* || "$opts" == *R* ]] && rec=1
      ;;
    *) ;;
  esac
done

# Gate only rm -rf
if [[ "$force" -eq 1 && "$rec" -eq 1 ]]; then
  cmd_str="$(printf '%q ' "$@")"
  confirm_or_die "$cmd_str"
fi

exec "$REAL_RM" "$@"
EOF

  chmod 0755 "$dst"
}

write_wrapper_git() {
  ensure_dir_0755 "$SAFEEXEC_DIR"
  local dst="$SAFEEXEC_DIR/git"

  cat >"$dst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_FILE_USER="${XDG_CONFIG_HOME:-$HOME/.config}/safeexec/disabled"
STATE_FILE_GLOBAL="/usr/local/safeexec/disabled"

is_disabled() {
  [[ "${SAFEEXEC_DISABLED:-}" == "1" ]] && return 0
  [[ -f "$STATE_FILE_GLOBAL" ]] && return 0

  if [[ -n "${SUDO_USER:-}" ]]; then
    local h=""
    h="$(eval "echo ~$SUDO_USER" 2>/dev/null || true)"
    [[ -n "$h" && -f "$h/.config/safeexec/disabled" ]] && return 0
  fi

  [[ -f "$STATE_FILE_USER" ]] && return 0
  return 1
}

log_audit() {
  if command -v logger >/dev/null 2>&1; then
    logger -t safeexec "$*" || true
  fi
}

confirm_or_die() {
  local cmd="$1"
  log_audit "BLOCKED: git $cmd"

  if [[ ! -e /dev/tty ]]; then
    echo "safeexec: BLOCKED (no /dev/tty): git $cmd" >&2
    exit 126
  fi

  local reply=""
  printf '\n\033[0;33m[SAFEEXEC] DESTRUCTIVE COMMAND INTERCEPTED:\033[0m\n  git %s\n' "$cmd" > /dev/tty
  printf 'Type "confirm" to execute: ' > /dev/tty
  IFS= read -r reply < /dev/tty || true
  printf '\n' > /dev/tty

  if [[ "$reply" != "confirm" ]]; then
    echo "safeexec: cancelled" >&2
    exit 130
  fi

  log_audit "CONFIRMED: git $cmd"
}

# Prefer Homebrew backup if present (mac shim)
REAL_GIT=""
for cand in \
  /opt/homebrew/bin/git.safeexec.real \
  /opt/homebrew/bin/git \
  /usr/local/bin/git.safeexec.real \
  /usr/local/bin/git \
  /usr/bin/git \
  /bin/git \
; do
  if [[ -x "$cand" ]] && ! [[ "$cand" -ef "$0" ]]; then
    REAL_GIT="$cand"
    break
  fi
done
if [[ -z "$REAL_GIT" ]]; then
  REAL_GIT="$(command -p -v git 2>/dev/null || echo '/usr/bin/git')"
fi

# Disabled => passthrough
if is_disabled; then
  exec "$REAL_GIT" "$@"
fi

args=("$@")
subcmd=""
subcmd_idx=-1

# Parse global options to locate subcommand
i=0
while (( i < ${#args[@]} )); do
  a="${args[i]}"
  case "$a" in
    --*=*) ((i+=1)); continue ;;
    -C|-c|--exec-path|--html-path|--man-path|--info-path|--git-dir|--work-tree|--namespace|--super-prefix)
      ((i+=2)); continue ;;
    --) ((i+=1)); break ;;
    -*) ((i+=1)); continue ;;
    *) subcmd="$a"; subcmd_idx=$i; break ;;
  esac
done

should_gate=0

if [[ -n "$subcmd" ]]; then
  case "$subcmd" in
    reset|revert|checkout|restore)
      should_gate=1
      ;;
    clean)
      for arg in "${args[@]}"; do
        if [[ "$arg" == "-f" || "$arg" == "--force" ]]; then should_gate=1; break; fi
      done
      ;;
    switch)
      for arg in "${args[@]}"; do
        if [[ "$arg" == "-f" || "$arg" == "--force" || "$arg" == "--discard-changes" ]]; then should_gate=1; break; fi
      done
      ;;
    stash)
      if (( subcmd_idx + 1 < ${#args[@]} )); then
        stash_op="${args[$((subcmd_idx+1))]}"
        case "$stash_op" in drop|clear|pop) should_gate=1 ;; esac
      fi
      ;;
  esac
fi

if [[ "$should_gate" -eq 1 ]]; then
  cmd_str="$(printf '%q ' "${args[@]}")"
  confirm_or_die "$cmd_str"
fi

exec "$REAL_GIT" "${args[@]}"
EOF

  chmod 0755 "$dst"
}

# -----------------------------
# Shims
# -----------------------------

install_localbin_shims() {
  ensure_dir_0755 "$LOCALBIN"
  for c in rm git; do
    local target="$LOCALBIN/$c"
    local src="$SAFEEXEC_DIR/$c"

    if symlink_points_to "$target" "$src"; then
      continue
    fi

    if [[ -e "$target" ]] && [[ ! -L "$target" ]]; then
      echo "safeexec: WARNING: $target exists; not overwriting."
      continue
    fi

    if [[ -L "$target" ]] && ! symlink_points_to "$target" "$src"; then
      echo "safeexec: WARNING: $target is a symlink not managed by safeexec; leaving it alone."
      continue
    fi

    rm -f "$target" 2>/dev/null || true
    ln -s "$src" "$target"
  done
}

remove_localbin_shims() {
  for c in rm git; do
    local target="$LOCALBIN/$c"
    local src="$SAFEEXEC_DIR/$c"
    if symlink_points_to "$target" "$src"; then
      rm -f "$target"
    fi
  done
}

# Homebrew git shim: works even if /opt/homebrew/bin/git is a symlink
install_homebrew_git_shim() {
  is_darwin || return 0
  [[ -e "$HOMEBREW_GIT" ]] || return 0

  ensure_dir_0755 "$HOMEBREW_BIN"

  if [[ -e "$HOMEBREW_GIT_REAL" ]]; then
    return 0
  fi

  # Move current git (file OR symlink) to git.safeexec.real
  if ! mv "$HOMEBREW_GIT" "$HOMEBREW_GIT_REAL"; then
    echo "safeexec: WARNING: failed to move $HOMEBREW_GIT; Homebrew git shim NOT installed."
    return 0
  fi

  cat >"$HOMEBREW_GIT" <<EOF
#!/usr/bin/env bash
# SAFEEXEC HOMEBREW GIT SHIM
exec "$SAFEEXEC_DIR/git" "\$@"
EOF
  chmod 0755 "$HOMEBREW_GIT"

  echo "safeexec: installed Homebrew git shim at $HOMEBREW_GIT (backup: $HOMEBREW_GIT_REAL)"
}

remove_homebrew_git_shim() {
  is_darwin || return 0
  [[ -e "$HOMEBREW_GIT_REAL" ]] || return 0

  # Only restore if current file is our shim
  if file_contains_marker "$HOMEBREW_GIT" "SAFEEXEC HOMEBREW GIT SHIM"; then
    rm -f "$HOMEBREW_GIT"
    mv "$HOMEBREW_GIT_REAL" "$HOMEBREW_GIT"
    echo "safeexec: restored Homebrew git ($HOMEBREW_GIT)"
  else
    echo "safeexec: WARNING: $HOMEBREW_GIT_REAL exists but $HOMEBREW_GIT is not safeexec shim; not restoring."
  fi
}

# -----------------------------
# safeexec CLI (toggle)
# -----------------------------

install_safeexec_cli() {
  ensure_dir_0755 "$LOCALBIN"
  local dst="$LOCALBIN/safeexec"

  cat >"$dst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/safeexec"
STATE_FILE="$STATE_DIR/disabled"

lc() { tr '[:upper:]' '[:lower:]'; }

cmd="${1:-status}"
cmd="$(printf '%s' "$cmd" | lc)"

case "$cmd" in
  -on|on|enable|-enable)
    rm -f "$STATE_FILE" 2>/dev/null || true
    echo "safeexec: ON"
    ;;
  -off|off|disable|-disable)
    mkdir -p "$STATE_DIR"
    : >"$STATE_FILE"
    echo "safeexec: OFF"
    ;;
  status|st|-status|-st)
    if [[ -f "$STATE_FILE" ]]; then
      echo "safeexec: OFF"
    else
      echo "safeexec: ON"
    fi
    ;;
  *)
    echo "Usage: safeexec -on|-off|status" >&2
    exit 2
    ;;
esac
EOF

  chmod 0755 "$dst"
}

remove_safeexec_cli() {
  rm -f "$LOCALBIN/safeexec" || true
}

# -----------------------------
# sudo secure_path (best-effort)
# -----------------------------

install_sudo_secure_path() {
  if [[ -d /etc/sudoers.d ]]; then
    local tmp_sudo
    tmp_sudo="$(mktemp)"
    cat >"$tmp_sudo" <<EOF
Defaults secure_path="$SAFEEXEC_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
    if command -v visudo >/dev/null 2>&1; then
      if visudo -cf "$tmp_sudo"; then
        mv "$tmp_sudo" "$SUDOERS_FILE"
        chmod 440 "$SUDOERS_FILE"
        echo "safeexec: sudo secure_path updated successfully."
      else
        echo "safeexec: WARNING: sudoers validation failed; sudo protection NOT installed."
        rm -f "$tmp_sudo"
      fi
    else
      echo "safeexec: WARNING: visudo missing; sudo protection NOT installed."
      rm -f "$tmp_sudo"
    fi
  fi
}

remove_sudo_secure_path() {
  rm -f "$SUDOERS_FILE" || true
}

# -----------------------------
# Commands
# -----------------------------

cmd_install() {
  need_root
  write_wrapper_rm
  write_wrapper_git
  install_localbin_shims
  install_safeexec_cli
  install_sudo_secure_path
  install_homebrew_git_shim

  echo "safeexec: installed wrappers in $SAFEEXEC_DIR"
  echo "safeexec: shims in $LOCALBIN (rm/git)"
  if is_darwin && [[ -e "$HOMEBREW_GIT_REAL" ]]; then
    echo "safeexec: Homebrew git shim active at $HOMEBREW_GIT"
  fi
  echo "safeexec: toggle with: safeexec -on | safeexec -off"
  echo "safeexec: for current shell: hash -r"
}

cmd_uninstall() {
  need_root
  remove_homebrew_git_shim
  remove_localbin_shims
  remove_safeexec_cli
  remove_sudo_secure_path
  rm -f "$SAFEEXEC_DIR/rm" "$SAFEEXEC_DIR/git" || true
  rmdir "$SAFEEXEC_DIR" 2>/dev/null || true
  rmdir "/usr/local/safeexec" 2>/dev/null || true
  echo "safeexec: uninstalled"
}

cmd_status() {
  local rm_path git_path
  rm_path="$(command -v rm 2>/dev/null || true)"
  git_path="$(command -v git 2>/dev/null || true)"

  echo "SAFEEXEC_DIR=$SAFEEXEC_DIR"
  [[ -x "$SAFEEXEC_DIR/rm" ]] && echo "rm wrapper:       [OK]" || echo "rm wrapper:       [MISSING]"
  [[ -x "$SAFEEXEC_DIR/git" ]] && echo "git wrapper:      [OK]" || echo "git wrapper:      [MISSING]"
  [[ -f "$SUDOERS_FILE" ]] && echo "sudoers:          [OK]" || echo "sudoers:          [MISSING]"

  for c in rm git; do
    local t="$LOCALBIN/$c"
    if symlink_points_to "$t" "$SAFEEXEC_DIR/$c"; then
      echo "$LOCALBIN/$c shim: [OK]"
    else
      echo "$LOCALBIN/$c shim: [NO]"
    fi
  done

  echo -n "PATH includes SAFEEXEC_DIR: "
  if [[ ":${PATH:-}:" == *":$SAFEEXEC_DIR:"* ]]; then
    echo "[YES]"
  else
    echo "[NO] (OK if shims win)"
  fi

  echo "which rm:  ${rm_path:-n/a}"
  echo "which git: ${git_path:-n/a}"

  echo -n "effective gate rm:  "
  if [[ "$rm_path" == "$SAFEEXEC_DIR/rm" || "$rm_path" == "$LOCALBIN/rm" ]]; then echo "[YES]"; else echo "[NO]"; fi

  echo -n "effective gate git: "
  if [[ "$git_path" == "$SAFEEXEC_DIR/git" || "$git_path" == "$LOCALBIN/git" ]]; then
    echo "[YES]"
  elif is_darwin && [[ "$git_path" == "$HOMEBREW_GIT" ]] && file_contains_marker "$HOMEBREW_GIT" "SAFEEXEC HOMEBREW GIT SHIM"; then
    echo "[YES] (homebrew shim)"
  else
    echo "[NO]"
  fi

  if command -v safeexec >/dev/null 2>&1; then
    safeexec status || true
  fi
}

cmd_onoff() {
  # per-user toggle, no sudo
  local sub="${1:-status}"
  if command -v safeexec >/dev/null 2>&1; then
    safeexec "$sub"
  else
    die "safeexec CLI not installed. Run: sudo ./safeexec.sh install"
  fi
}

main() {
  local c="${1:-install}"
  case "$c" in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    on|off|toggle|st|-on|-off|-status|status) cmd_onoff "$c" ;;
    *) usage ;;
  esac
}

main "$@"
