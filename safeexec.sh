#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# SAFEEXEC: Destructive Command Interceptor
# Gates: rm -rf, and git reset/revert/checkout/restore (+ some extras)
# Cross-platform hooks: Linux (/etc/profile.d, bashrc), macOS (zprofile/zshrc/profile)
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
EOF
  exit 2
}

pick_system_bashrc() {
  if [[ -f /etc/bash.bashrc ]]; then echo /etc/bash.bashrc
  elif [[ -f /etc/bashrc ]]; then echo /etc/bashrc
  else echo ""; fi
}

ensure_dir() {
  local d="$1"
  [[ -d "$d" ]] || install -d -m 0755 "$d"
}

ensure_block_in_file() {
  local file="$1" begin="$2" end="$3"
  local block; block="$(cat)"

  ensure_dir "$(dirname "$file")"
  [[ -e "$file" ]] || touch "$file"

  if ! [[ -w "$file" ]]; then
    echo "safeexec: WARNING: cannot modify $file (not writable); skipping."
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

symlink_points_to() {
  local link="$1" target="$2"
  [[ -L "$link" ]] || return 1
  local got=""
  got="$(readlink "$link" 2>/dev/null || true)"
  [[ "$got" == "$target" ]]
}

# --- WRAPPER: RM ---
write_wrapper_rm() {
  ensure_dir "$SAFEEXEC_DIR"
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
  printf 'STOP! Get permission from a human! type "confirm" to execute: ' > /dev/tty
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

# Gate only rm -rf
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
  ensure_dir "$SAFEEXEC_DIR"
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

# Parse global options to find subcommand
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

# --- /usr/local/bin shims (improves coverage on macOS + many Linux setups) ---
install_localbin_shims() {
  ensure_dir "$LOCALBIN"

  for c in rm git; do
    local target="$LOCALBIN/$c"
    local src="$SAFEEXEC_DIR/$c"

    if symlink_points_to "$target" "$src"; then
      continue
    fi

    if [[ -e "$target" && ! -L "$target" ]]; then
      echo "safeexec: WARNING: $target exists; not overwriting. (coverage may be reduced)"
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

# --- SYSTEM HOOKS ---
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

  # 1) /etc/profile.d (Linux-style)
  local profiled_dir
  profiled_dir="$(dirname "$PROFILED")"
  if [[ ! -d "$profiled_dir" ]]; then
    if ! install -d -m 0755 "$profiled_dir" 2>/dev/null; then
      echo "safeexec: WARNING: cannot create $profiled_dir; skipping $PROFILED."
    fi
  fi
  if [[ -d "$profiled_dir" ]]; then
    cat >"$PROFILED" <<EOF
# safeexec PATH hook (profile.d)
$path_block
EOF
    chmod 0644 "$PROFILED"
  fi

  # 2) macOS zsh (and harmless on Linux)
  printf '%s\n' "$path_block" | ensure_block_in_file "$ZPROFILE" "$MARK_BEGIN" "$MARK_END"
  printf '%s\n' "$path_block" | ensure_block_in_file "$ZSHRC"   "$MARK_BEGIN" "$MARK_END"

  # 3) bash login shells
  printf '%s\n' "$path_block" | ensure_block_in_file "$ETC_PROFILE" "$MARK_BEGIN" "$MARK_END"

  # 4) bash interactive non-login shells (Linux)
  local bashrc
  bashrc="$(pick_system_bashrc)"
  if [[ -n "$bashrc" ]]; then
    printf '%s\n' "$path_block" | ensure_block_in_file "$bashrc" "$MARK_BEGIN" "$MARK_END"
  fi

  # 5) sudo secure_path (optional; validated if possible)
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
    echo "safeexec: WARNING: /etc/sudoers.d not found; sudo protection NOT installed."
  fi
}

remove_hooks() {
  rm -f "$PROFILED" || true
  rm -f "$SUDOERS_FILE" || true

  remove_block_from_file "$ZPROFILE"    "$MARK_BEGIN" "$MARK_END"
  remove_block_from_file "$ZSHRC"       "$MARK_BEGIN" "$MARK_END"
  remove_block_from_file "$ETC_PROFILE" "$MARK_BEGIN" "$MARK_END"

  local bashrc
  bashrc="$(pick_system_bashrc)"
  if [[ -n "$bashrc" ]]; then
    remove_block_from_file "$bashrc" "$MARK_BEGIN" "$MARK_END"
  fi
}

# --- MAIN COMMANDS ---
cmd_install() {
  need_root
  write_wrapper_rm
  write_wrapper_git
  install_localbin_shims
  install_hooks
  echo "safeexec: installed wrappers in $SAFEEXEC_DIR"
  echo "safeexec: shims installed (or attempted) in $LOCALBIN"
  echo "safeexec: run: hash -r   (then test rm -rf /tmp/safeexec-test)"
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
    echo "[NO]"
  fi

  echo "which rm: $(command -v rm 2>/dev/null || echo 'n/a')"
  echo "which git: $(command -v git 2>/dev/null || echo 'n/a')"
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
