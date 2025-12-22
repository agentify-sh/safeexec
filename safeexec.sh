#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SAFEEXEC: Destructive Command Interceptor (Ubuntu/Debian/WSL + macOS)
#
# Soft mode (macOS + Linux):
#   - Wrappers: /usr/local/safeexec/bin/{rm,git}
#   - Shims:    /usr/local/bin/{rm,git} -> wrappers
#   - macOS (Apple Silicon): optional Homebrew git shim at /opt/homebrew/bin/git
#
# Hard mode (Ubuntu/Debian/WSL):
#   - Uses dpkg-divert to replace /usr/bin/{rm,git} with tiny dispatchers -> wrappers
#   - Catches non-interactive shells, command -p, and absolute paths
#
# WSL/Codex TTY quirks:
#   - /dev/tty may exist but be EACCES/unusable under some harnesses.
#   - Wrappers PROBE-open /dev/tty via FDs; if unusable, fall back to stdin only if stdin is a TTY.
#   - If no usable TTY, gated commands are BLOCKED (exit 126).
#
# macOS Homebrew git quirks:
#   - On Intel Homebrew, /usr/local/bin/git is often a symlink into Cellar.
#   - Installer will now (only for git) detect a Homebrew Cellar symlink and safely
#     back it up to /usr/local/bin/git.safeexec.real, then install our shim.
# =============================================================================

SAFEEXEC_ROOT="/usr/local/safeexec"
SAFEEXEC_DIR="$SAFEEXEC_ROOT/bin"
LOCALBIN="/usr/local/bin"
SUDOERS_FILE="/etc/sudoers.d/safeexec"

HOMEBREW_BIN="/opt/homebrew/bin"
HOMEBREW_GIT="$HOMEBREW_BIN/git"
HOMEBREW_GIT_REAL="$HOMEBREW_BIN/git.safeexec.real"

MARK_HARD="SAFEEXEC HARD WRAPPER"
MARK_BREW="SAFEEXEC HOMEBREW GIT SHIM"

