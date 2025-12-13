#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SAFEEXEC: Destructive Command Interceptor
# Prevents accidental execution of rm/git commands by requiring user confirmation.
# =============================================================================

SAFEEXEC_DIR="/usr/local/safeexec/bin"
LOCALBIN="/usr/local/bin"
PROFILED="/etc/profile.d/safeexec.sh"
SUDOERS_FILE="/etc/sudoers.d/safeexec"
MARK_BEGIN="# SAFEEXEC BEGIN"
MARK_END="# SAFEEXEC END"

die() { echo "safeexec: $*" >&2; exit 1; }
need_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root"; }

usage() {
  cat >&2 <<'EOF'
Usage:
  safeexec.sh install    # Installs wrappers and hooks
  safeexec.sh uninstall  # Removes all traces
  safeexec.sh status     # Checks installation health
EOF
  exit 2
}

pick_system_bashrc() {
  if [[ -f /etc/bash.bashrc ]]; then echo /etc/bash.bashrc
  elif [[ -f /etc/bashrc ]]; then echo /etc/bashrc
  else echo ""; fi
}

# --- WRAPPER: RM ---
write_wrapper_rm() {
  install -d -m 0755 "$SAFEEXEC_DIR"
  local dst="$SAFEEXEC_DIR/rm"
  cat >"$dst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

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

REAL_RM="$(command -p -v rm 2>/dev/null || echo '/bin/rm')"

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

# --- WRAPPER: GIT ---
write_wrapper_git() {
  install -d -m 0755 "$SAFEEXEC_DIR"
  local dst="$SAFEEXEC_DIR/git"
  cat >"$dst" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

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

REAL_GIT="$(command -p -v git 2>/dev/null || echo '/usr/bin/git')"

args=("$@")
subcmd=""
subcmd_idx=-1

i=0
while (( i < ${#args[@]} )); do
  a="${args[i]}"
  case "$a" in
    --*=*)
      ((i+=1)); continue ;;
    -C|-c|--exec-path|--html-path|--man-path|--info-path|--git-dir|--work-tree|--namespace|--super-prefix)
      ((i+=2)); continue ;;
    --)
      ((i+=1)); break ;;
    -*)
      ((i+=1)); continue ;;
    *)
      subcmd="$a"
      subcmd_idx=$i
      break ;;
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

# --- SHIMS INTO /usr/local/bin (Improves coverage) ---
install_localbin_shims() {
  install -d -m 0755 "$LOCALBIN"

  for c in rm git; do
    local target="$LOCALBIN/$c"
    local src="$SAFEEXEC_DIR/$c"

    if [[ -L "$target" ]]; then
      local resolved
      resolved="$(readlink -f "$target" 2>/dev/null || true)"
      if [[ "$resolved" == "$src" ]]; then
        continue
      fi
      echo "safeexec: WARNING: $target is a symlink not managed by safeexec; leaving it alone."
      continue
    fi

    if [[ -e "$target" ]]; then
      echo "safeexec: WARNING: $target exists; not overwriting. (coverage may be reduced)"
      continue
    fi

    ln -s "$src" "$target"
  done
}

remove_localbin_shims() {
  for c in rm git; do
    local target="$LOCALBIN/$c"
    local src="$SAFEEXEC_DIR/$c"
    if [[ -L "$target" ]]; then
      local resolved
      resolved="$(readlink -f "$target" 2>/dev/null || true)"
      if [[ "$resolved" == "$src" ]]; then
        rm -f "$target"
      fi
    fi
  done
}

# --- SYSTEM HOOKS ---
install_hooks() {
  # 1) /etc/profile.d
  cat >"$PROFILED" <<EOF
# safeexec PATH hook
SAFEEXEC_DIR="$SAFEEXEC_DIR"
if [ -d "\$SAFEEXEC_DIR" ]; then
  case ":\$PATH:" in
    *":\$SAFEEXEC_DIR:"*) ;;
    *) PATH="\$SAFEEXEC_DIR:\$PATH" ;;
  esac
