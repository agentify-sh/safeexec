# SafeExec: Destructive Command Interceptor

**SafeExec** is a Bash-based safety layer designed to protect Debian/Linux servers and macOS from accidental (or hallucinated) destructive commands run by AI agents (Codex/GPT) or humans.

It intercepts dangerous commands (like `rm -rf` or `git reset --hard`) and enforces an interactive **confirmation gate** via `/dev/tty`. This prevents automated scripts, pipes, and non-TTY execution from bypassing safety checks.

---

## 🛡️ Features

- **TTY-Based Confirmation Gate**
  - Requires the user to manually type `confirm` to proceed.
  - Reads directly from `/dev/tty`, so `echo confirm | rm -rf ...` won’t bypass it.
  - If there is **no TTY**, the command is **blocked** (exit `126`).

- **Destructive `rm` Gating**
  - Intercepts `rm` only when **both** recursive and force flags are present:
    - `rm -rf ...`, `rm -fr ...`, `rm --recursive --force ...`, etc.

- **Granular `git` Gating**
  - **Always gated:** `git reset`, `git revert`, `git checkout`, `git restore`
  - **Gated if forced:** `git clean -f`, `git clean --force`
  - **Gated if destructive:** `git switch -f`, `git switch --discard-changes`
  - **Gated stash ops:** `git stash drop`, `git stash clear`, `git stash pop`

- **Sudo Protection (Linux + macOS)**
  - Installs `/etc/sudoers.d/safeexec` to prepend SafeExec to `secure_path`,
    ensuring `sudo rm -rf ...` and `sudo git ...` hit the wrappers.

- **macOS Homebrew Git Coverage**
  - Homebrew’s `git` typically resolves from `/opt/homebrew/bin/git` (often ahead of `/usr/local/bin`).
  - SafeExec installs a **Homebrew git shim** at `/opt/homebrew/bin/git`, backing up the original to:
    - `/opt/homebrew/bin/git.safeexec.real`
  - This makes `git` gating work even when PATH ordering would otherwise bypass it.

- **Quick Toggle (On/Off)**
  - `safeexec -off` disables prompting **per-user**
  - `safeexec -on` re-enables it
  - `safeexec status` shows current state

- **Audit Logging**
  - Logs blocked + confirmed actions to syslog via `logger` (if available).

- **Fail-Safe Install**
  - Uses `visudo -c` to validate the sudoers snippet before installing (if `visudo` exists).

---

## 🚀 Installation

You must run the install step as **root**.

```bash
chmod +x safeexec.sh
sudo ./safeexec.sh install
hash -r
```

Notes:
- You do **not** need `SAFEEXEC_DIR` in `$PATH` on macOS. Shims take precedence.
- After install, open a new terminal (or run `hash -r`) to refresh command lookup.

---

## 📖 Usage

Once installed, usage is seamless. If a dangerous command is attempted, execution pauses:

### Example: Deleting a directory
```bash
rm -rf /var/www/html

[SAFEEXEC] DESTRUCTIVE COMMAND INTERCEPTED:
  rm -rf /var/www/html
Type "confirm" to execute:
```

### Example: Git reset
```bash
git reset --hard HEAD~1

[SAFEEXEC] DESTRUCTIVE COMMAND INTERCEPTED:
  git reset --hard HEAD~1
Type "confirm" to execute:
```

- Type `confirm` + Enter to proceed.
- Any other input (or `Ctrl+C`) aborts with exit code `130`.

---

## 🔀 Toggle On/Off (recommended)

Disable prompts temporarily (per-user):

```bash
safeexec -off
safeexec status
```

Re-enable:

```bash
safeexec -on
safeexec status
```

Accepted forms:
- `safeexec on|off|status`
- `safeexec -on|-off|-status`
- case-insensitive (e.g. `safeexec OFF` works)

---

## ⚙️ How It Works (high-level)

1. **Wrappers**
   - Installs wrapper scripts at:
     - `/usr/local/safeexec/bin/rm`
     - `/usr/local/safeexec/bin/git`

2. **Shims**
   - Installs symlink shims in:
     - `/usr/local/bin/rm` → `/usr/local/safeexec/bin/rm`
     - `/usr/local/bin/git` → `/usr/local/safeexec/bin/git`

3. **macOS/Homebrew Git Shim**
   - On Apple Silicon, `git` often resolves to `/opt/homebrew/bin/git`.
   - SafeExec replaces that with a small shim that calls SafeExec’s wrapper and backs up the original:
     - backup: `/opt/homebrew/bin/git.safeexec.real`

4. **Sudo secure_path**
   - Installs `/etc/sudoers.d/safeexec` so `sudo` prefers SafeExec’s directory.

5. **/dev/tty Confirmation**
   - Prompts and reads from `/dev/tty` (not stdin), blocking pipes and non-interactive execution.

---

## ✅ Verification

```bash
./safeexec.sh status
```

Example output on macOS (common and OK):
```text
PATH includes SAFEEXEC_DIR: [NO] (OK if shims win)
which rm:  /usr/local/bin/rm
which git: /opt/homebrew/bin/git
effective gate rm:  [YES]
effective gate git: [YES] (homebrew shim)
```

Important: On macOS, **PATH may not include** `SAFEEXEC_DIR`. What matters is `effective gate ...: [YES]`.

---

## ⚠️ Emergency Bypass (absolute path)

SafeExec relies on PATH/shims. Absolute paths bypass it:

```bash
/bin/rm -rf /tmp/junk
/usr/bin/git reset --hard
/opt/homebrew/bin/git.safeexec.real reset --hard   # macOS: bypass safeexec shim explicitly
```

Use with care.

---

## 🧹 Uninstall

```bash
sudo ./safeexec.sh uninstall
```

This removes:
- wrappers in `/usr/local/safeexec/bin`
- shims in `/usr/local/bin`
- sudoers snippet
- Homebrew git shim and restores the original git (if it was shimmed)

---
