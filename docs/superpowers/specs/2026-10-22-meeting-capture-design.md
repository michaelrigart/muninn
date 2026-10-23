# Muninn: meeting capture, transcription and client recaps

**Date:** 2026-10-22
**Status:** In progress
**Scope:** phase 1 (meetings). Dictation is phase 2 and gets its own spec.

## Intent

The target user has client calls, often on Microsoft Teams, and sends the attendees a
recap afterwards: a bullet summary per subject with action points. Writing it from memory
is unreliable, and the write-up costs time after every call.

Muninn is a native macOS app that records the call (the user's mic plus the call audio, with
no bot joining), transcribes it locally, and turns the transcript into a draft recap the
user reviews and sends. The user no longer needs to take notes during calls. The name is
Odin's raven of memory, which flies out, hears what happens and reports back.

## Goals

1. **Record without a bot.** Capture the user's microphone and the system audio of a Teams
   call on their Mac. Also record an iPhone call taken on the Mac (Continuity) and an
   in-person conversation (mic only), if the spike in "First step" shows these work.
2. **Transcribe locally and accurately** in Dutch (Flemish), French and English, including
   calls that switch between them mid-sentence, with speakers told apart.
3. **Keep two versions of the transcript:** verbatim and cleaned. The transcript view toggles
   between **Clean**, **Show changes** (removed words greyed and struck through) and
   **Verbatim**.
4. **Draft a recap** right after the call: bullet points grouped by subject, with the action
   points listed under their subject. Each action point has an owner and, when one was
   mentioned, a due date. Every bullet and action point links back to the transcript moment
   it came from.
5. **Hand the recap to Outlook as a draft** addressed to the meeting's attendees. Muninn
   never sends email itself.
6. **File the meeting in Obsidian** (the vault the user chooses) as a meeting note.
7. **Choose the summary engine:** This Mac, the Network Mac, or Claude. There is a default
   in settings and a per-meeting switch to regenerate with another engine.
8. **Keep the Mac usable** while recording and processing, with the user's normal background
   workload (for example agent sessions, dev servers, browsers) running at the same time.

## Non-goals (phase 1)

- Dictation into other apps (Wispr Flow style). This is phase 2, which reuses the same
  capture and transcription parts.
- An "Ask" feature for questions across meetings. It may come later.
- Linux, Windows, iOS or Android. Keeping the data as Markdown leaves a later Linux version
  possible, but nothing is built for it now.
- A Teams bot, joining calls, or fetching Teams' own transcripts through Microsoft Graph.
- Sending email, or any other automatic contact with clients.
- Sharing, multiple users, App Store distribution, or a cloud backend.

## Anti-goals: how it fails even if it "works"

These come from the owner and are the acceptance bar.

1. **Poor transcription:** words, names or speakers come out wrong often enough that the
   user cannot trust the transcript.
2. **Poor summary:** the recap misses subjects, gets decisions wrong, or assigns action
   points to the wrong person, so fixing it takes as long as writing it.
3. **The Mac becomes unworkable** while Muninn records or processes.

Two more were added during design:

4. Anything recorded without the user clearly knowing a recording is running.
5. Client audio or text leaving the user's Mac, or their own network, without their explicit
   choice. A choice is either a setting they turned on (for example Claude as the default engine) or
   a pick for that one meeting.

## Constraints

- **Hardware.** The Mac running Muninn is a laptop with modest unified memory that may
  already be under memory pressure, with heavy swapping, while the user's normal workload
  runs. The Network Mac is a more powerful Apple silicon Mac on the user's own network.
- **Privacy and GDPR.** Telling participants they are being recorded is the user's
  responsibility, but the app must make the recording state unmistakable. Processing is
  local by default. The Network Mac is on the user's own network. Claude is used only when
  the user picks it, either for one meeting or as the default engine in settings. Only the
  transcripts of meetings it processes are sent.
- **The Obsidian vault may sync through a cloud service.** Raw conversations and customer
  data stay out of the vault by default (see Obsidian below).
- **Outbound firewall.** An outbound firewall such as Little Snitch can block new or
  ad-hoc-signed binaries until they are allowed. Muninn needs a stable code signature, so
  that every rebuild doesn't re-prompt for its connections (Claude API, Microsoft Graph, the
  Network Mac).
