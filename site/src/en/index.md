---
title: Mobile-SSH-Client---Split-Keyboard — a landscape split-keyboard SSH terminal for iPhone and iPad
description: An SSH terminal for iPhone and iPad, used in landscape with a split keyboard on both sides of the shell. Built to drive tmux and Claude Code on your own Mac. iOS / iPadOS {{min_ios}} or later, free (¥0). Not on the App Store; you build it from source on a Mac and install it with a free Apple ID.
updated: 2026-10-30
---

# Mobile-SSH-Client---Split-Keyboard

An SSH terminal for iPhone and iPad that you hold in landscape, with the keyboard split into two halves on either side of the shell. It is a front end for driving tmux and Claude Code on your own Mac, and it puts network speed and typing feel first.

- **Devices**: iPhone and iPad on iOS / iPadOS {{min_ios}} or later. Landscape only
- **Price**: ¥0 (free). No paid Apple Developer Program membership needed
- **Distribution**: not on the App Store or TestFlight. You build it from source with Xcode on a Mac and install it with a free Apple ID
- **Settings**: one config file (like Ghostty). There is no settings screen

The primary language of this site is Japanese. The English pages cover the overview and Get Started; the other pages ([config](/config), [MCP](/mcp), [media](/media), [FAQ](/faq)) are in Japanese.

## The one line to give your agent {#one-line}

Give this line to an agent on your Mac (Claude Code or similar). It reads the runbook, runs the commands, and asks you only for the steps that need a human.

```text
Read {{base}}/en/get-started.md and install and set up Mobile-SSH-Client---Split-Keyboard on this Mac and iPhone.
```

Mainly five steps need a human: signing in to Xcode with an Apple ID, connecting the device by USB and tapping "Trust", turning on Developer Mode, trusting the developer profile on the device, and comparing key fingerprints with what the app shows.

## How it goes {#flow}

1. Give the line above to the agent on your Mac
2. The agent clones the repository, checks the tools, builds the app and installs it on the device
3. You do only the steps it asks you to do
4. The agent writes your host into the config, sends it to the device, registers the app's public key on the Mac, and schedules the automatic re-install
5. Open the app, check the host key fingerprint, and connect

## What it does {#features}

- **Split keyboard**: a US layout (Mac-style, split) and Japanese kana flick input (with kana-kanji conversion) on the left and right, with the shell in the middle
- **iPad hardware keyboards**: connect one and the on-screen keyboard disappears; the shell fills the screen
- **Survives disconnects**: reconnects automatically when the app returns to the foreground, the network changes, or the connection drops, and re-attaches to your tmux session
- **Touch**: drag vertically to scroll back, long-press to select, pinch to zoom. When vim, tmux or htop ask for the mouse, touches are sent as mouse events
- **Send media** (in development): send photos, videos and audio to an inbox on your Mac and put the paths on the command line. Videos become one image (a contact sheet) plus a transcript to save tokens. See [media (Japanese)](/media)
- **Agent-driven setup**: a `splitterm` command and MCP server on the Mac let an agent check, edit and push the config, register the public key and re-install the app. See [MCP (Japanese)](/mcp)

## Who it is for {#who}

- People who want to drive the shell or Claude Code on their own Mac from an iPhone or iPad
- People who can use a Mac with Xcode. Building and re-installing happen on the Mac (an agent can do the steps)

## Requirements {#requirements}

| Item | Requirement |
| --- | --- |
| iPhone / iPad | iOS / iPadOS {{min_ios}} or later: iPhone XS, XR, SE (2nd generation) or later; iPad (6th generation) or later |
| Mac | Xcode (signed in with a free Apple ID) and jq |
| Host | SSH (Remote Login on macOS) and tmux. Usually the same Mac |
| Network | The device must reach the host's SSH (same Wi-Fi, or Tailscale or similar) |
| First time only | A USB cable between the device and the Mac |

## Cost {#cost}

¥0. The app is free and is signed with a free Apple ID. This site is served from the Cloudflare Pages free tier. Whatever you run on the host (for example Claude Code) is billed by its own plan.

## Distribution and the 7-day limit {#distribution}

It is not on the App Store or TestFlight. You build it from source with Xcode on your Mac and sign it with a free Apple ID (Personal Team).

- Apps signed with a free Apple ID stop launching after 7 days. A launchd job on the Mac checks the expiry every hour and re-installs the app automatically when less than 48 hours are left
- Re-installing keeps your config, keys and saved host keys
- Free signing limits: up to 3 such apps per device, and up to 10 App IDs per 7 days

## Security and privacy {#privacy}

- No telemetry, no cloud sync, no AI features. Terminal content is never written to disk or sent anywhere
- The SSH key is created in the Secure Enclave and never leaves the device. Passwords are never stored
- The first connection shows the host key fingerprint; if it later changes, the connection is stopped
- Face ID (or passcode) on launch and on return; the app switcher shows a blurred view
- Text copied from the app is cleared from the clipboard after 60 seconds by default

## Status {#status}

In development (as of 2026-10-30). The implementation follows the design but has not been verified on a real device yet. Media sending is in development.

## Read next {#next}

- [Get Started](/en/get-started): the runbook an agent can execute
- [llms.txt](/en/llms.txt): the index for agents
- [日本語のトップ](/) (Japanese, primary)
- Source code: <{{repo}}>
