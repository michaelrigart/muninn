# Muninn email recap — design

**Status:** Implemented — [PR #6](https://github.com/michaelrigart/muninn/pull/6)

Follows the transcript speakers work ([design](2026-11-06-muninn-transcript-speakers-design.md)).
The UX pass ([design](2026-11-03-muninn-ux-pass-design.md)) sets the design system, copy style and
accessibility rules, and they apply here unchanged. This design replaces the Outlook draft from
the meeting capture design ([Email](2026-10-22-meeting-capture-design.md#email)) and the UX pass's
"Outlook draft sheet".

## Why

Muninn hands the recap over as an Outlook draft, created through Microsoft Graph. That works only
for a Microsoft 365 mailbox. The owner also wants to send recaps from other mail apps, such as
Proton Mail, which no API can put a draft into. Copying works with every mail app, so it replaces
the draft. The owner chose replacing over offering both, to keep Muninn as simple as possible.

## Goals

- Send a meeting's recap from any mail app: copy the recipients, the subject and the recap, and
  paste each one into the mail app's compose window.
- Keep choosing recipients in Muninn: tick or untick the invite's attendees, search people, or
  type an address.
- The pasted recap keeps its headings, bullets and bold owners in mail apps that accept formatted
  text, and reads cleanly in apps that accept plain text only.
- Remove everything that only the Outlook draft needed.

## Non-goals

- A `mailto:` link, a share sheet, or opening a mail app. Each one breaks for some mail app
  (`mailto:` carries plain text only and has length limits).
- Remembering whether a recap was copied or sent.
- Migrating stored meetings. Nothing has been used on real data yet, so stored draft fields are
  dropped without migration.
- Changing what the recap says (`RecapEmail`'s wording, languages and subject format stay).

## Anti-goals

- Muninn sends email or talks to a mail server. It never did and still doesn't.
- A recap reaches the clipboard with unsourced items without the owner agreeing to include them.
- Accented characters (Dutch, French) come out garbled after pasting.

## Design

### Toolbar

The meeting toolbar's "Outlook draft" becomes **"Email recap"**, with the same `envelope` symbol and
the same place. Its help text: "Copy the recipients, subject and recap into your mail app". No menu item or
keyboard shortcut opens the sheet today, and none is added. It is
unavailable for exactly the reasons "Outlook draft" was (`MeetingCommands.disabledReason`): the
recap isn't ready, there's no recap, unsaved recap edits, an event change in progress, or the event
not chosen yet. `MeetingCommand.outlookDraft` is renamed `emailRecap`.

### Email recap sheet

The sheet keeps today's layout from top to bottom, minus the "From" row and "Create draft". Its
title is "Email recap". Each part has a header row: the part's label on the left, and on the right a
small borderless **Copy** button with the `doc.on.doc` symbol.

1. **Recipients.** As today: "Recipients (N of M)", checkbox rows, and the "Search people or type an
   email address" field (just "Email address" when the meeting has no account), with the same
   people search through Graph. Copy puts the ticked recipients on the clipboard as plain text,
   in list order, separated by ", ":
   - `Name <address>` when there is a name, or just `address` when the name is empty;
   - when the name contains any of `, ; : < > @ " ( ) [ ] \ .` it is quoted:
     `"Peeters, Ann" <ann@example.com>`, with `"` and `\` escaped by a backslash.

   Copy is disabled when nobody is ticked, with the help text "Tick at least one recipient".

   An address can't carry a list separator into the copied line. The check for a typed address
   moves from the sheet into MuninnCore. It accepts an address only when it has exactly one `@`,
   a dot in the domain, no whitespace, and none of `, ; : < > " ( ) [ ] \`. So
   `last,first@example.com` is refused, and the field offers nothing to add. Addresses from the
   invite and from people search pass through the same check when they are added; one that fails
   is left out. The one function serves the typed field, `MeetingActions.addRecipient` (people
   search) and `RecipientBuilder` (the invite). People search hides a result that fails, rather
   than showing it and ignoring the click. `Meeting.attendees` stays unfiltered, so the Obsidian
   note and the client mapping don't change.
2. **Subject.** An editable field, defaulting to `RecapEmail.subject(...)` as today. Copy puts the
   trimmed field text on the clipboard as plain text, and is disabled when the field is blank.
3. **Recap.** A read-only preview that shows exactly what Copy copies, in the same order: greeting,
   intro, each subject's title and bullets, "Action points" with each owner in bold and the due
   date, and the closing. (Today's preview differs from what the draft held.) The preview's text
   can't be selected, so the sheet's only way to copy the recap is its Copy button and the
   check below. (The recap editor stays selectable; it marks unsourced items itself.) Copy runs the
   unsourced-items check first (below), then puts the recap on the clipboard in three
   representations:
   - **HTML:** `RecapEmail.html(...)`, wrapped in a complete document that declares UTF-8;
   - **RTF:** the same content as an attributed string, for native apps that read RTF before HTML;
   - **plain text:** `RecapEmail.plainText(...)` (new), described below.

The footer has one button, **Done** (the default action, unless the recipients field has focus,
as today; Escape also closes). An edit error or an action problem shows as a compact problem card
above the footer, as today.

After a successful copy, that part's button shows a checkmark and "Copied" for about 1.5 seconds,
then goes back to "Copy". VoiceOver announces "Copied". Each Copy button's accessibility label names
its part: "Copy recipients", "Copy subject", "Copy recap". Copying replaces the whole clipboard.
Nothing is written to the meeting, no card appears in the meeting, and nothing is added to Activity.
So copying doesn't run through `AppModel.perform`, which clears the meeting's cards and records
failures. It copies the saved summary that the preview shows.

### Plain-text recap

`RecapEmail.plainText(summary:speakerNames:)` sits next to `html` in MuninnCore and uses the same
copy and order:

```
Hi all,

Thanks for today. Here are the summary and next steps.

Q1 priorities
- Ship the import before the audit

Action points
- Ann: send the revised quote (12/11)

Best regards,
```

A blank line separates blocks, a subject title stands on its own line, bullets start with "- ",
and the due date follows the HTML's rules (`RecapEmail.dueDate`). The owner name resolves through
`speakerNames` as in the HTML. The edge cases match the HTML too: "Action points" appears with
nothing under it when there are no actions, and a subject with no bullets shows just its title.

The HTML document wrapper that declares UTF-8 is also built in MuninnCore (for example
`RecapEmail.htmlDocument(...)`), so a test can pin it.

### Unsourced items

Copying the recap runs the same check as the draft did, `confirmUnsourcedItems`: "N recap items
have no transcript source. Include them anyway?", with Include, Review first and Cancel.
- Include copies the recap.
- Review first closes the sheet and opens the recap editor, and copies nothing.
- Cancel copies nothing.

The check runs on every copy of the recap, and never on copying the recipients or the subject.

### Event changes

A draft used to lock the meeting's event. Copying doesn't, because Muninn can't know whether the
recap was sent. Only a filed Obsidian note locks the event now:
`MeetingActions.canChangeEvent` checks `exportedNotePath` only. The copy that mentions drafts
changes to match:
- "The event can't be changed once a draft or note exists" becomes "The event can't be changed
  once the note is filed";
- "A draft or a note already exists for this meeting." becomes "A note already exists for this
  meeting.";
- "Muninn needs the calendar event before it can draft or file the recap." becomes "Muninn needs
  the calendar event before it can file the recap.";
- "A draft or note is being made" becomes "A note is being filed";
- the sign-in-expired explanation "Sign in again so Muninn can read the calendar and create drafts."
  becomes "Sign in again so Muninn can read the calendar and search people.";
- the add-account question "Name it after the organisation whose calendar and mail it signs in to,
  …" becomes "Name it after the organisation whose calendar it signs in to, …".

Any other user-visible copy or code comment that mentions the draft is updated or removed in the
same way.

### Removed

- `GraphClient.createDraft`, `DraftResult` and the draft response type.
- `Mail.ReadWrite` from `DeviceCodeAuthenticator.scopes`. `People.Read` stays for people search, and
  `Calendars.Read` and `User.Read` stay. A token that was already granted `Mail.ReadWrite` keeps
  working, and nobody has to sign in again.
- `Meeting.draftID` and `Meeting.draftWebLink` (decoding ignores them in old files).
- `AppModel.createDraft`, `DraftOutcome`, `RetryableAction.draft`, the draft-only
  `MeetingActionError` cases (`noRecipients`, `unknownAccount`, `linkNotSaved`, unless something
  else still uses them), the "A draft already exists" question, and the `.draftCreated` success
  card with "Open in Outlook".
- `MeetingCommands.draftRefusal` and `MeetingActions.canDraft`. The sheet no longer needs an
  account; only people search uses the meeting's account.
- `SidebarSign.draftCreated` and its "Draft created" note.
- `ProblemStage.creatingDraft` and everything that maps it (`ProblemTranslator`, `KeychainStore`,
  areas), `Problems.outlookDraftFailed` and `Problems.draftWithoutLink`.
- The tests that covered only these, while tests of what stays keep their coverage.

### Kept

The recipients on the meeting (`Meeting.recipients`, `RecipientBuilder`, `MeetingActions.addRecipient`,
`setIncluded`, how clearing the event keeps hand-added recipients and choosing another event
replaces them), people search
(`GraphClient.searchPeople`, `AppModel.searchPeople`), the meeting's account, and the Graph
calendar.

### Documentation

- `docs/setup.md`: remove the `Mail.ReadWrite` permission row and any step that mentions it; the
  `graph.microsoft.com` firewall row lists "calendar, people". If the page tells people which
  permissions to add, add one sentence saying that an app registered earlier can drop
  `Mail.ReadWrite`.
- `CHANGELOG.md`: nothing has been released yet (only `## [Unreleased]`, no release tags), so the
  Unreleased entries that describe the Outlook draft are rewritten in place: the recap is one "that
  you copy into any mail app", and the Email recap sheet "copies the recipients, the subject and the
  recap, each with its own Copy button, to paste into any mail app". If a release exists by the time
  this ships, add `Changed`/`Removed` entries instead.
- Earlier specs keep their text, since specs are permanent. This spec records what replaced the
  Outlook draft.

## Testing

Core tests pin the logic:
- `RecapEmail.plainText`: the layout above, owner names resolved through `speakerNames`, due dates
  formatted, an invalid due date omitted, and each language's copy.
- The recipients line: names, empty names, quoting and escaping, list order, and only ticked
  recipients.
- The address check: valid addresses pass; `last,first@example.com`, `a;b@example.com`,
  `<a@example.com>`, an address with a space, one with two `@` and one without a dot in the domain
  are refused, both when typed and when added from an event or people search.
- `MeetingCommands.disabledReason(.emailRecap, …)`: the same reasons as the old command.
- `MeetingActions.canChangeEvent`: false once a note is filed, true otherwise.
- `DeviceCodeAuthenticator.scopes` does not contain `Mail.ReadWrite`.
- `SidebarSign` without the draft sign.
- The HTML document declares UTF-8 and keeps accented text ("Réunion", "één") unescaped.
- Graph's error handling keeps its coverage: the 403 test that called `createDraft` moves to a GET
  endpoint. `GraphClient.send`'s POST and body parameters go if nothing else uses them.

The app target has no test target, so the pasteboard writing is checked by hand. The check runs on
a Debug build, with a meeting whose recap has accents in a subject ("Réunion", "één"). Paste each
part into Apple Mail, into Proton Mail (web or app), into Gmail on the web, and into TextEdit in
both rich-text and plain-text mode. Confirm that the headings, bullets and bold owners appear, the
accents survive, rich-text TextEdit gets the RTF, and plain-text TextEdit gets the plain text. The
Proton Mail and Gmail pastes need the owner's accounts, so the owner does them before merge.

## Calls made in this design

The owner chose replacing the draft, keeping recipient editing, and a Copy button per part. These
calls were made for the owner, who can review them:
- The preview shows exactly what gets copied, where today it differs from the draft, and its text
  can't be selected.
- Addresses with list separators or angle brackets are refused wherever a recipient is added.
- The unsourced-items check stays, and runs on every copy of the recap.
- Copying doesn't lock the event, and Muninn records nothing about it (no card, no sidebar sign,
  no Activity entry).
- The recipients format is `Name <address>`, quoted when needed.
- The recap is copied as HTML, RTF and plain text.
- The changelog is rewritten in place, because nothing has been released.

## Left to the builder

Where the pasteboard code lives in the app target, how the RTF is produced, whether the preview
draws from the same structure or from the HTML, the "Copied" timing and animation, and whether
`DraftSheet.swift` is renamed (to `EmailRecapSheet.swift`, preferred).
