# Muninn setup guide

First-run steps, in order. Do them in this order: the signing certificate (step 2) decides
whether macOS permissions, Keychain items and firewall rules survive rebuilds, so make it
before you grant or save anything.

Requires macOS 26 or later.

Names, defaults and labels below were checked against the code. Two things are marked as not
verified: the Hugging Face and Ollama download CDN host names (step 3) and anything that needs
real hardware (the last section).

## 1. Build the app

```sh
scripts/vendor-fluidaudio.sh      # first time only; skips when its .vendored-<version> marker exists
scripts/bundle-app.sh             # release build, writes build/Muninn.app
```

The vendor script skips when `Vendor/FluidAudio/.vendored-<version>` exists (default version
`v0.17.7`, override with `FLUIDAUDIO_VERSION`). `bundle-app.sh` runs it itself, so the first
command is only needed on its own when you build `muninn-spike` first. Both reach GitHub:
`curl` downloads the FluidAudio archive (github.com, then `codeload.github.com`), and SwiftPM
fetches WhisperKit and swift-argument-parser. If you run an outbound firewall such as Little
Snitch, it will ask for `curl`, `git` and `swift-package`; allow `github.com` and
`codeload.github.com`.

Without `MUNINN_SIGN_IDENTITY` the script signs ad hoc and prints:

```
warning: signing ad hoc; macOS permissions and Little Snitch rules will be asked again after each rebuild (set MUNINN_SIGN_IDENTITY to keep them)
```

Fine for a smoke test, wrong for daily use. Fix it in the next step.

## 2. Create the code-signing certificate

An ad hoc signature changes with every build, so macOS treats each rebuild as a new app. A
stable certificate gives the app a stable identity, which keeps:

- the Microphone and System Audio Recording permissions,
- access to the Keychain items Muninn writes (Claude key, Graph tokens; service `be.netronix.muninn`),
- your firewall rules (for example Little Snitch).

1. Open Keychain Access.
2. Menu bar: Keychain Access > Certificate Assistant > Create a Certificate...
3. Name: `Muninn Local`. Identity Type: `Self Signed Root`. Certificate Type: `Code Signing`.
   Tick "Let me override defaults" and click Continue. Set Validity (days) to `3650` and keep
   clicking Continue to the end, setting an Organizational Unit (any value) on the
   certificate-information page. Keep the defaults elsewhere. Click Create,
   then Done.
4. Check that it is usable for signing:

   ```sh
   security find-identity -v -p codesigning
   ```

   `Muninn Local` must be listed. `-v` leaves out untrusted identities, so a trust problem
   never shows there. If `Muninn Local` is missing, run the command again without `-v` to see
   the trust error, then open the certificate in Keychain Access, expand Trust, set Code
   Signing to Always Trust, and check again with `-v`.
5. Rebuild and start:

   ```sh
   MUNINN_SIGN_IDENTITY="Muninn Local" scripts/bundle-app.sh
   open build/Muninn.app
   ```

   The first `codesign` run may ask for access to the certificate's private key; choose Always
   Allow. Export `MUNINN_SIGN_IDENTITY` from your shell profile if you do not want to type it each
   time.
6. After the first rebuild with a saved Claude key (step 8), check whether Keychain asks again
   for `claude.apiKey` or the Graph tokens. Items written by an ad hoc build belong to the old
   signature, so a prompt (choose Always Allow) or a re-entered key is expected once; it should
   not come back on later rebuilds. If it does, the signature is not stable.

Muninn is a menu bar app (no Dock icon). Its icon is a waveform; Settings is in its menu
(Settings…, Command-comma).

## 3. Outbound firewall (optional)

Skip this step if you do not run an outbound firewall. With one such as Little Snitch, allow
the following. Use domain rules where the table says so. `Muninn` is `build/Muninn.app`. `muninn-spike` is the CLI used by the
spike (`.build/release/muninn-spike`); the spike also needs the permissions in step 4 for the
terminal app you run it from.

