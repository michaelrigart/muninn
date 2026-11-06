# Muninn transcript speakers — design

**Status:** In progress — [PR #5](https://github.com/michaelrigart/muninn/pull/5)

Follows the UX pass ([design](2026-11-03-muninn-ux-pass-design.md)), after its pull request 2 (the
Meetings window). Its design system, copy style, accessibility rules and constraints apply here
unchanged.

## Why

Speaker attribution is automatic and sometimes wrong: a line said by one person is put under
another, or the mic picks up the other side of a call and files it under "You". Today the owner can
only rename a speaker, which changes every line with that label. A meeting without a calendar event
also shows nobody in its header, so the owner doesn't see who Muninn thinks took part, and doesn't
find out that clicking a name in the transcript renames that speaker.

## Goals

- Move one transcript line, or a run of lines, to another speaker or to a new one.
- Make clear that clicking a speaker's name renames that speaker everywhere.
- Show a meeting's speakers in the header when it has no calendar event.

## Non-goals

- Splitting a line between two speakers, or moving words within a line.
- Linking transcript speakers to calendar attendees.
- Rewriting the recap, or an exported Obsidian note, after a speaker change. Regenerating the recap
  stays a separate action.
- Undo (⌘Z) for speaker changes and renames.

## Anti-goals

- A speaker change that alters the audio, the timings, the words or the recap.
- Other speakers' colours shifting because one line moved.

## Decisions (owner's, 2026-11-06)

- **Change speaker.** Right-click a line, or a selection across several lines, and choose
  "Change speaker ▸". The submenu lists the meeting's speakers by their shown names, with a tick
  on the current speaker when every chosen line has the same one, then "New speaker". Only the
  chosen lines change: the transcript's names and colours, the player's speaker lanes and the
  transcript files follow. Lines can move between "You" and the call side.
- **New speaker** adds the next unnamed speaker, which the owner names with the existing rename.
- **Rename everywhere.** Clicking a speaker's name still renames that speaker on every line; the
  rename popover's title says so ("Rename S2 everywhere").
- **The recap is not rewritten**, and there is no ⌘Z: a line moves back through the same menu.
- **Speakers in the header.** A meeting with no attendees (no calendar event) shows its speakers
  where the attendee chips would be: one chip per speaker in its transcript colour, with its shown
  name. Clicking a chip opens the same "Rename … everywhere" popover. A meeting with attendees
  keeps showing them as today.

## Behaviour

### Which lines a change applies to

A line is one transcript segment. With a non-empty selection, the change applies to every segment
the selection touches, including one it covers only partly. With no selection, it applies to the
segment under the pointer. When the menu is opened from the keyboard or VoiceOver (off the text),
the segment holding the insertion point is used, as "Rename speaker…" does today. The menu doesn't
offer "Change speaker" when the pointer is on no segment (a speaker name line counts as no
segment). In the Clean view, segments the clean transcript leaves out are not shown, so a
selection never touches them.

### The menu's speakers

"You" is always offered, also in a mic-only (in-person) meeting, where no line starts as "You" and
the owner can mark their own lines. Every `S` label that has lines is offered, by its shown name;
two speakers with the same shown name are told apart by their label ("Sarah (S2)"). Then "New
speaker".

### Speaker labels

Transcript labels are `you` and `S1`, `S2`, … ("S" plus a number, as speaker attribution creates
them). "New speaker" takes `S` plus one more than the highest `S` number found in the transcript's
labels, the keys of the meeting's `speakerNames`, and the action owners of the current and the
previous recap. A new speaker therefore never takes a label that still carries meaning: a stored
name it would arrive with, or a recap action whose owner would turn into the new person in a draft
or note. A label that nothing refers to any more (a new speaker moved away before it was named or
used in a recap) can be taken again, which is harmless. An `S` label left with no lines disappears
from the menu and the header; its stored name stays.

### Colours

Today "you" is colour 0 and other speakers take colours 1 to 5 in order of first appearance, so
moving the first line of S2 can swap S2's and S3's colours. From now on an `S<n>` label takes
colour `1 + (n − 1) mod 5`, which stays the same whatever moves. Speaker attribution numbers labels
in order of first appearance, so freshly processed meetings look as before. A label that isn't
`you` or `S<n>` (none exist today) keeps the first-appearance rule, after the numbered ones.

### When a change is allowed

The same rule as Move to Trash: speaker changes are refused while the meeting is recording,
transcribing, diarizing, cleaning or summarizing, and while the pipeline has a job for it (queued,
or waiting for an engine). The pipeline reads the transcript when a job starts and writes the clean
Markdown and the recap from that copy, so a change made meanwhile would be missed by both. A
refused menu item is shown disabled, with its reason as a tooltip. Renaming keeps today's rules.

### Saving

A change sets the speaker of the chosen segments and nothing else; a segment's track says where its
audio is, so a moved line stays in its lane of the player and takes its new speaker's colour. The
clean transcript is keyed by segment and needs no change.

Who said each line lives in `transcript.json`; what each speaker is called lives in the meeting's
`speakerNames` (`meeting.json`). The Markdown files (`transcript.md`, and the clean one when a
clean transcript exists) are derived from both and only rewritten after them. Today
`saveTranscript` writes the Markdown before `transcript.json`; that order changes.

- **A speaker change** commits when `transcript.json` is written, by atomic replacement. If that
  write fails, nothing changed: the Markdown files are not touched, the view keeps the transcript
  as it was, and the usual problem card ("Couldn't save your changes") is shown and recorded in
  Activity.
- **A rename** commits when `speakerNames` is saved, as today; `transcript.json` holds no names and
  is not rewritten. If saving `speakerNames` fails, nothing changed and the same problem card is
  shown.
- **After either commits**, the Markdown files are rewritten. If one fails, the change stands in
  Muninn (the view, the player, drafts, notes and later recaps use `transcript.json` and
  `speakerNames`). The problem card says the transcript files couldn't all be updated, is recorded
  in Activity, and its "Try again" rewrites the Markdown files from `transcript.json` and
  `speakerNames`. Any later speaker change or rename rewrites them too.

The meeting view, the player's lanes and colours, and the header chips update once the change
commits.

### Header speaker chips

Shown only when the meeting has no attendees other than rooms and resources, and has a transcript.
Order: "You" first when present, then by label number. All speakers are shown, wrapping like the
attendee chips. A chip shows a dot in the speaker's colour and the shown name; its accessibility
label is the shown name and its help text is "Rename this speaker everywhere".

## Calls made in writing this up

The owner approved the decisions above; these details were settled while writing them down:

- a partly selected line counts as chosen;
- new labels take the highest `S` number found in the transcript, the stored names and the action
  owners of the current and previous recap, plus one, so no label that still carries meaning is
  reused;
- "You" is always on the menu, also in in-person meetings;
- colours follow the label number instead of first appearance;
- changes are refused while the meeting is being processed or has a pipeline job, as Move to Trash
  is;
- a moved line keeps its track (its lane in the player);
- a speaker change commits with `transcript.json` and a rename with `speakerNames`; the Markdown
  files are rewritten only after that, and a failed Markdown write keeps the change and offers
  "Try again";
- the header lists "You" first, then by label number, all of them.

## Constraints

- Everything with rules lives in MuninnCore and is unit tested: applying a speaker change to a
  transcript, the next label, the menu's and the header's speaker lists and their order, the colour
  rule, when a change is allowed (status and pipeline job) with its refusal reason, and the
  save order for a speaker change and a rename with their failure cases (commit fails; a Markdown
  file fails after the commit).
- MuninnCore stays dependency-free. Swift 5 language mode.
- Copy follows the UX pass: sentence case, "…" only where more input follows, no full stop in
  titles.
- Each test names the behaviour it pins and fails without the code.

## Acceptance

1. Right-click one line and choose another speaker: only that line changes, in the transcript, the
   player's lanes and the files; it survives View › Reload and a relaunch.
2. Select across three lines and change their speaker: all three change.
3. "New speaker" creates the next `S` label; renaming it changes only its lines.
4. Moving a line doesn't change any other speaker's colour.
5. While a meeting is being processed or waits for an engine, "Change speaker" is disabled and says
   why.
6. In an in-person meeting, lines can be marked "You"; in a call, moving the last "You" line away
   and back works.
7. A meeting without a calendar event shows its speakers in the header; clicking one renames that
   speaker everywhere. A meeting with an event shows its attendees as before.
8. The rename popover says "everywhere".

## Left to the builder

- Where the speaker-change logic lives in MuninnCore and how the app calls it.
- The exact chip layout, within the design system.
- How the transcript view keeps its scroll position and read-along state across a change (it must
  not jump).