die() { echo "safeexec: $*" >&2; exit 1; }
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (sudo)"; }
is_darwin() { [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; }
is_linux()  { [[ "$(uname -s 2>/dev/null || true)" == "Linux" ]]; }

usage() {
  cat >&2 <<'EOF'
Usage:
  safeexec.sh install
  safeexec.sh uninstall
  safeexec.sh status

Ubuntu/Debian/WSL hard mode:
  safeexec.sh install-hard
  safeexec.sh uninstall-hard
EOF
  exit 2
}

ensure_dir_0755() {
  local d="$1"
  [[ -d "$d" ]] || mkdir -p "$d"
  chmod 0755 "$d" 2>/dev/null || true
}

symlink_points_to() {
  local link="$1" target="$2"
  [[ -L "$link" ]] || return 1
  local got=""
  got="$(readlink "$link" 2>/dev/null || true)"
  [[ "$got" == "$target" ]]
}

file_has_marker() {
  local f="$1" marker="$2"
  [[ -f "$f" ]] || return 1
  grep -q "$marker" "$f" 2>/dev/null
}

# Detect if a symlink is Homebrew's git (Intel: /usr/local, or various cellar paths).
is_homebrew_git_symlink() {
  local link="$1"
  [[ -L "$link" ]] || return 1
  local val resolved
  val="$(readlink "$link" 2>/dev/null || true)"
  resolved="$val"
  if command -v readlink >/dev/null 2>&1; then
    resolved="$(readlink -f "$link" 2>/dev/null || echo "$val")"
  fi

  case " $val $resolved " in
    *"Cellar/git/"*|*"Homebrew/Cellar/git/"*|*"homebrew/Cellar/git/"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

confirm_tty_or_die() {
  local msg="$1"
  if [[ -r /dev/tty && -w /dev/tty ]]; then
    if exec 9</dev/tty 2>/dev/null && exec 10>/dev/tty 2>/dev/null; then
      local in out
      if [[ -e /dev/fd/9 ]]; then in="/dev/fd/9"; out="/dev/fd/10"; else in="/proc/self/fd/9"; out="/proc/self/fd/10"; fi
      printf "\n%s\nType \"confirm\" to proceed: " "$msg" >"$out"
      local reply=""
      if ! IFS= read -r reply <"$in"; then
        exec 9<&- 2>/dev/null || true
        exec 10>&- 2>/dev/null || true
        die "No usable TTY available for confirmation."
      fi
      exec 9<&- 2>/dev/null || true
      exec 10>&- 2>/dev/null || true
      [[ "$reply" == "confirm" ]] || die "Cancelled."
      return 0
    fi
  fi

  if [[ -t 0 ]]; then
    printf "\n%s\nType \"confirm\" to proceed: " "$msg" >&2
    local reply=""
    IFS= read -r reply || true
    [[ "$reply" == "confirm" ]] || die "Cancelled."
    return 0
  fi

  die "No usable TTY available for confirmation."
}

# =============================================================================
# WRAPPERS (in /usr/local/safeexec/bin)
# =============================================================================

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

SAFEEXEC_TTY_FDS_OPENED=0
TTY_IN="/dev/tty"
TTY_OUT="/dev/tty"

pick_tty_pair() {
  SAFEEXEC_TTY_FDS_OPENED=0
  TTY_IN="/dev/tty"
  TTY_OUT="/dev/tty"

  if exec 9</dev/tty 2>/dev/null && exec 10>/dev/tty 2>/dev/null; then
    SAFEEXEC_TTY_FDS_OPENED=1
    if [[ -e /dev/fd/9 ]]; then
      TTY_IN="/dev/fd/9"
      TTY_OUT="/dev/fd/10"
    else
      TTY_IN="/proc/self/fd/9"
      TTY_OUT="/proc/self/fd/10"
    fi
    return 0
  fi

  if [[ -t 0 ]]; then
    TTY_IN="/dev/fd/0"
    if [[ -t 2 ]]; then
      TTY_OUT="/dev/fd/2"
    elif [[ -t 1 ]]; then
      TTY_OUT="/dev/fd/1"
    else
      TTY_OUT="/dev/fd/2"
    fi
    return 0
  fi

  return 1
}

close_tty_pair() {
  if [[ "$SAFEEXEC_TTY_FDS_OPENED" -eq 1 ]]; then
    exec 9<&- 2>/dev/null || true
    exec 10>&- 2>/dev/null || true
    SAFEEXEC_TTY_FDS_OPENED=0
  fi
}

confirm_or_die() {
  local cmd="$1"
  log_audit "BLOCKED: rm $cmd"

  if ! pick_tty_pair; then
    echo "safeexec: BLOCKED (no usable TTY; cannot prompt): rm $cmd" >&2
    exit 126
  fi

  local reply=""
  printf '\n\033[0;31m[SAFEEXEC] DESTRUCTIVE COMMAND INTERCEPTED:\033[0m\n  rm %s\n' "$cmd" >"$TTY_OUT"
  printf 'Type "confirm" to execute: ' >"$TTY_OUT"

  if ! IFS= read -r reply <"$TTY_IN"; then
    close_tty_pair
    echo "safeexec: BLOCKED (cannot read TTY; cannot prompt): rm $cmd" >&2
    exit 126
  fi
  printf '\n' >"$TTY_OUT"
  close_tty_pair

  if [[ "$reply" != "confirm" ]]; then
    echo "safeexec: cancelled" >&2
    exit 130
  fi

  log_audit "CONFIRMED: rm $cmd"
}

REAL_RM=""
for cand in /usr/bin/rm.safeexec.real /bin/rm.safeexec.real /usr/bin/rm /bin/rm; do
  if [[ -x "$cand" ]] && ! [[ "$cand" -ef "$0" ]]; then
    REAL_RM="$cand"
    break
  fi
done
if [[ -z "$REAL_RM" ]]; then
  REAL_RM="$(command -p -v rm 2>/dev/null || echo '/bin/rm')"
fi

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

SAFEEXEC_TTY_FDS_OPENED=0
TTY_IN="/dev/tty"
TTY_OUT="/dev/tty"

pick_tty_pair() {
  SAFEEXEC_TTY_FDS_OPENED=0
  TTY_IN="/dev/tty"
  TTY_OUT="/dev/tty"

  if exec 9</dev/tty 2>/dev/null && exec 10>/dev/tty 2>/dev/null; then
    SAFEEXEC_TTY_FDS_OPENED=1
    if [[ -e /dev/fd/9 ]]; then
      TTY_IN="/dev/fd/9"
      TTY_OUT="/dev/fd/10"
    else
      TTY_IN="/proc/self/fd/9"
      TTY_OUT="/proc/self/fd/10"
    fi
    return 0
  fi

  if [[ -t 0 ]]; then
    TTY_IN="/dev/fd/0"
    if [[ -t 2 ]]; then
      TTY_OUT="/dev/fd/2"
    elif [[ -t 1 ]]; then
      TTY_OUT="/dev/fd/1"
    else
      TTY_OUT="/dev/fd/2"
    fi
    return 0
  fi

  return 1
}

close_tty_pair() {
  if [[ "$SAFEEXEC_TTY_FDS_OPENED" -eq 1 ]]; then
    exec 9<&- 2>/dev/null || true
    exec 10>&- 2>/dev/null || true
    SAFEEXEC_TTY_FDS_OPENED=0
  fi
}

confirm_or_die() {
  local cmd="$1"
  log_audit "BLOCKED: git $cmd"

  if ! pick_tty_pair; then
    echo "safeexec: BLOCKED (no usable TTY; cannot prompt): git $cmd" >&2
    exit 126
  fi

  local reply=""
  printf '\n\033[0;33m[SAFEEXEC] DESTRUCTIVE COMMAND INTERCEPTED:\033[0m\n  git %s\n' "$cmd" >"$TTY_OUT"
  printf 'Type "confirm" to execute: ' >"$TTY_OUT"

  if ! IFS= read -r reply <"$TTY_IN"; then
    close_tty_pair
    echo "safeexec: BLOCKED (cannot read TTY; cannot prompt): git $cmd" >&2
    exit 126
  fi
  printf '\n' >"$TTY_OUT"
  close_tty_pair

  if [[ "$reply" != "confirm" ]]; then
    echo "safeexec: cancelled" >&2
    exit 130
  fi

  log_audit "CONFIRMED: git $cmd"
}

REAL_GIT=""
for cand in \
  /usr/bin/git.safeexec.real \
  /bin/git.safeexec.real \
  /opt/homebrew/bin/git.safeexec.real \
  /usr/local/bin/git.safeexec.real \
  /opt/homebrew/bin/git \
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

if is_disabled; then
  exec "$REAL_GIT" "$@"
fi

args=("$@")
subcmd=""
subcmd_idx=-1

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

# =============================================================================
# SHIMS (soft mode)
# =============================================================================

install_localbin_shims() {
  ensure_dir_0755 "$LOCALBIN"
  for c in rm git; do
    local target="$LOCALBIN/$c"
    local src="$SAFEEXEC_DIR/$c"
    local backup="${target}.safeexec.real"

    if symlink_points_to "$target" "$src"; then
      continue
    fi

    if [[ -e "$target" && ! -L "$target" ]]; then
      echo "safeexec: WARNING: $target exists; not overwriting."
      continue
    fi

    if [[ -L "$target" ]] && ! symlink_points_to "$target" "$src"; then
      # Special-case: macOS Intel Homebrew often owns /usr/local/bin/git as a symlink into Cellar.
      if [[ "$c" == "git" ]] && is_darwin && is_homebrew_git_symlink "$target"; then
        if [[ -e "$backup" ]]; then
          echo "safeexec: WARNING: $backup already exists; not modifying $target."
          continue
        fi
        mv "$target" "$backup"
        ln -s "$src" "$target"
        echo "safeexec: backed up Homebrew git symlink ($target -> $backup) and installed safeexec shim."
        continue
      fi

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
    local backup="${target}.safeexec.real"

    if symlink_points_to "$target" "$src"; then
      rm -f "$target"
    fi

    # Restore backup if we created one (e.g. Homebrew /usr/local/bin/git)
    if [[ -e "$backup" ]]; then
      # Only restore if target is missing (or is our shim which we just removed)
      if [[ ! -e "$target" ]]; then
        mv "$backup" "$target"
      else
        # Don't overwrite user's current target
        echo "safeexec: WARNING: not restoring $backup because $target exists."
      fi
    fi
  done
}

# macOS Apple Silicon: ensure /opt/homebrew/bin/git hits safeexec
install_homebrew_git_shim() {
  is_darwin || return 0
  [[ -e "$HOMEBREW_GIT" ]] || return 0
  ensure_dir_0755 "$HOMEBREW_BIN"

  if [[ -e "$HOMEBREW_GIT_REAL" ]]; then
    return 0
  fi

  if ! mv "$HOMEBREW_GIT" "$HOMEBREW_GIT_REAL"; then
    echo "safeexec: WARNING: failed to move $HOMEBREW_GIT; Homebrew git shim NOT installed."
    return 0
  fi

  cat >"$HOMEBREW_GIT" <<EOF
#!/usr/bin/env bash
# $MARK_BREW
exec "$SAFEEXEC_DIR/git" "\$@"
EOF
  chmod 0755 "$HOMEBREW_GIT"

  echo "safeexec: installed Homebrew git shim at $HOMEBREW_GIT (backup: $HOMEBREW_GIT_REAL)"
}

remove_homebrew_git_shim() {
  is_darwin || return 0
  [[ -e "$HOMEBREW_GIT_REAL" ]] || return 0

  if file_has_marker "$HOMEBREW_GIT" "$MARK_BREW"; then
    rm -f "$HOMEBREW_GIT"
    mv "$HOMEBREW_GIT_REAL" "$HOMEBREW_GIT"
    echo "safeexec: restored Homebrew git ($HOMEBREW_GIT)"
  else
    echo "safeexec: WARNING: $HOMEBREW_GIT_REAL exists but $HOMEBREW_GIT is not safeexec shim; not restoring."
  fi
}

# =============================================================================
# safeexec CLI (toggle)
# =============================================================================

install_safeexec_cli() {
  ensure_dir_0755 "$LOCALBIN"
  local dst="$LOCALBIN/safeexec"

  cat >"$dst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR_USER="${XDG_CONFIG_HOME:-$HOME/.config}/safeexec"
STATE_FILE_USER="$STATE_DIR_USER/disabled"
STATE_FILE_GLOBAL="/usr/local/safeexec/disabled"

lc() { tr '[:upper:]' '[:lower:]'; }

cmd="${1:-status}"
cmd="$(printf '%s' "$cmd" | lc)"

global=0
if [[ "${2:-}" == "--global" || "${2:-}" == "-g" ]]; then
  global=1
fi

if [[ "$global" -eq 1 ]]; then
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "safeexec: --global requires sudo" >&2; exit 1; }
  mkdir -p "/usr/local/safeexec"
  case "$cmd" in
    -on|on|enable|-enable)
      rm -f "$STATE_FILE_GLOBAL" 2>/dev/null || true
      echo "safeexec: ON (global)"
      ;;
    -off|off|disable|-disable)
      : >"$STATE_FILE_GLOBAL"
      echo "safeexec: OFF (global)"
      ;;
    status|st|-status|-st)
      if [[ -f "$STATE_FILE_GLOBAL" ]]; then echo "safeexec: OFF (global)"; else echo "safeexec: ON (global)"; fi
      ;;
    *)
      echo "Usage: safeexec -on|-off|status [--global]" >&2
      exit 2
      ;;
  esac
  exit 0
