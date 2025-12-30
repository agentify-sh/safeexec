# SafeExec: Destructive Command Interceptor (Ubuntu/Debian/WSL + macOS)

**SafeExec** is a Bash-based safety layer that protects **Ubuntu/Debian servers**, **WSL**, and **macOS** from accidental (or hallucinated) destructive commands run by AI agents (Codex/GPT) or humans.

It intercepts dangerous commands (like `rm -rf` or `git reset --hard`) and enforces an interactive **confirmation gate** via a real terminal input. This prevents pipes/non-interactive execution from bypassing safety checks.

> **Note:** SafeExec no longer edits `/etc/*` or shell dotfiles automatically. Older versions injected `case` blocks into zsh/bash init files and caused parse errors on some setups. Current versions rely on shims + (macOS) Homebrew git shim, and optional hard mode on Ubuntu/Debian/WSL.

---

## 🛡️ Features

- **TTY-Based Confirmation Gate**
  - Requires the user to type `confirm` to proceed.
  - Reads from a real terminal device (not stdin), so `echo confirm | ...` doesn’t bypass it.
  - If there is **no usable TTY**, the command is **blocked** (exit `126`).

- **WSL/Codex Harness Safety**
  - Some WSL/Codex setups have `/dev/tty` present but **unusable** (EACCES). SafeExec probe-opens it.
  - If there is no usable terminal input, SafeExec **blocks** rather than “half prompting” inside a TUI.

- **Destructive `rm` Gating**
  - Intercepts only when both recursive + force flags are present:
    - `rm -rf ...`, `rm -fr ...`, `rm --recursive --force ...`

- **Granular `git` Gating**
  - **Always gated:** `git reset`, `git revert`, `git checkout`, `git restore`
  - **Gated if forced:** `git clean -f` / `git clean --force`
  - **Gated if destructive:** `git switch -f`, `git switch --discard-changes`
  - **Gated stash ops:** `git stash drop`, `git stash clear`, `git stash pop`

- **Sudo Protection**
  - Installs `/etc/sudoers.d/safeexec` to prepend SafeExec into `secure_path`,
    ensuring `sudo rm -rf ...` and `sudo git ...` are intercepted (soft mode).

- **macOS Homebrew Git Coverage**
  - Apple Silicon (default Homebrew prefix): `git` usually resolves from `/opt/homebrew/bin/git`.
    SafeExec installs a **Homebrew git shim** there, backing up the original to:
    - `/opt/homebrew/bin/git.safeexec.real`
  - Intel macOS (common Homebrew prefix): `git` may resolve from `/usr/local/bin/git` which is often a
    Homebrew symlink into Cellar. SafeExec will detect this case and **safely back it up** to:
    - `/usr/local/bin/git.safeexec.real`
    then install the SafeExec shim at `/usr/local/bin/git`.

- **Ubuntu/Debian/WSL Hard Mode (recommended for Codex/agents)**
  - Codex/non-interactive harnesses can bypass PATH via:
    - `command -p rm`, absolute paths (`/usr/bin/rm`), or restricted env PATH.
  - Hard mode uses `dpkg-divert` to replace `/usr/bin/rm` and `/usr/bin/git` with safe dispatchers,
    catching **non-interactive shells, command -p, and absolute paths**.

- **Quick Toggle**
  - `safeexec -off` disables prompts **per-user**
  - `safeexec -on` re-enables
  - `safeexec status` prints current state
  - Global toggle:
    - `sudo safeexec -off --global`

- **Audit Logging**
  - Logs blocked + confirmed actions to syslog via `logger` (if available).

---

## 🚀 Installation

### macOS

```bash
chmod +x safeexec.sh
sudo ./safeexec.sh install
hash -r
```

### Ubuntu/Debian/WSL (Soft Mode)

```bash
chmod +x safeexec.sh
sudo ./safeexec.sh install
hash -r
```

### Ubuntu/Debian/WSL (Hard Mode — recommended for Codex/agents)

Hard mode is what makes SafeExec apply to **non-interactive harness execution** and cases where PATH is bypassed.

```bash
sudo ./safeexec.sh install
sudo ./safeexec.sh install-hard
hash -r
```

---

## 📖 Usage

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

## 🔀 Toggle On/Off

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

## ⚙️ How It Works

### Soft Mode (macOS + Linux)

1. Installs wrappers at:
   - `/usr/local/safeexec/bin/rm`
   - `/usr/local/safeexec/bin/git`
2. Installs shims (symlinks) at:
   - `/usr/local/bin/rm` → `/usr/local/safeexec/bin/rm`
   - `/usr/local/bin/git` → `/usr/local/safeexec/bin/git`
3. Installs sudo `secure_path` rule:
   - `/etc/sudoers.d/safeexec`

### macOS Homebrew Git Shim

Because Homebrew’s PATH often wins, SafeExec also installs:

- `/opt/homebrew/bin/git` shim → calls SafeExec wrapper
- Backup stored as:
  - `/opt/homebrew/bin/git.safeexec.real`

### macOS Intel Homebrew Symlink Backup

If Homebrew owns `/usr/local/bin/git` as a symlink into Cellar (common on Intel macOS),
SafeExec will:

- Move the existing symlink to: `/usr/local/bin/git.safeexec.real`
- Install its shim at: `/usr/local/bin/git`

Rollback:

```bash
sudo rm /usr/local/bin/git
sudo mv /usr/local/bin/git.safeexec.real /usr/local/bin/git
hash -r
```

### Ubuntu/Debian/WSL Hard Mode (`dpkg-divert`)

1. Diverts real binaries:
   - `/usr/bin/rm` → `/usr/bin/rm.safeexec.real`
   - `/usr/bin/git` → `/usr/bin/git.safeexec.real`
2. Installs wrappers at the original paths (`/usr/bin/rm`, `/usr/bin/git`) that dispatch into:
   - `/usr/local/safeexec/bin/rm`
   - `/usr/local/safeexec/bin/git`

Result: even `command -p rm`, absolute paths, and minimal environment shells are gated.

---

## ✅ Verification

```bash
./safeexec.sh status
```

### macOS expected output (PATH may be NO, that’s fine)

Apple Silicon:

```text
which git: /opt/homebrew/bin/git
effective gate git: [YES] (homebrew shim)
```

Intel (example):

```text
which git: /usr/local/bin/git
effective gate git: [YES]
```

### Ubuntu/Debian/WSL hard mode expected output

```text
rm hard-mode:    [YES] (/usr/bin/rm)
git hard-mode:   [YES] (/usr/bin/git)
```

---

## 🧹 Cleanup old broken SAFEEXEC blocks (if you see shell parse errors)

If you previously installed an older SafeExec version that injected `SAFEEXEC BEGIN/END` blocks into shell init files and your shells are now erroring on startup:

```bash
sudo ./safeexec.sh cleanup-dotfiles
```

This removes `# SAFEEXEC BEGIN` → `# SAFEEXEC END` blocks from common `/etc/*` and `~/*` init files (best-effort).

---

## ⚠️ Emergency Bypass

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

## 🧹 Uninstall

Soft mode uninstall:

```bash
sudo ./safeexec.sh uninstall
```

Hard mode uninstall (if enabled):

```bash
sudo ./safeexec.sh uninstall-hard
```

---

## Notes / Limitations

- Any solution can be bypassed by explicitly executing the real diverted binaries (hard mode):
  - `/usr/bin/rm.safeexec.real`
  - `/usr/bin/git.safeexec.real`
- Under full-screen TUIs (like Codex on Windows), prompts may appear “misplaced” due to UI redraw.
  SafeExec will block if it cannot read from a real terminal input.
