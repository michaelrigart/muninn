# Muninn UX pass — design

**Date:** 2026-11-03
**Status:** Approved
**Mockups:** the direction and playback mockups shown to the owner on 2026-11-03 are described in
full below; this document is the reference, the mockups were the illustration.

## Why

Muninn works, but it looks and feels like a basic macOS app, and it hides what it is doing. The
owner tested it and hit the common failures at once:

- a summary failed with a raw `NSURLErrorDomain Code=-1004 … http://127.0.0.1:11434/api/chat`
  dump because Ollama wasn't running, with Retry as the only way out;
- there is nowhere to read or copy what went wrong;
- long work (transcription, the recap, the first model download) shows a spinner and nothing else;
- the Meetings window opened behind other windows (fixed in the distribution work);
- there is no way to listen back to the conversation.

The owner wants Muninn to be beautiful and user friendly, in the spirit of Things, Shottr, Bear,
Reeder, Fantastical and Craft: crafted, calm, content first.

## Goals

1. **A recognisable, crafted look.** Calm and editorial: generous space, clear type, one accent.
2. **Always say what is happening.** Processing stage, queue position, model downloads and
   elapsed time, in the meeting, the sidebar and the menu bar.
3. **Errors are sentences.** Every failure says what happened and what to do next, with the right
   actions; the technical detail is one click away and copyable.
4. **A log the owner can copy from.** An Activity window and a "Copy diagnostics" action.
5. **Listen back and read along.** Play a meeting's audio; the transcript follows, highlighting
   the passage and the word being spoken.
6. **Fewer dead ends and fewer surprises.** Disabled controls say why, actions confirm when done,
   edits undo, and nothing destructive happens without a way back.
7. **Keyboard and accessibility** on a par with the reference apps.

## Non-goals

- Changing how Muninn records, transcribes or summarises: models, engines, prompts and the
  pipeline's order stay as they are. Probing This Mac before a run and reporting progress are in
  scope; changing what the stages do is not.
- New capabilities beyond playback: no audio editing, no exporting audio clips, no sharing.
- iOS, a widget, or a redesign of the Obsidian note format or the Outlook email.
- A custom theme or user-chosen colours.

## Anti-goals

- **Pretty but slower to use.** Every change must keep or shorten the path for the common jobs:
  review a recap, fix it, send the draft, file the note.
- **Hiding information to look clean.** Status, warnings and sources stay visible; only chrome is
  reduced.
- **Secrets or meeting content in the log.** The Activity log never holds transcript or recap
  text, API keys, tokens or email bodies.
- **Breaking the recording-consent behaviour.** The call prompt still never records silently, the
  all-audio fallback still asks, and red still means "recording".

## Decisions (owner's, 2026-11-03)

- The direction in the mockups: calm and editorial, New York serif for titles and recap subjects,
  SF for the interface, raven teal as the one accent, red only for recording, amber for "needs
  you", macOS 26 materials, light and dark following the system.