fi
export PATH
EOF
  chmod 0644 "$PROFILED"

  # 2) sudo secure_path
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
      # Fallback: manual confirm for minimal systems
      if [[ -e /dev/tty ]]; then
        local reply=""
        printf '\n[SAFEEXEC] visudo not found. Installing sudoers without validation is risky.\nType "confirm" to proceed: ' > /dev/tty
        IFS= read -r reply < /dev/tty || true
        printf '\n' > /dev/tty
        if [[ "$reply" == "confirm" ]]; then
          mv "$tmp_sudo" "$SUDOERS_FILE"
          chmod 440 "$SUDOERS_FILE"
          echo "safeexec: sudo secure_path installed (unvalidated)."
        else
          echo "safeexec: sudo protection NOT installed."
          rm -f "$tmp_sudo"
        fi
      else
        echo "safeexec: WARNING: visudo missing and no tty; sudo protection NOT installed."
        rm -f "$tmp_sudo"
      fi
    fi
  else
    echo "safeexec: WARNING: /etc/sudoers.d not found. 'sudo rm' might bypass the wrapper."
  fi

  # 3) bashrc (interactive non-login)
  local bashrc
  bashrc="$(pick_system_bashrc)"
  if [[ -n "$bashrc" && -f "$bashrc" && -w "$bashrc" ]]; then
    if ! grep -Fq "$MARK_BEGIN" "$bashrc" 2>/dev/null; then
      cat >>"$bashrc" <<EOF

$MARK_BEGIN
SAFEEXEC_DIR="$SAFEEXEC_DIR"
if [ -d "\$SAFEEXEC_DIR" ]; then
  case ":\$PATH:" in
    *":\$SAFEEXEC_DIR:"*) ;;
    *) PATH="\$SAFEEXEC_DIR:\$PATH" ;;
  esac
fi
export PATH
$MARK_END
EOF
    fi
  fi
}

remove_hooks() {
  rm -f "$PROFILED" || true
  rm -f "$SUDOERS_FILE" || true

  local bashrc
  bashrc="$(pick_system_bashrc)"
  if [[ -n "$bashrc" && -f "$bashrc" && -w "$bashrc" ]]; then
    if grep -Fq "$MARK_BEGIN" "$bashrc" 2>/dev/null; then
      awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0==b {skip=1; next}
        $0==e {skip=0; next}
        !skip {print}
      ' "$bashrc" > "${bashrc}.safeexec.tmp" && mv "${bashrc}.safeexec.tmp" "$bashrc"
    fi
  fi
}

# --- MAIN ---
cmd_install() {
  need_root
  write_wrapper_rm
  write_wrapper_git
  install_localbin_shims
  install_hooks
  echo "safeexec: installed wrappers in $SAFEEXEC_DIR"
  echo "safeexec: shims attempted in $LOCALBIN"
  echo 'safeexec: start a new shell to test.'
}

cmd_uninstall() {
  need_root
  remove_localbin_shims
  remove_hooks
  rm -f "$SAFEEXEC_DIR/rm" "$SAFEEXEC_DIR/git" || true
  rmdir "$SAFEEXEC_DIR" 2>/dev/null || true
  rmdir "/usr/local/safeexec" 2>/dev/null || true
  echo "safeexec: uninstalled"
}

cmd_status() {
  echo "SAFEEXEC_DIR=$SAFEEXEC_DIR"
  [[ -x "$SAFEEXEC_DIR/rm" ]] && echo "rm wrapper:       [OK]" || echo "rm wrapper:       [MISSING]"
  [[ -x "$SAFEEXEC_DIR/git" ]] && echo "git wrapper:      [OK]" || echo "git wrapper:      [MISSING]"
  [[ -f "$SUDOERS_FILE" ]] && echo "sudoers:          [OK]" || echo "sudoers:          [MISSING]"

  for c in rm git; do
    t="$LOCALBIN/$c"
    if [[ -L "$t" ]] && [[ "$(readlink -f "$t" 2>/dev/null || true)" == "$SAFEEXEC_DIR/$c" ]]; then
      echo "$LOCALBIN/$c shim: [OK]"
    else
      echo "$LOCALBIN/$c shim: [NO]"
    fi
  done

  echo -n "PATH includes SAFEEXEC_DIR: "
  if [[ ":$PATH:" == *":$SAFEEXEC_DIR:"* ]]; then
    echo "[YES]"
  else
    echo "[NO]"
  fi
}

main() {
  local c="${1:-install}"
  case "$c" in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    *) usage ;;
  esac
}

main "$@"
