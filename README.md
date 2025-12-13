# SafeExec: Destructive Command Interceptor

**SafeExec** is a Bash-based safety layer designed to protect debian servers or Mac OSX from accidental or hallucinated destructive commands run by AI agents (like Codex/GPT) or human operators.

It intercepts dangerous commands (like `rm -rf` or `git reset --hard`) and enforces an interactive **confirmation gate** via `/dev/tty`. This prevents automated scripts or piped commands from bypassing safety checks.

## 🛡️ Features

*   **TTY-Based Confirmation:** Requires the user to manually type `confirm` to proceed. It explicitly ignores `echo confirm | command` pipes.
*   **Destructive `rm` Gating:** Intercepts `rm` only when `-f` (force) AND `-r` (recursive) flags are detected.
*   **Granular `git` Gating:**
    *   **Always blocked:** `git reset` (soft/mixed/hard), `git revert`, `git checkout`, `git restore`.
    *   **Blocked if forced:** `git clean -f`, `git switch -f`, `git switch --discard-changes`.
    *   **Blocked stashes:** `git stash drop`, `git stash clear`, `git stash pop`.
*   **Sudo Protection:** Updates `secure_path` to ensure `sudo rm -rf` is also intercepted.
*   **Audit Logging:** Logs all intercepted and confirmed actions to the system syslog.
*   **Fail-Safe:** Checks for `visudo` and `logger` availability to prevent system corruption during install.

## 🚀 Installation

You must run the script as **root**.

1.  **Download the script** (assuming you saved the code as `safeexec.sh`):
    ```bash
    chmod +x safeexec.sh
    ```

2.  **Install:**
    ```bash
    sudo ./safeexec.sh install
    ```

3.  **Activate:**
    Close your current shell session and open a new one (or run `hash -r`) to pick up the new `$PATH`.

## 📖 Usage

Once installed, usage is seamless. If an AI or user attempts a dangerous command, the execution is paused:

**Example: Deleting a directory**
```bash
$ rm -rf /var/www/html

[SAFEEXEC] DESTRUCTIVE COMMAND INTERCEPTED:
  rm -rf /var/www/html
Type "confirm" to execute:
```

**Example: Git Reset**
```
$ git reset --hard HEAD~1

[SAFEEXEC] DESTRUCTIVE COMMAND INTERCEPTED:
  git reset --hard HEAD~1
Type "confirm" to execute:
```

To proceed, you must type `confirm` and hit Enter. Any other input (or closing the terminal) aborts the command with exit code `130`.

## ⚙️ How It Works

1.  **Path Precedence:** It creates wrapper scripts in `/usr/local/safeexec/bin`.
2.  **Profile Hooks:** It prepends this directory to the `$PATH` via `/etc/profile.d` and `.bashrc`.
3.  **Sudoers Shim:** It creates `/etc/sudoers.d/safeexec` to modify the `secure_path`, forcing `sudo` commands to respect the wrappers.
4.  **Local Bin Shims:** It creates symlinks in `/usr/local/bin` (e.g., `/usr/local/bin/rm`) as a secondary catchment layer for scripts using that path.
5.  **Arguments Parsing:** It uses robust Bash argument parsing to distinguish between harmless flags (like `--work-tree=/tmp`) and destructive subcommands.

## ⚠️ Emergency Bypass

If the wrapper is preventing a legitimate automated task (e.g., a cron job) or you need to bypass it quickly, use the **absolute path** to the binary. SafeExec relies on `$PATH` resolution; absolute paths bypass it entirely.

```bash
# Bypass the wrapper explicitly
/bin/rm -rf /tmp/junk
/usr/bin/git reset --hard
```

## Uninstall

`sudo ./safeexec.sh uninstall`

## Verification

```bash 
./safeexec.sh status
SAFEEXEC_DIR=/usr/local/safeexec/bin
rm wrapper:       [OK]
git wrapper:      [OK]
sudoers:          [OK]
/usr/local/bin/rm shim: [OK]
/usr/local/bin/git shim: [OK]
PATH includes SAFEEXEC_DIR: [YES]
```
