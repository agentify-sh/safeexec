# SafeExec: Destructive Command Interceptor (Ubuntu/Debian/WSL + macOS)

**SafeExec** is a Bash-based safety layer that protects **Ubuntu/Debian servers**, **WSL**, and **macOS** from accidental (or hallucinated) destructive commands run by AI agents (Codex/GPT) or humans.

It intercepts dangerous commands (like `rm -rf` or `git reset --hard`) and enforces an interactive **confirmation gate** using a *real terminal input* (`/dev/tty` when available). This prevents pipes and most non-interactive execution from bypassing safety checks.

> SafeExec **does not modify shell init files** (`~/.zshrc`, `/etc/zprofile`, etc).  
> If your shell prompt changed, that's a dotfile/theme issue (see “Shell prompt changed?” below).

---

## Features

- **TTY-based confirmation gate**
  - Requires the user to type `confirm` to proceed.
  - Reads from a real terminal device (not stdin), so `echo confirm | ...` doesn’t bypass it.
  - If there is **no usable TTY**, the command is **blocked** (exit `126`).

- **WSL / Codex harness safety**
  - Some WSL/Codex setups have `/dev/tty` present but **unusable** (EACCES). SafeExec probes-open it.
  - If there is no usable terminal input, SafeExec **blocks** rather than “half prompting”.

- **Destructive `rm` gating**
  - Intercepts only when both recursive + force flags are present:
    - `rm -rf ...`, `rm -fr ...`, `rm --recursive --force ...`

- **Granular `git` gating**
  - **Always gated:** `git reset`, `git revert`, `git checkout`, `git restore`
  - **Gated if forced:** `git clean -f` / `git clean --force`
  - **Gated if destructive:** `git switch -f`, `git switch --discard-changes`
  - **Gated stash ops:** `git stash drop`, `git stash clear`, `git stash pop`

- **Sudo protection (soft mode)**
  - Installs `/etc/sudoers.d/safeexec` to prepend SafeExec into `secure_path`,
    ensuring `sudo rm -rf ...` and `sudo git ...` resolve through SafeExec when PATH-based.

- **macOS Homebrew git coverage**
  - On Apple Silicon, `git` typically resolves from `/opt/homebrew/bin/git`.
  - SafeExec installs a **Homebrew git shim** at `/opt/homebrew/bin/git`, backing up the original to:
    - `/opt/homebrew/bin/git.safeexec.real`
  - On Intel macOS, if `/usr/local/bin/git` is a Homebrew Cellar symlink, SafeExec will back it up to:
    - `/usr/local/bin/git.safeexec.real`

- **Ubuntu/Debian/WSL hard mode (recommended for Codex/agents)**
  - Non-interactive harnesses can bypass PATH via:
    - `command -p rm`, absolute paths (`/usr/bin/rm`), or restricted env PATH.
  - Hard mode uses `dpkg-divert` to replace `/usr/bin/rm` and `/usr/bin/git` with safe dispatchers,
    catching **non-interactive shells, command -p, and absolute paths**.

- **Quick toggle**
  - `safeexec -off` disables prompts **per-user**
  - `safeexec -on` re-enables
  - `safeexec status` prints current state
  - Global toggle:
    - `sudo safeexec -off --global`

- **Audit logging**
  - Logs blocked + confirmed actions to syslog via `logger` (if available).

---

## Installation

### macOS (soft mode)

```bash
chmod +x safeexec.sh
sudo ./safeexec.sh install
hash -r
```

### Ubuntu/Debian/WSL (soft mode)

```bash
chmod +x safeexec.sh
sudo ./safeexec.sh install
hash -r
```

### Ubuntu/Debian/WSL (hard mode — recommended for Codex/agents)

Hard mode is what makes SafeExec apply to **non-interactive harness execution** and cases where PATH is bypassed.

```bash
sudo ./safeexec.sh install
sudo ./safeexec.sh install-hard
hash -r
```

---

## Usage

If a dangerous command is attempted, execution is paused:

### Example: `rm -rf`

```bash
rm -rf /var/www/html

[SAFEEXEC] DESTRUCTIVE COMMAND INTERCEPTED:
  rm -rf /var/www/html
Type "confirm" to execute:
```

### Example: `git reset --hard`

```bash
git reset --hard HEAD~1

[SAFEEXEC] DESTRUCTIVE COMMAND INTERCEPTED:
  git reset --hard HEAD~1
Type "confirm" to execute:
```

To proceed, type `confirm` + Enter. Any other input (or `Ctrl+C`) cancels with exit code `130`.

