#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SAFEEXEC: Destructive Command Interceptor (+ on/off toggle)
# - Gates: rm -rf, git reset/revert/checkout/restore (+ clean -f, switch -f, stash drop/clear/pop)
# - Cross-platform: Linux VPS + macOS
# - Adds: `safeexec -on|-off|status` (per-user toggle)
# =============================================================================

SAFEEXEC_DIR="/usr/local/safeexec/bin"
LOCALBIN="/usr/local/bin"

PROFILED="/etc/profile.d/safeexec.sh"
SUDOERS_FILE="/etc/sudoers.d/safeexec"

ZPROFILE="/etc/zprofile"
ZSHRC="/etc/zshrc"
ETC_PROFILE="/etc/profile"

MARK_BEGIN="# SAFEEXEC BEGIN"
MARK_END="# SAFEEXEC END"

die() { echo "safeexec: $*" >&2; exit 1; }
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (sudo)"; }

usage() {
  cat >&2 <<'EOF'
Usage:
  safeexec.sh install
  safeexec.sh uninstall
  safeexec.sh status
  safeexec.sh on|off        # per-user toggle (no sudo required)
EOF
  exit 2
}

is_darwin() { [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; }

pick_system_bashrc() {
  if [[ -f /etc/bash.bashrc ]]; then echo /etc/bash.bashrc
  elif [[ -f /etc/bashrc ]]; then echo /etc/bashrc
  else echo ""; fi
}

ensure_dir() {
  local d="$1"
  [[ -d "$d" ]] || mkdir -p "$d"
}

symlink_points_to() {
  local link="$1" target="$2"
  [[ -L "$link" ]] || return 1
  local got=""
  got="$(readlink "$link" 2>/dev/null || true)"
  [[ "$got" == "$target" ]]
}

ensure_block_in_file() {
  local file="$1" begin="$2" end="$3"
  local block; block="$(cat)"

  ensure_dir "$(dirname "$file")"
  [[ -e "$file" ]] || : >"$file"

  if ! [[ -w "$file" ]]; then
    echo "safeexec: WARNING: cannot modify $file; skipping."
    return 0
  fi

  if grep -Fq "$begin" "$file" 2>/dev/null; then
    return 0
  fi

  {
    echo ""
    echo "$begin"
    echo "$block"
    echo "$end"
    echo ""
  } >>"$file"
}

remove_block_from_file() {
  local file="$1" begin="$2" end="$3"
  [[ -f "$file" && -w "$file" ]] || return 0
  grep -Fq "$begin" "$file" 2>/dev/null || return 0
  awk -v b="$begin" -v e="$end" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    !skip {print}
  ' "$file" > "${file}.safeexec.tmp" && mv "${file}.safeexec.tmp" "$file"
}

target_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER:-}" != "root" ]]; then
    echo "$SUDO_USER"
  else
    id -un 2>/dev/null || echo "root"
  fi
}

user_home() {
  local u="$1"
  local h=""
  h="$(eval "echo ~$u" 2>/dev/null || true)"
  [[ -n "$h" && -d "$h" ]] || h=""
  echo "$h"
}

# =============================================================================
# WRAPPERS
# =============================================================================