| Host | Port | Who | Why |
|---|---|---|---|
| `graph.microsoft.com` | 443 | Muninn | calendar, people, mail drafts |
| `login.microsoftonline.com` | 443 | Muninn | device-code sign-in and token refresh |
| `api.anthropic.com` | 443 | Muninn, `muninn-spike` | the Claude engine (only when you pick it) |
| `<network-mac-host>` | 11434 | Muninn, `muninn-spike` | the Network Mac engine |
| `127.0.0.1` | 11434 | Muninn, `muninn-spike` | Ollama on This Mac |
| `huggingface.co` and `hf.co` (domain rules) | 443 | Muninn, `muninn-spike` | model downloads |
| `*.r2.cloudflarestorage.com` | 443 | `ollama` | `ollama pull` blobs |
| `registry.ollama.ai` | 443 | `ollama` | `ollama pull` manifests |

Model downloads. FluidAudio (Parakeet, diarizer) and WhisperKit both default to
`https://huggingface.co` (`ModelRegistry.swift` in FluidAudio, `ModelDownloader.swift` in
WhisperKit). Neither source names another host. Hugging Face serves the large files by
redirecting to its own CDN hosts (the Xet and LFS hosts, subdomains of `hf.co` and
`huggingface.co`), which are not in these sources and are unverified. Allow `huggingface.co` and
`hf.co` as domain rules so the subdomains are covered; observed hosts may differ, so allow what
your firewall shows if something still prompts. Downloads only happen the first time
each model is used, so do this with `muninn-spike transcribe` on a short file or the first
recording.

Ollama itself (`ollama pull`) needs `registry.ollama.ai` plus the storage host it redirects to
(observed as `*.r2.cloudflarestorage.com`; observed hosts may differ). Those rules are for the
`ollama` binary, not Muninn. On the Network Mac, a firewall also needs to let `ollama` accept
incoming connections on port 11434 (see step 6).

## 4. Permissions

Prompts for `Muninn` (bundle id `be.netronix.muninn`):

| Permission | What triggers it | Where to change it |
|---|---|---|
| Notifications | first launch of the app | System Settings > Notifications > Muninn |
| Local Network | first contact with the Network Mac. A denial looks exactly like an unreachable Network Mac. | System Settings > Privacy & Security > Local Network |
| Microphone | the first time a recording starts and opens your mic | System Settings > Privacy & Security > Microphone |
| System Audio Recording | the first time Muninn taps another app's audio (a call) | System Settings > Privacy & Security > Screen & System Audio Recording, in the "System Audio Recording Only" list |

Settings > Permissions shows the Microphone status (Allowed / Denied / Not requested yet) and
has an "Open Microphone settings" and an "Open System Audio Recording settings" button. macOS
does not report the system-audio permission, so that tab can only tell you it is requested on
the first call recording. To trigger the Microphone prompt without a call: menu bar > "Record a
conversation…" (mic only; stop it right after). The System Audio Recording prompt needs a
real call: accept the "Record call in <app>" offer when one is detected. Quit and reopen Muninn
after changing a permission if it does not take effect.

Other prompts that can appear, depending on what you use:

- Files and folders, or iCloud Drive: when Muninn writes into your Obsidian vault (step 9),
  macOS may ask for access to that folder, or to iCloud Drive if the vault lives there.
- Documents folder: only if you choose the Whisper model, because WhisperKit stores its models
  in `~/Documents/huggingface` (step 10).

## 5. This Mac engine: Ollama via Homebrew

```sh
brew install ollama
brew services start ollama                    # runs `ollama serve` on 127.0.0.1:11434
ollama pull qwen3:8b
```

`qwen3:8b` is the This Mac default in Settings (`macbook.model`). Check it answers:

```sh
curl -s http://127.0.0.1:11434/api/tags
```

The defaults for This Mac are: API `Ollama`, Base URL `http://127.0.0.1:11434`, Model `qwen3:8b`,
Keep alive `0` (the model unloads after each request, which frees memory for the rest of your
workload). Nothing to change in Settings > Engines unless you want something else. Under
memory pressure the default path does not run the engine on This Mac and the summary waits
instead; choosing This Mac explicitly in the "Written by" menu overrides memory pressure and
runs it anyway. It does not override a recording: while one is running, transcription,
diarization and This Mac summaries wait for it to end, whichever engine is chosen.

## 6. Network Mac engine

This engine is optional. It runs the summary model on a second, more powerful Mac on your own
network. The Network Mac address is empty by default, which means "not configured": the engine
selector reports "Set the network Mac's address in Settings" and makes no request.