- **Toolchain.** Swift dependencies come through Swift Package Manager. Nothing is installed
  ad hoc.
- **Secrets.** The Claude API key and any Microsoft tokens live in the macOS Keychain. They
  are never logged or written to disk in plain text.

## Decided

### Platform

A native macOS app in Swift and SwiftUI, macOS only. The owner chose macOS-first and kept
Linux only as an option; Swift was chosen over Rust/Tauri. The reasons: Core Audio capture, the Neural Engine and Apple's samples are all
first-class in Swift.

The minimum is macOS 26, which the owner set on 2026-10-23. Older releases, macOS 15 included, are out
of scope. On macOS 26 a call tap can name the call app's bundle IDs and restore a helper
process that restarts mid-call.

### Shape of the app

- **Menu bar app**, with no Dock icon while idle. The dropdown has:
  - the recording state and controls (🚩 flag, pause, stop)
  - "Record a conversation…" for in-person or other calls
  - "Show live transcript"
  - recent meetings
  - "Open meetings… ⌘O"
- **When a call starts** in any app on the watch list (see Capture), Muninn asks whether to
  record: "Record" or "Not this one". It never records silently. The user can also start a
  recording by hand.
- **The recording pill** floats during a recording and can be dragged or hidden. It shows a
  red dot, the elapsed time, a level meter, 🚩 and stop. While recording, the menu bar icon
  is red, whether the pill is shown or not.
- **The live transcript window** is optional and closed by default.
- **The flag hotkey** is a global shortcut that marks "this matters" without typing. The
  summary must cover every flagged moment, and the transcript shows each one with a 🚩.
- **The main window:**
  - a sidebar of meetings by date, with search across all of them
  - for each meeting: a header (title, date and time, attendees, language, duration), a
    **Summary** tab and a **Transcript** tab
  - the actions "✉ Outlook draft" and "◆ To Obsidian"
  - on the Summary tab, a "Written by: <engine> ▾" switch with regenerate

### Capture

- Record the mic and the system audio as **separate tracks**. When the other side comes in
  through system audio (any call on the Mac), the mic track is "You", and only the call
  audio needs its speakers told apart.
- In **mic-only recordings** (in-person, or an iPhone on speaker), several people speak into
  the mic. There the mic track's speakers are told apart like call audio, and nothing is
  assumed to be "You".
- **Teams:** system audio plus mic, with no bot and nothing for a tenant admin to approve.
- **Other call apps** are handled the same way: Zoom, Webex, Slack, FaceTime, and Google Meet
  or any other call in a browser.
  - A call is noticed when an app on a **configurable watch list** starts using the mic.
    The default list holds the common call apps and the browsers. Apps that aren't on the
    list never trigger the prompt.
  - Muninn records that app's audio, plus the mic.
  - The meeting's details come from the calendar, not from the call app. If a calendar
    event is on at that moment, in any signed-in account (see Email), it supplies the title and
    attendees, whatever app hosts the call.
  - When more than one event matches (overlapping events, or the same invitation in more than one
    account), Muninn asks which one. The event, the account and the client can be
    corrected in the meeting header before any draft or export is made, since they decide
    the recipients, the sending mailbox and the vault folder.
  - With no event, the title is the app plus the time ("Zoom call, 14:02"), and the user adds
    recipients, searching their contacts.
- **Phone calls taken on the Mac (Continuity)** are wanted. Whether macOS lets the app capture
  them is not yet known; the spike decides. A call taken on the iPhone itself can't be
  captured. The only option there is the speaker plus "Record a conversation", at lower
  quality.
- **In-person conversations** are mic only and started by hand. Without an invite, the user
  adds recipients themselves.

### Transcription

- Two passes. A fast model (Parakeet) feeds the live transcript during the call. After the
  call, the full recording is transcribed again with the most accurate model the bake-off
  picks, and that final transcript is the one used for everything else. The two models may
  turn out to be the same.
- A **personal dictionary** of names and jargon (company, product and client names), empty
  by default and editable in settings, improves recognition and spelling.
- Languages: Dutch, French and English, detected automatically, mixing within a call
  allowed.

### Cleanup (verbatim → clean)

- Cleanup only **removes** fillers ("euh", "hmm"), false starts and repeated words, and fixes
  punctuation, capitalisation and sentence breaks. It never rephrases. This keeps the "Show
  changes" view exact, and it keeps the meaning from drifting, which matters if a client
  ever disputes what was agreed.