write_wrapper_rm() {
  ensure_dir "$SAFEEXEC_DIR"
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

# Fast path: disabled => no prompts
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
  ensure_dir "$SAFEEXEC_DIR"
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

# Fast path: disabled => no prompts
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
# SHIMS + macOS Homebrew git shim (for /opt/homebrew/bin precedence)
# =============================================================================

install_localbin_shims() {
  ensure_dir "$LOCALBIN"
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

install_homebrew_git_shim() {
  is_darwin || return 0

  local brew_git="/opt/homebrew/bin/git"
  local brew_real="/opt/homebrew/bin/git.safeexec.real"

  [[ -x "$brew_git" ]] || return 0

  # Already shimmed
  [[ -e "$brew_real" ]] && return 0

  # Refuse if git is a symlink (brew sometimes uses real file; but be safe)
  if [[ -L "$brew_git" ]]; then
    echo "safeexec: WARNING: $brew_git is a symlink; not installing Homebrew shim."
    return 0
  fi

  mv "$brew_git" "$brew_real"

  cat >"$brew_git" <<EOF
#!/usr/bin/env bash
# SAFEEXEC HOMEBREW GIT SHIM
exec "$SAFEEXEC_DIR/git" "\$@"
EOF
  chmod 0755 "$brew_git"

  echo "safeexec: installed Homebrew git shim at $brew_git (backup: $brew_real)"
}

remove_homebrew_git_shim() {
  is_darwin || return 0

  local brew_git="/opt/homebrew/bin/git"
  local brew_real="/opt/homebrew/bin/git.safeexec.real"

  [[ -e "$brew_real" ]] || return 0

  # Remove shim only if it looks like ours
  if [[ -f "$brew_git" ]] && grep -q "SAFEEXEC HOMEBREW GIT SHIM" "$brew_git" 2>/dev/null; then
    rm -f "$brew_git"
    mv "$brew_real" "$brew_git"
    echo "safeexec: restored Homebrew git ($brew_git)"
  else
    echo "safeexec: WARNING: $brew_real exists but $brew_git does not look like safeexec shim; not restoring."
  fi
}

# =============================================================================
# safeexec CLI: safeexec -on|-off|status
# =============================================================================

install_safeexec_cli() {
  ensure_dir "$LOCALBIN"
  local dst="$LOCALBIN/safeexec"
  cat >"$dst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/safeexec"
STATE_FILE="$STATE_DIR/disabled"

cmd="${1:-status}"

case "$cmd" in
  -on|on|enable)
    rm -f "$STATE_FILE" 2>/dev/null || true
    echo "safeexec: ON"
    ;;
  -off|off|disable)
    mkdir -p "$STATE_DIR"
    : >"$STATE_FILE"
    echo "safeexec: OFF"
    ;;
  status|st)
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

# =============================================================================
# HOOKS (best-effort)
# =============================================================================

install_hooks() {
  local path_block
  path_block="$(cat <<EOF
SAFEEXEC_DIR="$SAFEEXEC_DIR"
if [ -d "\$SAFEEXEC_DIR" ]; then
  case ":\$PATH:" in
    *":\$SAFEEXEC_DIR:"*) ;;
    *) PATH="\$SAFEEXEC_DIR:\$PATH" ;;
  esac
fi
export PATH
EOF
)"

  # system files (best-effort)
  ensure_dir "$(dirname "$PROFILED")" || true
  if [[ -d "$(dirname "$PROFILED")" ]] && [[ -w "$(dirname "$PROFILED")" ]]; then
    cat >"$PROFILED" <<EOF
# safeexec PATH hook (profile.d)
$path_block
EOF
    chmod 0644 "$PROFILED" 2>/dev/null || true
  fi

  printf '%s\n' "$path_block" | ensure_block_in_file "$ZPROFILE" "$MARK_BEGIN" "$MARK_END"
  printf '%s\n' "$path_block" | ensure_block_in_file "$ZSHRC"    "$MARK_BEGIN" "$MARK_END"
  printf '%s\n' "$path_block" | ensure_block_in_file "$ETC_PROFILE" "$MARK_BEGIN" "$MARK_END"

  local bashrc
  bashrc="$(pick_system_bashrc)"
  if [[ -n "$bashrc" ]]; then
    printf '%s\n' "$path_block" | ensure_block_in_file "$bashrc" "$MARK_BEGIN" "$MARK_END"
  fi

  # user files (critical on macOS because brew often rewrites PATH)
  local u h
  u="$(target_user)"
  h="$(user_home "$u")"
  if [[ -n "$h" ]]; then
    for f in "$h/.zshrc" "$h/.zprofile" "$h/.bashrc" "$h/.bash_profile" "$h/.profile"; do
      remove_block_from_file "$f" "$MARK_BEGIN" "$MARK_END" || true
      printf '%s\n' "$path_block" | ensure_block_in_file "$f" "$MARK_BEGIN" "$MARK_END"
      chown "$u" "$f" 2>/dev/null || true
    done
  fi

  # sudo secure_path
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