On the Network Mac:

1. Install Ollama the same way: `brew install ollama`.
2. Make it listen on the network, persistently. `brew services` regenerates its plist, so use
   your own LaunchAgent. Create the log directory first (launchd cannot create it):
   `mkdir -p ~/Library/Logs/ollama`. Then create
   `~/Library/LaunchAgents/local.ollama.plist`:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
       <key>Label</key><string>local.ollama</string>
       <key>ProgramArguments</key>
       <array><string>/opt/homebrew/bin/ollama</string><string>serve</string></array>
       <key>EnvironmentVariables</key>
       <dict><key>OLLAMA_HOST</key><string>0.0.0.0:11434</string></dict>
       <key>RunAtLoad</key><true/>
       <key>KeepAlive</key><true/>
       <key>StandardOutPath</key><string>/Users/you/Library/Logs/ollama/ollama.log</string>
       <key>StandardErrorPath</key><string>/Users/you/Library/Logs/ollama/ollama.log</string>
   </dict>
   </plist>
   ```

   launchd does not expand `~`, so the log paths above must be absolute: replace `/Users/you`
   with your own home directory.

   Stop the Homebrew service first if it ever ran, so the two do not fight over the port:

   ```sh
   brew services stop ollama
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.ollama.plist
   ollama pull gpt-oss:20b
   ```

   To re-run this or after editing the plist, unload the agent first; a second `bootstrap` on a
   loaded agent fails with "Bootstrap failed: 5: Input/output error":

   ```sh
   launchctl bootout gui/$(id -u)/local.ollama
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.ollama.plist
   ```

   It starts when you log in to the Network Mac. `launchctl bootstrap gui/$(id -u)` needs a
   console (GUI) login there, so run it on that Mac, not over SSH.
3. Incoming connections on port 11434 must reach `ollama`. If the macOS firewall is on, allow
   incoming connections for `/opt/homebrew/bin/ollama`. If you run an outbound firewall such as
   Little Snitch there, add an incoming rule for `ollama` on port 11434 too.

Exposure: Ollama has no authentication and Muninn talks to it over plain HTTP, so every
transcript sent to the Network Mac crosses the network in the clear. Keep it LAN-only or behind
a VPN. Do not forward the port. To narrow it, set `OLLAMA_HOST` to the Network Mac's LAN address
instead of `0.0.0.0`.

On This Mac, in Muninn: Settings > Engines > Network Mac:

- API: `Ollama`
- Base URL: `http://<network-mac-host>:11434` (the field's placeholder is
  `http://my-mac.local:11434`), where `<network-mac-host>` is `<name>.local`, a bare host
  name, or a private LAN IP (10.x, 172.16-31.x, 192.168.x)
- Model: `gpt-oss:20b` (the default)
- Keep alive: `10m` (the default)

Plain HTTP only works in the app for those forms. The app is allowed local networking only
(`NSAllowsLocalNetworking` in `scripts/Info.plist`; arbitrary loads stay off), and App Transport
Security blocks a fully qualified name such as `http://mac.example.lan`, and VPN addresses such
as a Tailscale `100.x` (the error is -1022). Only `curl` bypasses ATS. `muninn-spike` is a plain
CLI with no Info.plist, which still gets default ATS, so a Network Mac URL the app blocks also
fails in `muninn-spike ... --engine studio`. In the app the failure shows as an unreachable
Network Mac and a silent fallback to This Mac. Use the `.local` name, a bare name or the
private IP. ATS judges the host string, so a bare MagicDNS name (`http://my-mac:11434`) passes
over a VPN, while `http://100.x.x.x` or `http://my-mac.tailnet.ts.net` does not. Otherwise the
Network Mac needs an HTTPS front end.

There is no "Test" button. The app checks reachability itself with `GET <Base URL>/api/tags`
(2 second timeout, must return 2xx) whenever it picks an engine. Check by hand first:

```sh
curl -s http://<network-mac-host>:11434/api/tags
```

If the Network Mac is the default engine and does not answer, Muninn falls back to the This Mac
engine (unless memory pressure rules that out too, then it waits). An empty Base URL means "not
configured" and has the same effect.