- Words that carry meaning in context ("allez", "bon") stay.
- Both versions are stored.

### Summary

- Bullets are grouped by subject. Under each subject come its action points (owner, text,
  due date if mentioned). Every bullet links to its moment in the transcript. Flagged
  moments are always covered.
- The summary is written in the language the call was held in.
- **Engines:**

  | Engine | Runs | Data leaves |
  |---|---|---|
  | This Mac | a small model, loaded only for the summary, then unloaded | nothing |
  | Network Mac | a larger model on an inference server on another Mac | the user's network only |
  | Claude | the Anthropic API, Claude Opus 5.5 (`claude-opus-5-5`) | that meeting's transcript |

- The default engine is a setting, and **as shipped it is local, never Claude**. Each
  meeting can be regenerated with another engine.
- **When the default engine can't run,** because the Network Mac is unreachable (away from that
  network, no VPN) or not configured, or memory pressure is too high to load This Mac's
  model:
  - **The Network Mac is unreachable or not set up, but This Mac can run:** Muninn uses the
    engine on This Mac and says so ("Network Mac unreachable" or "Network Mac not set up").
    Regenerating on the Network Mac later stays possible.
  - **Otherwise the summary waits.** The meeting shows why, for example "Waiting for the
    Network Mac" or "Set the network Mac's address in Settings", and offers
    **"Run on This Mac anyway"** and **"Use Claude"**.
  - **A waiting summary resumes on its own** once the default engine can run. Claude is
    never used unless the user picks it there or made it the default.
- The model per engine is picked by the bake-off on the owner's own calls, not by benchmarks.
  Starting candidates:
  - Network Mac: gpt-oss-20b, Qwen3 30B-A3B
  - This Mac: models of 4–8B

### Email

- **Microsoft Graph** provides the calendar and the drafts. The user registers the Entra app
  themselves, with delegated permissions only: read the calendar, write drafts, search
  people. Muninn acts only as the signed-in user.
- **Accounts:** one account, "Work", by default. Settings → Accounts has **Add Account** and
  **Remove Account…**, so each further account is signed in separately. Removing an account
  asks for confirmation, signs it out and deletes its Keychain token, and is refused while
  a meeting is recording or being processed for that account.
- The recipients are the attendees from the calendar invite, all ticked by default. The user
  is left out under all of their own addresses. They untick or add people per meeting.
- Muninn creates an **Outlook draft** and never sends. The draft goes into the mailbox of
  the account whose calendar held the meeting, which is the sender the client sees. With no
  calendar event, the user picks the account. Subject: "Recap: <meeting>, <date>". The body
  holds a greeting, a summary per subject, and the action points.
- A wrong recipient can still be fixed in Outlook before sending.

### Obsidian

- **The meeting note** holds the summary, the action points, the attendees, links to related
  notes, and a link to the full transcript and audio in Muninn's own storage.
- **Filing happens when the user clicks "◆ To Obsidian".** A setting files every meeting
  automatically instead (off by default, since the vault may sync to the cloud).
- **Filing is a one-time export.** The user edits the recap in Muninn first. If they file
  again after regenerating, Muninn asks before overwriting the note.
- **The vault path is empty by default.** Until the user chooses their Obsidian vault in
  Settings, export shows "Choose your Obsidian vault in Settings first" and writes nothing,
  and auto-file is skipped with the same notice once per session.
- **A setting** also puts everything in the vault: the full transcript, with the audio as a
  separate option.
- **Location** is configurable in settings: the vault path, the folder pattern, the inbox
  folder, and a mapping from attendee email domains to clients. The default folder pattern
  is `Meetings/{client}/{date} {title}.md`. `{area}`, the account's vault area, is also
  available in the pattern. A note goes to the inbox folder, `Inbox` by default, only when a
  placeholder the pattern uses has no value: `{client}` without a client, or `{area}` without
  an account.
- **Format:** action points are plain `- [ ]` checkboxes with Dataview inline fields, for
  example `[owner:: Jan]` and `[due:: 2026-11-07]`, with no Tasks plugin required.

### Storage

- Each meeting is plain files: Markdown for anything a human reads (summary, transcripts),
  with sidecar files for timings and structure. The audio is stored alongside them.