fi

case "$cmd" in
  -on|on|enable|-enable)
    rm -f "$STATE_FILE_USER" 2>/dev/null || true
    echo "safeexec: ON"
    ;;
  -off|off|disable|-disable)
    mkdir -p "$STATE_DIR_USER"
    : >"$STATE_FILE_USER"
    echo "safeexec: OFF"
    ;;
  status|st|-status|-st)
    if [[ -f "$STATE_FILE_USER" ]]; then echo "safeexec: OFF"; else echo "safeexec: ON"; fi
    ;;
  *)
    echo "Usage: safeexec -on|-off|status [--global]" >&2
    exit 2
    ;;
esac
EOF

  chmod 0755 "$dst"
}

remove_safeexec_cli() {
  rm -f "$LOCALBIN/safeexec" || true
}

# =============================================================================
# Sudo secure_path
# =============================================================================

install_sudo_secure_path() {
  [[ -d /etc/sudoers.d ]] || return 0
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
      rm -f "$tmp_sudo"
      echo "safeexec: WARNING: sudoers validation failed; sudo protection NOT installed."
    fi
  else
    rm -f "$tmp_sudo"
    echo "safeexec: WARNING: visudo missing; sudo protection NOT installed."
  fi
}

remove_sudo_secure_path() {
  rm -f "$SUDOERS_FILE" || true
}

