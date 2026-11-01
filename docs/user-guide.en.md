# Installation Guide (English)

日本語版: [user-guide.ja.md](user-guide.ja.md)

Runs on Windows 10 / 11 (64-bit). **You do not need to install Python or anything else first.**

On a Mac with Apple Silicon, see [8. macOS (Apple Silicon)](#8-macos-apple-silicon). Sections 1-7 are about Windows.

---

## 1. Install

1. Type `PowerShell` into the Start menu and open **Windows PowerShell**. You do not need to run it as administrator.

2. Copy the line below, paste it in, and press Enter.

   ```powershell
   irm https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.ps1 | iex
   ```

3. Follow the on-screen prompts to choose the tool you want to install.

4. When asked for a password, enter the one you received from your contact.
   Nothing appears on screen while you type — this is normal.

5. You are done when you see `was installed successfully.` A shortcut is now on your desktop.

Installation takes a few minutes. Please do not close the window before it finishes.

---

**VS Code extension (MMDAgent-EX).** If Visual Studio Code is installed and its `code` command works in a terminal, the installer also adds the extension that helps you edit MMDAgent-EX scripts. If not, the installer shows a command like `code --install-extension "...\mmdagent-ex-lua.vsix"`; after installing VS Code, run that command to add it.

## 2. Update

**Run exactly the same command again.**

```powershell
irm https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.ps1 | iex
```

If a newer version is available, it is installed. Your settings and any downloaded data are kept, so there is nothing to set up again.

**You need the password for updates too.** Please keep a note of it.

---

## 3. Release channels

There are two channels. **Unless you were told otherwise, use the default one — the command above already does.**

| Channel | Who it is for |
|---|---|
| `beta` (default) | Everyone. The version we ask people to use |
| `alpha` | Lab members helping to test the newest build. Updated often |

To install or update from the alpha channel, run this line instead:

```powershell
$env:LEELAB_CHANNEL = 'alpha'; irm https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.ps1 | iex
```

Running a line again updates you **within the channel you are on**: the plain line keeps you on beta, the alpha line keeps you on alpha.

To move to the other channel, simply run the line for that channel. The installer shows which channel you are on now, and asks you to confirm before it replaces what you have. Your settings and downloaded data are kept, as with a normal update.

The two channels have different version numbers, so moving from alpha to beta can install an older version. That is expected.

---

## 4. About the password

- This tool has not been released publicly, so only people with the password can install it.
- **Please do not share the password with anyone outside the project.**
- If you lose the password, or it is not accepted, please contact us.

---

## 5. Uninstall

Open Windows **Settings > Apps > Installed apps**, find the tool by name, and uninstall it.

---

## 6. If something goes wrong

**The app does not start, or the window disappears immediately**

If the `Lee Lab` folder of your Start menu has a **"(tool name) (Diagnostic Mode)"** entry, start it from there. A console window will show the error message. Please copy that text, or take a photo of it, and send it to us.

Some tools do not have that entry. In that case, please tell us what you saw: how far it got, and the wording of any error.

**"running scripts is disabled on this system"**

Run the command below, then try installing again.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

**Installation stops partway, or ends with an error**

A network proxy or antivirus software may be blocking the connection. Please copy the error message shown on screen and send it to us.

**"64-bit Windows is required"**

You need 64-bit Windows 10 or 11. Windows on ARM is not supported.

---

## 7. Disk space

The first installation uses about **4.5 GB**. Around 2.2 GB of that is a cache kept to make future updates fast.

If you are short on space, you can delete the cache with the command below. This only makes the next update slower; the app keeps working normally.

```powershell
& "$env:USERPROFILE\.local\bin\uv.exe" cache clean
```

---

## 8. macOS (Apple Silicon)

Some tools also have a macOS version (currently **MMDAgent-EX**). The installer only offers the tools that do.

**Requirements:** a Mac with Apple Silicon (M1 or later) and **macOS 15 or later**. Intel Macs are not supported. Nothing else needs to be installed first, and administrator rights are not required.

### Install

1. Open **Terminal** (Finder > Applications > Utilities > Terminal, or search for "Terminal" with Spotlight).

2. Copy the line below, paste it in, and press Return.

   ```bash
   curl -fsSL https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.sh | bash
   ```

3. When asked for a password, enter the one you received from your contact.
   Nothing appears on screen while you type — this is normal.

4. You are done when you see `was installed successfully.`

The app is placed in the **Applications folder of your home folder** (`~/Applications`; in Finder choose Go > Home, then open Applications). You can also find it with Spotlight (Command + Space).

### First launch

Open it like any other app. **No security warning is expected**: the installer downloads the files itself, so macOS does not treat them as "downloaded from the internet".

If macOS still says the app "cannot be opened" or "is damaged", open **System Settings > Privacy & Security**, scroll down, and click **Open Anyway** next to the message about the app. If that does not help, please contact us and tell us the exact message.

### Update

**Run exactly the same command again.** Your content is kept.

### Release channels

As on Windows, the plain command installs the default `beta` channel. For the `alpha` channel, put `LEELAB_CHANNEL=alpha` right before `bash` (after the `|`):

```bash
curl -fsSL https://raw.githubusercontent.com/lee-lab/tools-dist/main/install.sh | LEELAB_CHANNEL=alpha bash
```

Running a line again keeps you on its channel. Running the line of the other channel asks you to confirm before it switches.

If the chosen channel has no macOS version of the tool yet, the installer says so and stops without changing anything.

### Uninstall

Run this in Terminal:

```bash
~/Library/Application\ Support/LeeLab/mmdagent-ex/uninstall.sh
```

It removes the app, its entry in your Applications folder, and the VS Code extension it added. **Your content in the `MMDAgent-Contents` folder of your home folder (`~/MMDAgent-Contents`) is not removed.**

### Where things are

| What | Where |
|---|---|
| The app | `~/Library/Application Support/LeeLab/mmdagent-ex/` |
| The icon you start it from | `~/Applications/MMDAgent-EX.app` |
| Your content (MMDAgent-EX) | `~/MMDAgent-Contents` — kept on update and on uninstall |

**VS Code extension (MMDAgent-EX).** If Visual Studio Code is installed, the installer also adds the extension when the package includes it. Otherwise it shows the `code --install-extension ...` command to run later.

---

## Contact

Please contact **the person who gave you the password**.

When reporting a problem, it helps if you can tell us:

- Which tool and which version
- The error message shown on screen (copied text or a photo)
- What you were doing when it happened