Default engine: Settings > Engines > Default engine is `This Mac` out of the box. Switch it to
`Network Mac` once the check above works. You can also rewrite one meeting with another engine
from the "Written by" menu in the summary toolbar.

## 7. Microsoft accounts (Entra)

Do this once per tenant you want to sign in to. Each gets its own app registration, so each
sign-in stays inside its own tenant.

In the Entra admin center (entra.microsoft.com) of the tenant:

1. Entra ID > App registrations > New registration. Name: `Muninn`. Supported account types:
   this organizational directory only. Skip the redirect URI. Register.
2. Copy the Application (client) ID and the Directory (tenant) ID from the Overview page.
3. Authentication > Add a platform > Mobile and desktop applications. No redirect URI is
   needed for device-code sign-in; configure the platform without ticking one.
4. On the same page: Advanced settings > Allow public client flows = Yes. Save. (Device-code
   sign-in fails without this.)
5. API permissions > Add a permission > Microsoft Graph > Delegated permissions. The app
   requests exactly the scopes in `DeviceCodeAuthenticator.scopes`:

   | Scope | Used for |
   |---|---|
   | `offline_access` | refresh tokens, so you sign in once |
   | `User.Read` | your own addresses |
   | `Calendars.Read` | matching a recording to its calendar event |
   | `Mail.ReadWrite` | creating the Outlook recap draft (a draft only; Muninn never sends) |
   | `People.Read` | recipient lookup |

   `User.Read` is added by default; `offline_access` is under OpenId permissions. None of these
   need admin consent by default. If the tenant blocks user consent, press "Grant admin consent
   for <tenant>" on the same page.

In Muninn: Settings > Accounts. Muninn starts with one account, "Work". **Add Account** adds
another one (for example for a second tenant); its ID is derived from its display name
(lowercased, ASCII, hyphens, unique). **Remove Account…** asks for
confirmation, signs the account out and deletes its Keychain token. It is refused while a
meeting is recording or being processed for that account. In the account's section:

1. Client ID: the Application (client) ID.
2. Tenant: the Directory (tenant) ID. The default `organizations` only works for multi-tenant
   registrations; a single-tenant app used with `organizations` fails with AADSTS50194. This
   registration is single-tenant, so enter the ID (or the verified domain).
3. Vault area: the folder name under the vault for this account, available as `{area}` in the
   note pattern (step 9). The default account's area is `Work`.
4. Click Sign in.

The sheet "Sign in to <account>" shows a code (with a Copy button) and a link
(`microsoft.com/devicelogin`). Open the link, enter the code, sign in as yourself in that
tenant and accept the consent screen. Muninn polls until you finish, shows "Reading your
profile", then "Signed in" with "Your addresses: ...". Those addresses (`mail` and the user
principal name) are merged into "Your addresses (comma separated)" for that account. They are
how Muninn recognises you among attendees. Add any aliases to that field by hand.
The section then shows "Signed in" with Sign out and Sign in again buttons. Tokens are in the
Keychain (service `be.netronix.muninn`, account `graph.<account id>`, for example
`graph.work`).

## 8. Claude

Settings > Engines > Claude:

- Model: `claude-opus-5-5` (default).
- Effort: `medium` by default; choices are `low`, `medium`, `high`, `xhigh`, `max`.
- API key: paste into "API key" and press Save (or Return). It is stored in the Keychain as
  service `be.netronix.muninn`, account `claude.apiKey`; the field then shows "Key saved", and
  Remove deletes it.

The default engine stays local. Claude is used only when you set Default engine to `Claude` or
pick it per meeting in the "Written by" menu, and then the transcript leaves this Mac for
`api.anthropic.com`. Without a saved key, choosing Claude waits instead of running.

"Use LLM cleanup" (same tab, off by default) runs an LLM pass over the transcript before
summarising. It only runs when an engine is available; otherwise it waits for one.

## 9. Obsidian

Settings > Obsidian:

| Field | Default | Meaning |
|---|---|---|
| Vault path | empty | your vault; "Choose..." opens a folder picker, so choose your Obsidian vault folder. The folder must exist. While it is empty, export and auto-file show "Choose your Obsidian vault in Settings first" and write nothing (auto-file shows it once per session). |
| Note pattern | `Meetings/{client}/{date} {title}.md` | placeholders `{area}`, `{client}`, `{date}` (yyyy-MM-dd), `{title}`; `{title}` is required |
| Inbox folder | `Inbox` | where a note goes as `<inbox>/<date> <title>.md` when a placeholder the pattern uses has no value (no client for `{client}`, no account for `{area}`) |
| File to Obsidian automatically | off | files a ready meeting without asking. It skips a meeting whose event is still unsettled, one already exported, and any path where a note already exists. |
| Include the transcript | off | embeds the transcript in the note; otherwise the note links to `transcript.md` in the data folder |
| Include the audio | off | copies the `.caf` files into the vault next to the note. About 1.5 GB for a 90-minute call, which matters if your vault syncs to the cloud. Leave it off unless you want that. |

`{area}` is the account's Vault area (step 7), which the default pattern does not use. `{client}` comes from Client domains: add rows
mapping a domain to a client name (`example.com` -> `Example`). A subdomain matches its parent
domain, the longest match wins, your own addresses are ignored, and with several clients the
one with the most attendees wins. With the default pattern, no match (no client) files the note in the inbox; a note with no account still files under its client. A pattern that uses `{area}` sends a note with no account to the inbox.
Per meeting, "To Obsidian" in the summary toolbar exports by hand (and asks before
overwriting an existing note).

## 10. Where the data lives

Paths follow XDG (`XDG_DATA_HOME` and `XDG_CONFIG_HOME` are honoured), but only when they are
set in the app's own environment. A Finder- or `open`-launched app does not see exports from
your zsh profile, so it uses the defaults below. The spike, run from a terminal, does see them.

| Path | Holds |
|---|---|
| `~/.config/muninn/settings.json` | all settings (the spike reads the same file) |
| `~/.local/share/muninn/meetings/<id>/meeting.json` | the meeting record |
| `.../<id>/audio/mic.caf`, `.../audio/system.caf` | raw audio, one track each |
| `.../<id>/transcript.json`, `transcript.md` | raw transcript |
| `.../<id>/transcript.clean.json`, `transcript.clean.md` | cleaned transcript |
| `.../<id>/summary.json`, `summary.md` | the summary |
| macOS Keychain, service `be.netronix.muninn` | `claude.apiKey`, `graph.<account id>` (for example `graph.work`) |
| `~/Library/Application Support/FluidAudio/Models` | Parakeet and diarizer models |
| `~/Documents/huggingface` | WhisperKit models, only if you choose the Whisper model. If Desktop & Documents sync to iCloud is on, they sync too. |

Disk: audio is stored as 16-bit integer PCM in a CAF file, one file per track, at the
device's sample rate (a 48 kHz microphone track is about 5.8 MB per minute, and a stereo call
track about twice that). A 90-minute call takes roughly 1.5 GB. It is not compressed, and
nothing is pruned automatically. The speech models read the files as ordinary audio.

To free the space, select a meeting and choose "Delete Meeting…" (the right-click menu in
the list, or the "..." menu in the meeting's header). After a confirmation it removes the whole
meeting folder: the recording, transcripts, summary and record. It is refused while that meeting
is recording, being processed or queued for processing. A note already exported to Obsidian, and
any audio copied into the vault, is not touched, but the note's links to the audio and to
Muninn's transcript files point into the deleted folder and will stop working. With "Include
the transcript" off (the default), the vault then holds no transcript for that meeting at all.
If a backup tool covers this folder, a big recording list grows the backup too.

## 11. Run the spike before relying on the app

Follow `docs/spike.md` end to end. It checks capture (Teams, Continuity, mic-only), the live
pipeline, transcription accuracy, summary quality per engine, and load while your normal
background workload (for example agent sessions, dev servers, browsers) is running. Treat the app as unproven until the pass criteria there are met.

## Known limitations

Not yet tested on real hardware, so expect surprises in:

- process taps on the system-audio path (per-app isolation, and the "all audio" fallback),
- Continuity (iPhone) calls taken on the Mac,
- live transcription during a real call,
- AirPods and Bluetooth hands-free (HFP) sample-rate switches mid-call,
- the first model download: each model downloads from Hugging Face the first time it is used,
  so the first transcription after install depends on the network and on any outbound firewall; run
  `muninn-spike transcribe` on a short file first to get it over with.

The full list of what the spike must settle is in `docs/spike.md`.