# =============================================================================
# Ubuntu/Debian/WSL hard mode (dpkg-divert)
# =============================================================================

dpkg_divert_install_one() {
  local cmd="$1"
  command -v dpkg-divert >/dev/null 2>&1 || die "dpkg-divert not found (hard mode requires Ubuntu/Debian/WSL)."

  local sys_path=""
  sys_path="$(command -p -v "$cmd" 2>/dev/null || true)"
  [[ -n "$sys_path" ]] || die "Cannot locate system $cmd via command -p."

  if command -v readlink >/dev/null 2>&1; then
    sys_path="$(readlink -f "$sys_path" 2>/dev/null || echo "$sys_path")"
  fi

  local divert="${sys_path}.safeexec.real"

  if [[ -e "$divert" ]] && file_has_marker "$sys_path" "$MARK_HARD"; then
    echo "safeexec: hard-mode already active for $cmd at $sys_path"
    return 0
  fi

  dpkg-divert --add --rename --divert "$divert" "$sys_path"

  cat >"$sys_path" <<EOF
#!/usr/bin/env bash
# $MARK_HARD ($cmd)
exec "$SAFEEXEC_DIR/$cmd" "\$@"
EOF
  chmod 0755 "$sys_path"
  chown root:root "$sys_path" 2>/dev/null || true

  echo "safeexec: hard-mode installed for $cmd at $sys_path (real: $divert)"
}

