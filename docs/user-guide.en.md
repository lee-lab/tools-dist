# Installation Guide (English)

日本語版: [user-guide.ja.md](user-guide.ja.md)

Runs on Windows 10 / 11 (64-bit). **You do not need to install Python or anything else first.**

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

## Contact

Please contact **the person who gave you the password**.

When reporting a problem, it helps if you can tell us:

- Which tool and which version
- The error message shown on screen (copied text or a photo)
- What you were doing when it happened