If SafeExec cannot access a usable terminal input, it blocks with exit code `126`.

---

## Toggle On/Off

Per-user:

```bash
safeexec -off
safeexec status
safeexec -on
```

Global (requires sudo):

```bash
sudo safeexec -off --global
sudo safeexec -on --global
sudo safeexec status --global
```

One-command bypass (no prompting for that single invocation):

```bash
SAFEEXEC_DISABLED=1 rm -rf /tmp/junk
SAFEEXEC_DISABLED=1 git reset --hard
```

---

## How it works

### Soft mode (macOS + Linux)

1. Installs wrappers at:
   - `/usr/local/safeexec/bin/rm`
   - `/usr/local/safeexec/bin/git`
2. Installs shims (symlinks) at:
   - `/usr/local/bin/rm` → `/usr/local/safeexec/bin/rm`
   - `/usr/local/bin/git` → `/usr/local/safeexec/bin/git`
3. Installs CLI:
   - `/usr/local/bin/safeexec`
4. Installs sudo `secure_path` rule:
   - `/etc/sudoers.d/safeexec`

### macOS Homebrew git shim

Because Homebrew’s PATH often wins, SafeExec also installs:

- `/opt/homebrew/bin/git` shim → calls SafeExec wrapper
- Backup stored as:
  - `/opt/homebrew/bin/git.safeexec.real`

### Ubuntu/Debian/WSL hard mode (`dpkg-divert`)

1. Diverts real binaries:
   - `/usr/bin/rm` → `/usr/bin/rm.safeexec.real`
   - `/usr/bin/git` → `/usr/bin/git.safeexec.real`
2. Installs wrappers at the original paths (`/usr/bin/rm`, `/usr/bin/git`) that dispatch into:
   - `/usr/local/safeexec/bin/rm`
   - `/usr/local/safeexec/bin/git`

Result: even `command -p rm`, absolute paths, and minimal environment shells are gated.

---

## Verification

```bash
./safeexec.sh status
```

### macOS expected output

`PATH includes SAFEEXEC_DIR` may show `NO` — that’s fine because shims win.

```text
SAFEEXEC_DIR=/usr/local/safeexec/bin
/usr/local/bin/rm shim: [OK]
/usr/local/bin/git shim: [OK]
which rm:  /usr/local/bin/rm
which git: /opt/homebrew/bin/git
effective gate rm:  [YES]
effective gate git: [YES] (homebrew shim)
safeexec: ON
```

### Ubuntu/Debian/WSL hard mode expected output

```text
rm hard-mode:    [YES] (/usr/bin/rm)
git hard-mode:   [YES] (/usr/bin/git)
```

---

## Emergency bypass

### Soft mode bypass (absolute paths)

```bash
/bin/rm -rf /tmp/junk
/usr/bin/git reset --hard
```

### macOS Homebrew bypass

```bash
/opt/homebrew/bin/git.safeexec.real reset --hard
```

### Ubuntu/Debian/WSL hard mode bypass

Hard mode is designed to be hard to bypass. If you must bypass in an emergency:

- Disable globally:
  ```bash
  sudo safeexec -off --global
  ```
- Or uninstall hard mode:
  ```bash
  sudo ./safeexec.sh uninstall-hard
  ```

---

## Uninstall

Soft mode uninstall:

```bash
sudo ./safeexec.sh uninstall
```

Hard mode uninstall (if enabled):

```bash
sudo ./safeexec.sh uninstall-hard
```

---

## Shell prompt changed?

If your prompt suddenly looks like:

```text
Ups-MacBook-Pro%
```

That means your zsh prompt/theme config didn’t load (usually `~/.zshrc` wasn’t sourced or errored). **SafeExec does not edit dotfiles**, so this is almost always due to a broken shell init file or a removed prompt/theme config.

Quick checks:

```bash
ls -la ~/.zshrc ~/.zprofile ~/.zshenv
zsh -n ~/.zshrc && echo "zshrc syntax ok"
command -v safeexec || ls -la /usr/local/bin/safeexec
echo "$PATH"
```

If `safeexec` isn’t found but `/usr/local/bin/safeexec` exists, your PATH likely doesn’t include `/usr/local/bin`.

---

## Notes / limitations

- Any solution can be bypassed by explicitly executing the real diverted binaries (hard mode):
  - `/usr/bin/rm.safeexec.real`
  - `/usr/bin/git.safeexec.real`
- Under full-screen TUIs (some Codex UIs), prompts may look “misplaced” due to UI redraw. SafeExec will block if it cannot read a real terminal input.
