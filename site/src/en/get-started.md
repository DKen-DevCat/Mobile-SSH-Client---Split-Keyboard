---
title: Get Started | Mobile-SSH-Client---Split-Keyboard
description: How to install and set up Mobile-SSH-Client---Split-Keyboard on a Mac and an iPhone or iPad. Written so an agent can execute it — each step has the command to run, how to verify success, and the steps that need a human (HUMAN-ONLY).
updated: 2026-10-31
---

# Get Started

You build the app from source with Xcode on a Mac and install it on an iPhone or iPad with a free Apple ID. Then you write your host into the config and send it, register the app's public key on the Mac, and let launchd re-install the app every 7 days. It costs ¥0.

An agent (Claude Code or similar) can execute this page as-is. To hand it off, give the agent on your Mac this one line:

```text
Read {{base}}/en/get-started.md and install and set up Mobile-SSH-Client---Split-Keyboard on this Mac and iPhone.
```

The Japanese version ([はじめる](/get-started)) is the primary one. The scripts print their messages in Japanese; the expected messages are quoted below with a translation.

## How to read this runbook {#how-to-read}

- Each step says what to run, then how to verify success. Run commands from the repository root (`~/Mobile-SSH-Client---Split-Keyboard`)
- Steps marked **HUMAN-ONLY** are not run by the agent. Ask the human, wait until they say it is done, then verify
- If a step fails, do not go on. Show the output to the human and see "Troubleshooting"
- For agents: never guess or invent a key fingerprint; always use the one the human reads from the app. Never put keys or passwords in the config. Ask the human for anything that needs `sudo`

## Prerequisites {#prerequisites}

| Item | Requirement |
| --- | --- |
| iPhone / iPad | iOS / iPadOS {{min_ios}} or later: iPhone XS, XR, SE (2nd generation) or later; iPad (6th generation) or later |
| Mac | Xcode and jq (install jq with Homebrew if missing) |
| Host | SSH (Remote Login on macOS) and tmux. Usually the same Mac |
| Network | The device must reach the host's SSH (same Wi-Fi, or Tailscale or similar) |
| Apple ID | A free one is enough. No paid Apple Developer Program membership needed |
| First time only | A USB cable between the device and the Mac |

## 1. Clone the repository {#clone}

Run:

```bash
git clone {{repo}} ~/Mobile-SSH-Client---Split-Keyboard
cd ~/Mobile-SSH-Client---Split-Keyboard
```

Verify: `ls scripts/ios_reinstall.sh` prints the file name. If you already have it, update it with `git pull`.

## 2. Check Xcode and the tools {#tools}

Run:

```bash
xcodebuild -version
jq --version
tmux -V
nc -z 127.0.0.1 22 && echo "SSH OK"
```

Verify: all four print a version or `SSH OK`.

If something is missing:

- jq or tmux: `brew install jq tmux`
- No `xcodebuild`, or it says "requires Xcode": **HUMAN-ONLY**. Install Xcode from the App Store and open it once. Then the human runs `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
- No `SSH OK`: **HUMAN-ONLY**. Turn on System Settings > General > Sharing > Remote Login

## 3. Build the splitterm command {#cli}

A command that runs on the Mac and lets an agent handle the config (it is also an MCP server). It has no third-party dependencies.

Run:

```bash
swift build -c release --package-path ios/TermCore
ios/TermCore/.build/release/splitterm doctor
```

Verify: the build ends with `Build complete!`, and `doctor` prints what it checked and how to fix what is missing. At this point it is fine if the Team, the device and the app are reported missing; later steps fill them in.

- To use it over MCP, register it now: `claude mcp add splitterm -- "$PWD/ios/TermCore/.build/release/splitterm" mcp` (details on the [MCP page, in Japanese](/mcp))
- If your checkout has no `ios/TermCore`, skip this step. The later steps also work with the `scripts/` commands

## 4. Sign in to Xcode with an Apple ID {#apple-id}

> **HUMAN-ONLY**: open Xcode, go to Xcode > Settings… > Accounts, click + and sign in with an Apple ID. A free Apple ID is enough (it creates a Personal Team). Never give the Apple ID password or verification codes to the agent.

Verify (the agent runs this):

```bash
defaults export com.apple.dt.Xcode - | plutil -extract IDEProvisioningTeamByIdentifier json -o - - | jq -r '[.[][] | select(.isFreeProvisioningTeam == true) | .teamID] | unique | .[]'
```

Success is one line with a 10-character Team ID. Nothing printed means the sign-in is not done yet. If two or more lines are printed, choose one with `export SPLITTERM_IOS_TEAM=<Team ID>`.

## 5. Connect the device by USB and trust the Mac {#trust-mac}

> **HUMAN-ONLY**: connect the iPhone or iPad to the Mac by USB. When the device asks "Trust This Computer?", tap Trust and enter the passcode.

Verify (the agent runs this):

```bash
xcrun devicectl list devices
```

Success: the device is listed and its state is not `unavailable`. If two or more devices are paired with the Mac, choose one with `export SPLITTERM_IOS_DEVICE=<UDID>`.

## 6. Turn on Developer Mode {#developer-mode}

> **HUMAN-ONLY**: on the device, turn on Settings > Privacy & Security > Developer Mode. Restart when asked, and after unlocking choose "Turn On" in the confirmation. If the item is not there, open Xcode once with the device connected by USB, and it appears.

Verify: the human sees it turned on in the same screen. Step 7 succeeding confirms it.

## 7. Install the app {#install}

The first run creates the signing certificate, registers the device, and creates the App ID and provisioning profile automatically.

Run:

```bash
scripts/ios_reinstall.sh
```

Verify: exit code 0, and the last line is `入れ直しました（ビルド …）。次の期限は …` ("re-installed (build …); next expiry …").

- With `splitterm` built, `ios/TermCore/.build/release/splitterm install` does the same. Over MCP, use `app_install`
- Exit code 1: read the message and the logs (`logs/ios_build.log`, `logs/ios_install.log`). `無料の Team が分かりません` ("cannot find the free Team") means go back to step 4
- Exit code 3: the Mac is short on memory. Close other apps, or run `scripts/ios_reinstall.sh --force`
- Exit code 5: the device cannot be reached. Reconnect the USB cable and unlock the device

## 8. Trust the developer profile on the device {#trust-developer}

> **HUMAN-ONLY**: on the device, open Settings > General > VPN & Device Management, choose "Apple Development: (your Apple ID)" and tap Trust. Then open Mobile-SSH-Client---Split-Keyboard and unlock it with Face ID or the passcode.

Opening the app once creates its public key (`splitterm.pub`) and a sample config in the app's Documents folder.

Verify (the agent runs this):

```bash
scripts/ios_pubkey.sh --print
```

Success: a line `ecdsa-sha2-nistp256 … splitterm` and a line `指紋: SHA256:…` ("fingerprint") are printed. This only prints; nothing is registered yet. If it says `公開鍵を取れませんでした` ("could not fetch the public key"), open the app again and retry.

## 9. Create the config and add your host {#config}

The config on the Mac is `~/.config/splitterm/config`. Create it from the sample and add one `host` line.

First, find the user name and address of the host:

```bash
whoami
scutil --get LocalHostName
```

On the same Wi-Fi the address is `<LocalHostName>.local`; with Tailscale it is this Mac's name in `tailscale status` (for example `mac.tail1234.ts.net`). Ask the human which one to use.

Run (replace `<user>` and `<address>`):

```bash
ios/TermCore/.build/release/splitterm config init
ios/TermCore/.build/release/splitterm host add mac <user>@<address> --tmux main
ios/TermCore/.build/release/splitterm config check
```

Verify: `config check` exits with 0. Lines it cannot read are printed as `N 行目: reason` ("line N").

Without `splitterm`, do the same with:

```bash
scripts/ios_push_config.sh --init
printf 'host = mac %s@%s tmux=main\n' "<user>" "<address>" >> ~/.config/splitterm/config
grep '^host' ~/.config/splitterm/config
```

All keys are listed on the [config page (Japanese)](/config).

## 10. Send the config to the device {#push}

Run:

```bash
scripts/ios_push_config.sh
```

Verify: it prints `送りました: … → <UDID>` ("sent"). A running app picks it up immediately. `splitterm push` (MCP: `config_push`) does the same.

## 11. Register the public key on the Mac {#pubkey}

This adds the app's public key to `~/.ssh/authorized_keys` on this Mac. The key file on the device can be changed from the Files app, so the fingerprint is compared with the app's screen before adding.

> **HUMAN-ONLY**: in the app, long-press ＋ → 「公開鍵をコピー」 ("Copy public key") and tell the agent the fingerprint shown (it starts with `SHA256:`). The agent never guesses it, and never uses the fingerprint printed by `--print` in step 8 instead (that would verify nothing).

Run (with the fingerprint from the human):

```bash
scripts/ios_pubkey.sh --fingerprint 'SHA256:<fingerprint shown in the app>'
```

Verify: it prints `足しました: …/.ssh/authorized_keys` ("added") or `もう登録してあります` ("already registered"). If it prints `指紋がアプリの表示（…）と違います` ("the fingerprint does not match the app"), stop and tell the human. The added line is prefixed with `restrict,pty` (terminal only; port forwarding and the like are disabled).

Alternatively, the human can run `scripts/ios_pubkey.sh` in their own terminal, compare the fingerprint and answer `y`.

## 12. Schedule the automatic re-install {#launchd}

Apps signed with a free Apple ID stop launching after 7 days. launchd checks the expiry every hour and re-installs when less than 48 hours are left (while the device is locked or the app is not in use).

Run (this rewrites the repository path inside the plist to the current location, then registers it):

```bash
mkdir -p ~/Library/LaunchAgents logs
sed -E "s#/Users/[^/]+/Mobile-SSH-Client---Split-Keyboard#$PWD#g" launchd/com.dken.splitterm-ios.plist > ~/Library/LaunchAgents/com.dken.splitterm-ios.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dken.splitterm-ios.plist
```

Verify: `launchctl list | grep com.dken.splitterm-ios` prints one line. It runs once right after registration, so `tail -n 3 logs/ios_reinstall.log` shows a line like `期限まで … 時間です。まだ入れ直しません` ("… hours until expiry; no re-install yet").

If it was already registered and bootstrap fails, run `launchctl bootout gui/$(id -u)/com.dken.splitterm-ios` and register again.

## 13. Connect for the first time {#first-connect}

First, print the host key fingerprint of the Mac you connect to (the agent runs this and shows it to the human):

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

> **HUMAN-ONLY**: open the app (it connects to the first `host` on launch; you can also long-press ＋ and pick one from its menu). When it asks you to confirm the host key fingerprint, accept only if it matches the `SHA256:…` printed above. If it differs, do not accept.

Verify: the app shows the tmux screen (session `main`). Setup is complete.

## Match the colors to Ghostty on your Mac (optional) {#colors}

Use this when the app's colors look paler than Ghostty on your Mac and you want the same colors. Build `splitterm` first (step 3).

Run (show the human what it will write first):

```bash
ios/TermCore/.build/release/splitterm theme import --dry-run
ios/TermCore/.build/release/splitterm theme import
ios/TermCore/.build/release/splitterm push
```

Verify: `--dry-run` prints what it would write (`color-space`, `background`, `foreground`, `palette`, `minimum-contrast`, `bold-is-bright`, `font-thicken`) and warns about values it could not read; the config is not changed. When the human agrees, run the second line to write the config, then `push` to send it to the device. The last line of the output says what to run next (`splitterm push`). With MCP, use `theme_import` (`dry_run` only shows the result) and `config_push`.

- It reads Ghostty's real values from `ghostty +show-config`; if that fails it reads Ghostty's config file and the theme file directly. For a light/dark pair (`theme = light:A,dark:B`) it uses the dark theme. If Ghostty cannot be found it fails with how to fix it
- `color-space` becomes Ghostty's `window-colorspace` (default `srgb`): slightly calmer than the current Display P3, but the same as on the Mac
- Color names such as `red` are not written (a warning is printed). Palette entries 16–255 are not imported; it only warns if they differ from the xterm standard
- The default of the readability correction `minimum-contrast` is 1 (no correction, like Ghostty). Setting it back to 4.5 pulls dark colors toward white

**Make true color reach tmux.** When the app starts tmux it passes `COLORTERM=truecolor` (with tmux 3.2 or later it also adds `-T RGB` and `-e COLORTERM=truecolor`; check with `tmux -V`). tmux's environment only reaches sessions created afterwards, so **recreate any session that is already running once**. Whatever runs inside (Claude Code and so on) ends, so **ask the human first**:

```bash
tmux ls
tmux kill-session -t main
```

Each tab has its own session (`main`, `main-2`, `main-3`…). After killing it, tap that tab in the app to reconnect (a new session is created). From the device you can do the same by running `exit` in that tab's shell (when the session has one window, the session ends) and opening the tab again.

To compare, print the same sample in Ghostty and in the app (outside and inside tmux): `scripts/colortest.sh`. If the true color bands show steps, the colors are still rounded to 256.

## Troubleshooting {#troubleshooting}

| Message | What to do |
| --- | --- |
| 「無料の Team が分かりません」 (cannot find the free Team) | Redo the sign-in in step 4. With two or more Teams, set `SPLITTERM_IOS_TEAM` |
| 「Mac と対になった iPhone がありません」 (no paired device) | Redo step 5 (connect by USB and tap Trust) |
| 「端末が 2 台以上あります」 (two or more devices) | Set `SPLITTERM_IOS_DEVICE` to the UDID |
| The app does not open ("Untrusted Developer") | Redo step 8 |
| The app does not open after 7 days | Re-install with `scripts/ios_reinstall.sh`. Check the launchd job (step 12) and `logs/ios_reinstall.log` |
| 「公開鍵を取れませんでした」「送れませんでした」 (could not fetch / send) | Open the app once, then retry |
| The host key does not match | There is no way to accept it. Only if you really changed the key, long-press ＋ → 「このタブのホスト鍵を忘れる」 ("forget this tab's host key") in the app |
| ⚠ on the config | Run `splitterm config check` to see the line numbers and reasons |
| Colors look pale only inside tmux, or the bands show steps | Check `tmux -V` is 3.2 or later, and that you recreated the running session ([steps](#colors)). Compare `scripts/colortest.sh` outside and inside tmux |
| 「認証に失敗しました」 (authentication failed) in the app | Check the public key is registered: if `grep -c splitterm ~/.ssh/authorized_keys` prints 0, do step 11. If it is there, check that you are allowed in System Settings > General > Sharing > Remote Login, and the permissions (`chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`). The reason appears in `log show --last 10m --style compact --predicate 'process BEGINSWITH "sshd"'` |
| The build stops at "Validate plug-in “SwiftTermBuildInfoPlugin”" | Human, first time only: open Xcode with `open ios/*.xcodeproj`, choose "Any iOS Simulator Device", press ⌘B and click "Trust & Enable" (to build in Xcode, first write `DEVELOPMENT_TEAM` into `ios/Config/Local.xcconfig`). Then redo step 7 |