remove_hooks() {
  rm -f "$PROFILED" || true
  rm -f "$SUDOERS_FILE" || true

  remove_block_from_file "$ZPROFILE" "$MARK_BEGIN" "$MARK_END"
  remove_block_from_file "$ZSHRC" "$MARK_BEGIN" "$MARK_END"
  remove_block_from_file "$ETC_PROFILE" "$MARK_BEGIN" "$MARK_END"

  local bashrc
  bashrc="$(pick_system_bashrc)"
  if [[ -n "$bashrc" ]]; then
    remove_block_from_file "$bashrc" "$MARK_BEGIN" "$MARK_END"
  fi

  local u h
  u="$(target_user)"
  h="$(user_home "$u")"
  if [[ -n "$h" ]]; then
    for f in "$h/.zshrc" "$h/.zprofile" "$h/.bashrc" "$h/.bash_profile" "$h/.profile"; do
      remove_block_from_file "$f" "$MARK_BEGIN" "$MARK_END"
    done
  fi
}

# =============================================================================
# ON/OFF TOGGLE (per-user; no sudo required)
# =============================================================================

cmd_on() {
  "${LOCALBIN}/safeexec" -on 2>/dev/null || safeexec -on 2>/dev/null || {
    # fallback if CLI not installed yet
    local d="${XDG_CONFIG_HOME:-$HOME/.config}/safeexec"
    mkdir -p "$d"
    rm -f "$d/disabled"
    echo "safeexec: ON"
  }
}

cmd_off() {
  "${LOCALBIN}/safeexec" -off 2>/dev/null || safeexec -off 2>/dev/null || {
    local d="${XDG_CONFIG_HOME:-$HOME/.config}/safeexec"
    mkdir -p "$d"
    : >"$d/disabled"
    echo "safeexec: OFF"
  }
}

# =============================================================================
# MAIN COMMANDS
# =============================================================================

cmd_install() {
  need_root
  write_wrapper_rm
  write_wrapper_git
  install_localbin_shims
  install_safeexec_cli
  install_hooks
  install_homebrew_git_shim

  echo "safeexec: installed wrappers in $SAFEEXEC_DIR"
  echo "safeexec: shims installed (or attempted) in $LOCALBIN"
  echo "safeexec: toggle with: safeexec -on | safeexec -off"
  echo "safeexec: for current shell: hash -r; exec \$SHELL -l"
}

cmd_uninstall() {
  need_root
  remove_homebrew_git_shim
  remove_localbin_shims
  remove_safeexec_cli
  remove_hooks
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
  if [[ ":${PATH:-}:" == *":$SAFEEXEC_DIR:"* ]]; then echo "[YES]"; else echo "[NO]"; fi

  echo "which rm:  ${rm_path:-n/a}"
  echo "which git: ${git_path:-n/a}"

  echo -n "effective gate rm:  "
  if [[ "$rm_path" == "$SAFEEXEC_DIR/rm" || "$rm_path" == "$LOCALBIN/rm" ]]; then echo "[YES]"; else echo "[NO]"; fi

  echo -n "effective gate git: "
  if [[ "$git_path" == "$SAFEEXEC_DIR/git" || "$git_path" == "$LOCALBIN/git" ]]; then
    echo "[YES]"
  elif [[ "$git_path" == "/opt/homebrew/bin/git" ]] && [[ -f "/opt/homebrew/bin/git.safeexec.real" ]] && grep -q "SAFEEXEC HOMEBREW GIT SHIM" /opt/homebrew/bin/git 2>/dev/null; then
    echo "[YES] (homebrew shim)"
  else
    echo "[NO]"
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
    on) cmd_on ;;
    off) cmd_off ;;
    *) usage ;;
  esac
}

main "$@"