dpkg_divert_remove_one() {
  local cmd="$1"
  command -v dpkg-divert >/dev/null 2>&1 || die "dpkg-divert not found."

  local sys_path=""
  sys_path="$(command -p -v "$cmd" 2>/dev/null || true)"
  [[ -n "$sys_path" ]] || sys_path="/usr/bin/$cmd"

  if command -v readlink >/dev/null 2>&1; then
    sys_path="$(readlink -f "$sys_path" 2>/dev/null || echo "$sys_path")"
  fi

  local divert="${sys_path}.safeexec.real"

  if [[ -f "$sys_path" ]] && file_has_marker "$sys_path" "$MARK_HARD"; then
    rm -f "$sys_path"
  fi

  if [[ -e "$divert" ]]; then
    dpkg-divert --remove --rename --divert "$divert" "$sys_path"
    echo "safeexec: hard-mode removed for $cmd at $sys_path"
  else
    echo "safeexec: hard-mode not found for $cmd (no $divert)"
  fi
}

cmd_install_hard() {
  need_root
  is_linux || die "install-hard is only supported on Ubuntu/Debian/WSL Linux (dpkg-divert). macOS cannot hard-replace /usr/bin."

  confirm_tty_or_die "[SAFEEXEC HARD MODE] This will dpkg-divert /usr/bin/rm and /usr/bin/git so they ALWAYS route through safeexec (non-interactive + command -p + absolute paths)."

  write_wrapper_rm
  write_wrapper_git
  install_safeexec_cli
  install_sudo_secure_path
  install_localbin_shims

  dpkg_divert_install_one rm
  dpkg_divert_install_one git

  echo "safeexec: HARD MODE active."
}