- Recipients leave the meeting header and live in the Outlook draft sheet. Account and client,
  which also decide the calendar event, the sending mailbox and the Obsidian folder, become one
  details chip in the header (for example "Work · Acme") that opens a popover; Obsidian filing
  stays one click (owner's answer to the design check).
- Delivered as three pull requests, in this order: (1) errors, Activity and processing status;
  (2) the Meetings window, recap, transcript and playback; (3) Settings, menu bar, call prompt,
  recording pill, notifications, keyboard and accessibility.
- Playback as in the mockup: a player docked at the bottom of the meeting, read-along highlighting
  at word level, click-to-listen, speaker lanes, speed control, and play marks on recap
  timestamps.
- Muninn is a regular app with a permanent Dock icon (distribution design, same date).

## Design system

One set of tokens and components, used everywhere; no hard-coded colours or ad hoc spacing.

### Colour roles

| Role | Light | Dark | Use |
|---|---|---|---|
| Accent | `#1D6779` | `#5FB0C2` | selection, primary buttons, links, progress, current playback |
| Accent soft | accent at 10% | accent at 13% | selected rows, current passage, source marks |
| Attention | `#9A5B00` (text), `#D68A00` (fills) | `#E8A33A` | "needs you", unsourced items, flags |
| Problem | `#C4302B` | `#FF6B63` | failures (never for recording) |
| Success | `#2E7D4F` | `#5CC489` | "Draft created", "Key saved" |
| Recording | `#ED1B2E` | same | the recording dot, menu bar icon and stop button only |

Text uses the system label colours. Every text colour meets WCAG AA (4.5:1) on its background in
both appearances; the builder checks each pair.

### Type

| Style | Font | Use |
|---|---|---|
| Meeting title | New York, 26–28 pt, semibold | meeting header |
| Subject | New York, 19 pt, semibold | recap subjects, pane titles |
| Body | SF, 14.5 pt reading / 13 pt interface | recap and transcript text / controls |
| Meta | SF, 12–12.5 pt, secondary | dates, durations, captions |
| Label | SF, 11 pt, semibold, uppercase, tertiary | section labels ("Actions", "Today") |
| Mono | SF Mono, 11–11.5 pt | timestamps, technical details |

macOS doesn't scale third-party apps' text with a system setting, so these sizes are fixed; layouts
use no fixed widths that would truncate text, and every window works at its minimum size.

### Space and shape

An 8-point grid (4 for fine adjustments). Corner radii: 6 (chips, tokens), 10 (cards, rows), 14
(windows' content cards, panels). Reading width for recap and transcript: at most 760 pt.

### Components

- **Status card**: the single component for progress, waits, warnings and problems (replaces the
  two banner styles and the inline spinner). It has a role (progress, waiting, attention,
  problem, success), a title sentence, an explanation sentence, up to three actions, and for
  problems a "Copy details" and "Show in Activity" pair.
- **Token**: a small rounded value (owner, due date, account, client) that opens a popover editor.
- **Chip**: a static label (client, engine).
- **Source mark**: a timestamp in mono on accent soft; in the recap it carries a play glyph.
- **Person chip**: an initials avatar plus a short name, for attendees. Its colour comes from the
  name, not from transcript speakers, which aren't linked to attendees.
- **Player**: see Playback.

### Copy style

"Recap" everywhere (never "summary" in the interface). Sentence case for every label, button and
menu item. Real ellipses (…) only where more input follows. "This Mac", "Network Mac", "Claude".
British spelling, matching the existing copy ("summarise", "colour").

## Problems and the Activity log (pull request 1)

### Problem model

A `Problem` value type in MuninnCore replaces raw error strings as what the interface shows:

- `title`: one sentence, what happened ("Ollama isn't running on This Mac");
- `explanation`: one or two sentences, why and what to do;
- `actions`: a list of typed actions (try again, write with another engine, open a Settings pane,
  sign in again, open the Activity window);
- `details`: the technical facts for copying, built from the allowlisted fields below.

A translator maps errors to problems. It covers at least:

| Cause | Title | Actions |
|---|---|---|
| Connection refused or timeout to This Mac's server | Ollama isn't running on This Mac (or "The model server on This Mac isn't running" when This Mac uses an OpenAI-compatible server) | Write with Claude (when a key exists), Try again, Engine settings |
| Network Mac unreachable or not set | The Network Mac can't be reached / isn't set up | Try again, Engine settings |
| HTTP 404 "model not found" from Ollama | The model `<name>` isn't installed | explanation names `ollama pull <name>`; Try again |
| Claude 401 or 403 | Claude didn't accept the API key | Change key…, Try again |
| Claude 429 or 529 | Claude is busy right now | Try again, Write on This Mac |
| Reply that doesn't parse or is cut off | The recap came back incomplete | Try again, Write with another engine |
| Graph `invalid_grant` or expired sign-in | Sign-in to `<account>` expired | Sign in again |
| Graph other HTTP errors | Outlook couldn't create the draft | Try again; details carry the status and Graph's error code |
| Keychain errors (a new probe state: today a failed key read looks like "no key") | Muninn couldn't read its saved key | Engine settings |
| Speech model download failure | The speech model couldn't be downloaded | Try again; explanation mentions the network and firewall |
| Disk write failure | Muninn couldn't save `<what>` | Try again; details carry the path |
| Hotkey already in use | The shortcut `<keys>` is used by another app | Recording settings |
| Anything else | Something went wrong while `<stage>` | Try again, Show in Activity |

**Details hold no free-form text from outside Muninn.** A server can echo the transcript back in
any message it returns, so details are built only from these fields:

- error domain and numeric code;
- HTTP method, status and the endpoint's path (the host is shown only in the window's own copy);
- engine, provider and model, taken from Muninn's own settings;
- a provider error **category** chosen by the translator from a fixed list (for example
  `modelNotFound`, `unauthorized`, `rateLimited`, `overloaded`, `contextTooLong`, `badRequest`,
  `serverError`, `unknown`), recognised from the status and known error shapes (Ollama's
  `error`, Anthropic's `error.type`, Graph's `error.code`). The provider's own message text is
  never kept;
- stage and elapsed time;
- app and macOS version.

`ProcessingStatus.failed` stores the problem (title, explanation, action kinds, details) instead of
a raw string, and so does `engineNotice` (a regeneration that failed but kept the previous recap).
A meeting saved with an old raw string loads as a generic problem: "This meeting couldn't be
finished" with a plain explanation and Try again. The old string is shown nowhere: not in the
interface, the details, the Activity log or diagnostics. Its details say only that it came from an
earlier version of Muninn. Every channel that shows an error today uses the same component:

- the processing status and engine notice on a meeting;
- meeting action errors and notices (draft, export, delete, event change);
- settings save failures and field validation;
- the sign-in sheet and account status;
- the change-event popover;
- recording notices in the call prompt, the pill and the menu;
- the Live transcript window's status.

### This Mac probe

Before a run on This Mac, Muninn checks that its server answers (the same way it checks the
Network Mac today). If it doesn't, the meeting waits with the "Ollama isn't running on This Mac"
card and its actions, instead of failing. While a meeting waits on This Mac or the Network Mac,
Muninn re-checks every 15 seconds (not only on the 60-second retry), so starting the server clears
the wait within about 15 seconds.

### Activity log

- **What goes in:** every problem (with details), every warning, and milestones: recording
  started and stopped, transcription done (with duration), recap written (engine, model, time
  taken), draft created, note filed, sign-in changes, settings save failures, model downloads,
  launch recovery. Errors that today only reach `os.Logger` or are dropped become entries: settings
  save failures, meeting list and detail load failures, people search and calendar fetch failures,
  Keychain read failures, Network Mac probe failures, LLM cleanup fallbacks, summary retries,
  diarisation failures, pipeline failures, and auto-file failures.
- **What never goes in:** transcript text, recap text, email bodies, HTTP response bodies, API
  keys, tokens, or full attendee address lists. Entries carry only the allowlisted detail fields
  above. A redaction step still runs over every entry for anything that looks like a key or
  bearer token, as a second line of defence.
- **Entry:** time, level (info, warning, problem), area (Recording, Transcription, Recap, Outlook,
  Obsidian, Accounts, Engines, App), meeting id and title when there is one, message (the
  problem title or a milestone sentence), details.
- **Storage:** JSON lines in `$XDG_STATE_HOME/muninn/activity.jsonl`, defaulting to
  `~/.local/state/muninn/activity.jsonl`, matching the app's XDG paths. Entries older than 14 days
  are dropped at launch; the file is capped at 5 MB, dropping the oldest entries first.
- **Window:** "Activity", opened from the menu bar menu and the Help menu. Newest first; filter
  All / Problems; search; selecting an entry expands its details with a Copy button; a meeting
  name opens that meeting. The toolbar has "Copy diagnostics"; the footer has "Show log file in
  Finder" and the retention note.
- **Copy diagnostics** is safe to paste into a public issue:
  - app version and build, macOS version, Mac model class (Apple silicon or not);
  - the engine settings: engine, model names, whether a base URL is set and its scheme and port,
    never keys or private hostnames;
  - the permission states Muninn can read, with "not reported by macOS" for System Audio Recording
    and Local Network;
  - the last 200 entries with details, with meeting titles and ids replaced by short stable
    labels ("meeting A"), and email addresses, account names and hostnames masked.

  Copying a single entry from the window keeps its full details, for the owner's own use.
- `os.Logger` stays for development logging; the Activity log is the user-facing record.

### Processing status

- **Stages:** Transcribed, Speakers, Cleaned up, Recap, shown as a four-step bar on the status
  card with the current stage, the engine and the elapsed time.
- **Queue:** a meeting waiting behind another shows "Waiting its turn" with the number of meetings
  ahead. This fixes today's bug where a queued meeting reads "Transcribing".
- **Downloads:** the first use of a speech model shows "Getting the speech model ready", on the
  meeting and in the Live transcript window, with a percentage where the model library reports
  progress (the Parakeet and Whisper models) and an indeterminate bar with "This can take a few
  minutes the first time" where it doesn't.
- **Needs attention** means the owner has to act:
  - a failed meeting;
  - a wait that won't clear by itself (no Network Mac address, no Claude key, the This Mac server
    not running, a key Muninn can't read);
  - a regeneration that failed and kept the previous recap.

  Waits that clear by themselves (a recording in progress, memory pressure, the queue, a Network
  Mac that is asleep) don't count.
- **Everywhere:** the sidebar row shows a progress ring while processing and an amber dot when the
  meeting needs attention; the menu bar menu leads with the current work ("Writing the recap ·
  Supplier call · step 4 of 4") or "1 meeting needs attention"; a "Needs attention" smart list
  collects those meetings.
- **Notifications:** "Recap ready" as today, plus "Needs attention" once per meeting each time it
  enters that state (the 60-second retry never repeats it), and never while a recording is in
  progress (it is sent when the recording stops). The notification permission is asked the first
  time a notification would be sent, not at launch.

## The Meetings window (pull request 2)

### Window and toolbar

- Default size 1180×780; minimum 820×560. The sidebar column 220–320 pt.
- A unified toolbar: Recap / Transcript segmented control; the engine button ("Claude ▾", which
  regenerates with the chosen engine and says that Claude sends the transcript off the Mac);
  "Outlook draft"; "Obsidian"; a "…" menu (Previous version, Move to Trash…). On the Transcript
  tab the toolbar also holds Clean / Changes / Verbatim, Search and Copy all.
- The window title is the meeting title.

### Sidebar

Search covers titles, clients, attendees, recap text and transcript text. Smart lists: All
meetings, Needs attention. Day groups as today. Each row: title, time and duration, client chip,
and one status sign (progress ring, amber dot, or a quiet "Draft created" / "Filed").

### Header

The title in New York (editable on click, looks like text otherwise); one meta line (date, time
range, duration, language); one row of chips:

- the calendar event (click to change it, in a popover; "No event" asks before clearing the title
  and attendees);
- the details chip, "<account> · <client>", opening a popover with the account and client
  pickers. Changing the account there says when it will drop an event from the other account,
  and asks first;
- the attendees as person chips (+N for the rest).

### Recap

- Subjects as New York headings; bullets as real text; an "Actions" label over action rows.
- An action row: a checkbox-styled marker, the text, an owner token and a due-date token, and its
  source mark. Tokens appear on hover and when set.
- Source marks show the transcript timestamp (`12:04`) instead of `S12`; hovering shows "Play from
  12:04"; clicking plays from there with the transcript beside it (see Playback). Unsourced items
  carry an amber "No source in the transcript" mark.
- Fields look like text until clicked. Removing a subject, bullet or action is immediate and
  undoable with ⌘Z (an `UndoManager` covers all recap edits); "Previous version" stays for
  whole-recap rollback.
- A quiet footer: "Written by <engine> · <when> · Previous version".

### Removing a meeting

"Move to Trash…" replaces the permanent delete. After a confirmation that says what happens to
an exported Obsidian note, it moves the whole meeting folder to the macOS Trash, so it can be put
back from Finder. Muninn picks a put-back meeting up again the next time it reloads its list (at
launch, and from a "Reload" item in the View menu). The same refusals apply as today: no removal
while the meeting is recording, processing or queued. The confirmation's default button is Cancel.

### Outlook draft sheet

Clicking "Outlook draft" opens a sheet with the sending account shown (changed through the details
chip), the recipients as checkbox rows with search-or-type to add, the subject, and a preview of
the recap. "Create draft" shows progress on the button, then "Draft created · Open in Outlook" on
the meeting. "Obsidian" files in one click, using the details chip's client and account, and then
shows "Filed in Obsidian · Reveal".

### Transcript

One continuous, selectable text flow: speaker names in their colours, timestamps in the margin,
the three views (Clean, Show changes, Verbatim) as today, ⌘F search with matches highlighted,
Copy all. Renaming a speaker stays a popover on the name.

### Playback

- **Player:** docked at the bottom of the meeting window whenever the meeting has audio. Controls:
  skip back 15 s, play/pause, skip forward 15 s; a scrubber with elapsed and remaining time;
  speaker lanes above the scrubber (one lane for "You", one for the call, coloured per speaker,
  built from the transcript segments); flag ticks in attention colour; speed 1×, 1.25×, 1.5×, 2×
  with pitch kept natural; volume.
- **Audio:** the meeting's `audio/mic.caf` (mono) and `audio/system.caf` (the call's own rate)
  play together. Both tracks follow the recording's shared clock: each is padded with silence or
  trimmed when it drifts more than 50 ms, and paused time is cut from both, so both start at time
  zero and segment and word times are on the same timeline. A mic-only meeting plays its one
  track. If one file is shorter (a write failed), playback continues on the other.
- **Mix:** a menu next to volume chooses Both (default), Call only or Me only. Call only is the
  cure when the owner was on speakers without echo cancellation, where the mic track also carries
  the call's echo.
- **Read along:** while playing, the current segment gets the accent-soft tint and the current
  word the accent-mid highlight, updated at least 20 times a second, from the transcript's word
  timings. All three views follow:
  - Verbatim and Show changes use the segment's word timings directly;
  - Clean maps its words back to the verbatim words with the same alignment Show changes uses,
    and skips the removed ones;
  - a segment without word timings (Parakeet without token timings, some WhisperKit segments)
    highlights as a whole segment;
  - words changed by vocabulary boosting use their estimated times.

  The transcript auto-scrolls to keep the current passage in view; when the owner scrolls away, a
  "Back to 12:04" button appears and playback continues.
- **Tabs and windows:** playback continues when the owner switches between Recap and Transcript,
  and the player stays visible on both. Clicking a recap source mark switches to the Transcript tab
  at that moment and plays. Switching to another meeting pauses; closing the window stops.
- **Click to listen:** clicking a timestamp or a sentence seeks there and plays. Space plays and
  pauses when no text field has focus; ← and → skip 15 s; ⇧← and ⇧→ jump to the previous or next
  segment.
- **Memory:** the position is remembered per meeting for the session and across launches (stored
  outside the meeting folder, keyed by meeting id, removed when the meeting is deleted). Switching
  to another meeting pauses.
- **No audio:** Muninn never deletes audio on its own, but when the files are missing the player is
  replaced by a quiet line: "The recording for this meeting isn't available."
- **Sidebar:** the playing meeting's row shows a small animated level mark.

## Settings, menu bar, prompt and pill (pull request 3)

### Settings

A sidebar like System Settings (Engines, Accounts, Obsidian, Recording, Vocabulary, Permissions),
each pane sized to its content.

- **Engines:** a card per engine with a radio for the default, a one-line description, live status
  ("Ollama isn't running", "Connected · gpt-oss:20b", "Key saved · reachable", "No address set")
  and a Test button. Claude's card says "Sends the transcript to Anthropic to write the recap."
  Advanced fields (API kind, base URL, keep alive, effort) sit behind a disclosure, each with a
  sentence of help.
- **Accounts:** a card per account with its own status and errors next to it; sign-in sheet as
  today, showing when the code expires and confirming "Copied".
- **Recording:** an app picker for the watch list instead of bundle IDs; a shortcut recorder for
  the flag hotkey; model pickers with human names ("Parakeet v3 — fast", "Whisper large v3 turbo —
  most accurate").
- **Permissions:** Microphone and Notifications with their state; System Audio Recording and Local
  Network, which macOS doesn't report, with a sentence on when macOS asks and what a denial looks
  like. Each has a button to the right System Settings pane.
- A failed save shows next to the field and keeps the field marked unsaved.

### Menu bar menu

A status block first (recording with elapsed time, or the current processing work with its step,
or "1 meeting needs attention"); then Record a conversation (with its shortcut), Show live
transcript (only while recording); Recent (five meetings with time and status dot); Open
Meetings ⌘O, Activity, Settings… ⌘,, Quit Muninn ⌘Q. Notices longer than one line open the
Activity window instead of widening the menu.

### Call prompt

Anchored below Muninn's menu bar icon (away from notification banners), on glass, with the calling
app's icon, "Call in <app>", "Record this call?", Record and Not this one, and one line on what is
recorded. Its icon is neutral, not red. It never takes keyboard focus: a Return typed into the call
app's chat must never start a recording. Record is a click, or the global "Record" shortcut
(⌃⌥⌘R by default) while the prompt shows.

### Recording pill

A glass capsule: the recording dot, elapsed time, your level and the call's, flag, pause and stop.
"Paused" shows as text while paused. Warnings appear as a second line in attention colour, readable
without a tooltip. Its position is remembered across launches.

### Keyboard and accessibility

- A Meeting menu: Regenerate ⌘R, Outlook draft ⌘D, Obsidian ⌘E, Move to Trash ⌘⌫, Play/Pause
  Space, Find ⌘F; Record a conversation ⌃⌥⌘R globally (configurable like the flag hotkey).
- Every icon-only button has an accessibility label; level meters expose their value; status signs
  have text equivalents; emoji are not used as interface.
- No fixed widths that truncate labels or names; every window and pane works at its minimum size.

## Constraints

- macOS 26, SwiftUI with AppKit where needed, Swift 5 language mode, `MuninnCore` stays
  dependency-free (the `Problem` model, the translator's mapping rules, the activity entry type and
  redaction, and the read-along timing logic live there and are unit tested).
- The build, signing and release recipe from the distribution design is unchanged.
- Performance: playback highlighting must not make typing in the recap or scrolling the transcript
  stutter on a 90-minute meeting; the transcript view stays lazy.
- Public repository rules: no personal details or workflow-specific content.

## Delivery

One branch and pull request per milestone, each with its own plan, reviewed and merged before the
next starts:

1. `feat/ux-problems-activity`: design-system tokens and the status card, the problem model and
   translator, the This Mac probe, the Activity log and window, processing status and queue,
   notifications.
2. `feat/ux-meetings-window`: toolbar, sidebar, header, recap editor with undo, Outlook draft
   sheet, transcript, playback.
3. `feat/ux-settings-menu`: Settings, menu bar menu, call prompt, recording pill, keyboard and
   accessibility, copy sweep.

## Acceptance

1. With Ollama stopped and This Mac as the default engine, a new meeting waits with "Ollama isn't
   running on This Mac" and its actions; "Write with Claude" produces the recap; starting Ollama
   clears the wait within about 15 seconds.
2. Every channel listed under "Problem model" shows a problem with a title, explanation and
   actions; no raw `Error Domain=` or Swift enum text reaches the interface. This is checked by:
   - tests over the translator's mapping, including `engineNotice`;
   - a test that loads a meeting saved with an old raw failure string and an old raw engine notice;
   - a search of the views for `localizedDescription` and `String(describing:)` on errors.
3. The Activity window lists the session's problems and milestones; "Copy diagnostics" produces
   text with no transcript content, keys, tokens, meeting titles, email addresses or hostnames
   (checked by a test with seeded values of each). Three paths leave none of a seeded transcript
   sentence in the problem, the Activity file or the diagnostics, each checked by a test:
   - an engine error whose response body echoes transcript text;
   - an Ollama `error` message that echoes it;
   - a meeting saved by an earlier version with that text in its raw failure string.
4. A queued meeting shows "Waiting its turn" with its position; the first model download shows
   progress.
5. Playback of a recorded meeting plays both tracks in sync; the highlighted word matches the
   audio within 150 ms at 1× and 2×; clicking a recap source mark plays from that moment.
6. ⌘Z restores a removed bullet, action and subject. A meeting moved to the Trash and put back
   from Finder appears again after a reload, with its recording, transcript and recap intact.
7. Each surface in light and dark passes contrast for its text colours, every icon-only control
   has an accessibility label, and every window works at its minimum size without truncated
   controls.
8. The owner reviews each milestone on his Mac and accepts the look.

## Left to the builder

- SwiftUI or AppKit for each component; the exact layout within the descriptions above.
- The player's audio implementation (for example `AVPlayer` with a composition of the two tracks,
  or `AVAudioEngine`), within the timing requirement.
- The translator's matching details, as long as the table's causes are covered and tested.
- The activity file's rotation mechanics within the retention rule.