### Performance

Two of these are the owner's **hard constraints**: the time from hanging up to a draft, and
the Mac staying usable. If either fails, the owner decides what changes. The other targets
are the builder's, who may adjust them with measurements.

- **From hanging up to a draft recap** takes about a minute for a typical call and no more
  than 5 minutes for the longest. This covers the final transcription, telling speakers
  apart, cleanup and the summary, and is measured with the background workload busy. The owner set the budget;
  the 90-minute upper bound for call length is an assumption.
- **Transcription on the Network Mac** happens only if the bake-off shows This Mac can't meet
  that budget. In that case the final pass may run on the Network Mac, with the audio staying
  on the user's network. Otherwise all transcription stays on This Mac.
- **Away from the Network Mac, the budget doesn't apply** (the owner agreed). If the final
  pass normally runs on the Network Mac, it runs on This Mac instead, slower and at
  background priority. A summary that has to wait (see Summary) waits.
- **During a recording** Muninn only captures audio and runs the live transcription on the
  Neural Engine. It stays around 2 GB of memory or less and leaves the graphics chip alone.
- **After the call,** the final transcription and the cleanup run at background priority
  and make way for interactive work.
- **The engine on This Mac** loads its model only when it runs and unloads it straight away. When
  memory pressure is already high, it doesn't load the model; the summary waits instead (see
  Summary), unless the user chooses "Run on This Mac anyway".
- Every target is tested with the background workload busy, not on an idle Mac.

## First step: spike and bake-off

Before building the app, a throwaway spike checks the risks behind the three anti-goals on
real audio. The owner supplies real recordings, with the participants told: a Teams
call, an iPhone call taken on the Mac, and a mic-only conversation with at least two
people speaking.

**Test conditions.** Every measurement runs under a **written-down background workload**:
the normal working state (for example agent sessions, dev servers, browsers), recorded so
the run can be repeated.

1. **Capture**
   - Record the Teams and Continuity calls with both sides on separate tracks. This
     settles whether Continuity calls can be captured.
   - Check **detection**: a watched app starting to use the mic (Teams, and a call in a
     browser) triggers the prompt.
   - Check **isolation**: with music or a video playing in another app during the call,
     the recording holds only the call app's audio.
   - Fallbacks:
     - No per-app isolation: record all system audio, and say so in the prompt.
     - No reliable detection: recordings are started by hand only.
     - Continuity capture fails: phone calls drop out of phase 1.

     The spec records whichever applies.
2. **Live pipeline.** Run capture and live transcription together for at least 60 minutes,
   either during a long real call or with a long recording played through a call app.
   Measure how far the live transcript lags, memory use, and whether it stays on the
   Neural Engine.
3. **Transcription.** Run the candidate models on the recordings and compare them on
   Flemish accents, mixed languages, names, and telling speakers apart, including on the
   mic-only sample. The owner corrects one transcript by hand to serve as a reference.
4. **Summary.** Generate the recap on all three engines, and the owner judges which ones are
   good enough to send.
5. **End to end.** Time hanging up to a draft recap for a typical call (about 30 minutes)
   and for a 90-minute recording, using each engine setup that is actually wanted.
6. **Load and responsiveness.**
   - Record memory pressure, swap activity and CPU during steps 2 and 5.
   - The owner keeps working during those runs: typing in the editor and terminal,
     switching apps. A run fails if the owner notices lag they wouldn't accept.

The results pick the models and settle the builder's targets. A failed hard constraint
goes to the owner (see Performance).

## Left to the builder

- Which capture API to use, and how to notice a Teams call starting.
- How to avoid echo when the user uses speakers instead of a headset, so the call audio
  doesn't also land on the mic track.
- Which libraries to use for transcription and for telling speakers apart. Candidates:
  FluidAudio, WhisperKit, whisper.cpp.
- How to name speakers: match them to the invite's attendees using the conversation, with
  a manual rename.
- How cleanup marks removed words, plus a check that the clean text really is the verbatim
  text with only words removed and punctuation changed.
- Which inference server runs on the Network Mac (Ollama, LM Studio, MLX) and how to reach
  it securely.
- The details of the Graph sign-in and calls (flow, token refresh, people search).
- The file formats, the folder layout, and how long audio is kept.
- The detailed UI within the shape above.