cmd_uninstall_hard() {
  need_root
  is_linux || die "uninstall-hard is only supported on Ubuntu/Debian/WSL Linux."

  dpkg_divert_remove_one git
  dpkg_divert_remove_one rm

  echo "safeexec: HARD MODE removed."
}

hard_mode_status_one() {
  local cmd="$1"
  local p=""
  p="$(command -p -v "$cmd" 2>/dev/null || true)"
  [[ -n "$p" ]] || p="/usr/bin/$cmd"
  if command -v readlink >/dev/null 2>&1; then
    p="$(readlink -f "$p" 2>/dev/null || echo "$p")"
  fi
  local divert="${p}.safeexec.real"
  if [[ -e "$divert" ]] && file_has_marker "$p" "$MARK_HARD"; then
    echo "$cmd hard-mode:    [YES] ($p)"
  else
    echo "$cmd hard-mode:    [NO]"
  fi
}

# =============================================================================
# Commands
# =============================================================================

cmd_install() {
  need_root
  write_wrapper_rm
  write_wrapper_git
  install_safeexec_cli
  install_sudo_secure_path
  install_localbin_shims
  install_homebrew_git_shim

  echo "safeexec: installed wrappers in $SAFEEXEC_DIR"
  echo "safeexec: shims in $LOCALBIN (rm/git)"
  if is_darwin && [[ -e "$HOMEBREW_GIT_REAL" ]]; then
    echo "safeexec: Homebrew git shim active at $HOMEBREW_GIT"
  fi
  echo "safeexec: toggle with: safeexec -on | safeexec -off"
  echo "safeexec: for current shell: hash -r"
  if is_linux; then
    echo "safeexec: for Codex/agents on Ubuntu/WSL, enable hard mode: sudo ./safeexec.sh install-hard"
  fi
}

cmd_uninstall() {
  need_root
  remove_homebrew_git_shim
  remove_localbin_shims
  remove_safeexec_cli
  remove_sudo_secure_path

  rm -f "$SAFEEXEC_DIR/rm" "$SAFEEXEC_DIR/git" || true
  rmdir "$SAFEEXEC_DIR" 2>/dev/null || true
  rmdir "$SAFEEXEC_ROOT" 2>/dev/null || true

  echo "safeexec: uninstalled (soft mode)."
  echo "safeexec: if you enabled hard mode, also run: sudo ./safeexec.sh uninstall-hard"
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
  if [[ "$rm_path" == "$SAFEEXEC_DIR/rm" || "$rm_path" == "$LOCALBIN/rm" ]]; then
    echo "[YES]"
  else
    echo "[NO]"
  fi

  echo -n "effective gate git: "
  if [[ "$git_path" == "$SAFEEXEC_DIR/git" || "$git_path" == "$LOCALBIN/git" ]]; then
    echo "[YES]"
  elif is_darwin && [[ "$git_path" == "$HOMEBREW_GIT" ]] && file_has_marker "$HOMEBREW_GIT" "$MARK_BREW"; then
    echo "[YES] (homebrew shim)"
  else
    echo "[NO]"
  fi

  if is_linux; then
    hard_mode_status_one rm
    hard_mode_status_one git
  fi

  if command -v safeexec >/dev/null 2>&1; then
    safeexec status || true
  fi
}

main() {
  local c="${1:-install}"
  case "$c" in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    install-hard) cmd_install_hard ;;
    uninstall-hard) cmd_uninstall_hard ;;
    *) usage ;;
  esac
}

main "$@"
