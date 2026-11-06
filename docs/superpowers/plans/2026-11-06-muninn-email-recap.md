# Muninn email recap — Implementation Plan

**Status:** In progress — [PR #6](https://github.com/michaelrigart/muninn/pull/6)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Outlook draft with an "Email recap" sheet that copies the recipients, the subject and the recap (HTML, RTF and plain text) for any mail app, and remove everything only the draft needed.

**Architecture:** MuninnCore gains the address check, the recipients line, and one recap structure (`RecapEmail.Content`) that the HTML, the plain text and the sheet's preview all render, so the preview always matches what is copied. The app renames the toolbar command and rewrites the sheet around three Copy buttons that write to `NSPasteboard`; the RTF is converted from the HTML document. Then the draft action, the Graph draft call, `Mail.ReadWrite`, the draft fields on `Meeting` and the draft lock on the event are removed, with the copy that mentioned drafts.

**Tech Stack:** Swift 5 language mode, SwiftUI and AppKit (macOS 26), Swift Testing, XcodeGen.

**Spec:** [docs/superpowers/specs/2026-11-06-muninn-email-recap-design.md](../specs/2026-11-06-muninn-email-recap-design.md)

## Global Constraints

- `MuninnCore` stays dependency-free; Swift 5 language mode in every target; tests use Swift Testing.
- In the app target, the settings type is `MuninnCore.Settings`.
- Every user-visible string the spec quotes is used verbatim, curly apostrophes excepted: the codebase writes `'` (for example "There's no recap yet").
- Disabled controls say why in their help text (UX pass, rule 6).
- Run every build and test command outside the agent sandbox, prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`:
  - Core: `swift test --package-path Packages/MuninnCore` (focused: add `--filter <TestSuite>`)
  - Platform: `swift test --package-path Packages/MuninnPlatform`
  - App: `mise exec -- xcodegen generate`, then `xcodebuild -project Muninn.xcodeproj -scheme Muninn -configuration Debug -derivedDataPath build -quiet build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`
- The app target has no test target: app changes are verified by the Debug build, and the pasteboard by the manual checks at the end.
- Batching: every task compiles `MuninnCore` (one module, one `.build`), so no two tasks run in the same batch; run them in order.

## Review Focus

1. **HTML-special characters in the recap** (`R&D <beta> "q"`): the HTML escapes them and the plain text keeps them literal. Pinned in Task 2.
2. **A recipient name that is only whitespace**: the line shows the bare address, not `  <ann@example.com>`. Pinned in Task 1.
3. **A typed address with spaces around it** (`"  ann@example.com "`): trimmed and accepted, while a space inside it is refused. Pinned in Task 1.
4. **Accented names and international addresses** (`Zoë Peeters`, `zoë@exämple.be`): accepted, and the name is not quoted. Pinned in Task 1.
5. **A recap with no subjects**: the plain text still reads greeting, intro, "Action points", closing. Pinned in Task 2.

---

### Task 1: The address check and the recipients line

**Depends on:** none

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Email/EmailRecipients.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Calendar/RecipientBuilder.swift` (`recipients(for:selfAddresses:)`)
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Pipeline/MeetingActions.swift` (`addRecipient` only)
- Create: `Packages/MuninnCore/Tests/MuninnCoreTests/EmailRecipientsTests.swift`
- Modify: `Packages/MuninnCore/Tests/MuninnCoreTests/CalendarTests.swift`, `Packages/MuninnCore/Tests/MuninnCoreTests/MeetingPreparationTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum EmailRecipients {
      /// Exactly one "@", a dot in the domain, no whitespace, none of , ; : < > " ( ) [ ] \
      public static func isValidAddress(_ address: String) -> Bool
      /// The typed text, trimmed, as a recipient without a name; nil unless it is a valid address.
      public static func typedAddress(_ text: String) -> Attendee?
      /// The ticked recipients, in list order, as "Name <address>" or "address", joined by ", ".
      public static func line(_ recipients: [Recipient]) -> String
  }
  ```

- [ ] **Step 1: Write the failing tests** in `EmailRecipientsTests.swift` (`struct EmailRecipientsTests`):

```swift
@Test(arguments: ["ann@example.com", "ann.peeters+recap@mail.example.be", "zoë@exämple.be"])
func validAddressesPass(_ address: String) { #expect(EmailRecipients.isValidAddress(address)) }

@Test(arguments: [
    "last,first@example.com", "a;b@example.com", "<a@example.com>", "ann peeters@example.com",
    "a@b@example.com", "ann@example", "ann@", "@example.com", "ann:x@example.com",
    #""ann"@example.com"#, "ann(x)@example.com", "ann[x]@example.com", #"ann\x@example.com"#, "ann@example.com\n",
])
func addressesThatCouldBreakTheLineAreRefused(_ address: String) { #expect(!EmailRecipients.isValidAddress(address)) }

@Test func typedAddressIsTrimmedAndChecked() {
    #expect(EmailRecipients.typedAddress("  ann@example.com \n") == Attendee(name: "", email: "ann@example.com"))
    #expect(EmailRecipients.typedAddress("last,first@example.com") == nil)
    #expect(EmailRecipients.typedAddress("ann peeters@example.com") == nil)
    #expect(EmailRecipients.typedAddress("ann") == nil)
}

@Test func lineFormatsQuotesAndEscapesNames() {
    let recipients = [
        Recipient(attendee: Attendee(name: "Ann Peeters", email: "ann@example.com"), included: true),
        Recipient(attendee: Attendee(name: "", email: "bob@example.com"), included: true),
        Recipient(attendee: Attendee(name: "Carl", email: "carl@example.com"), included: false),
        Recipient(attendee: Attendee(name: "Peeters, Ann", email: "ann2@example.com"), included: true),
        Recipient(attendee: Attendee(name: #"Ann "Boss" \ P"#, email: "boss@example.com"), included: true),
        Recipient(attendee: Attendee(name: "Dr. Who", email: "who@example.com"), included: true),
        Recipient(attendee: Attendee(name: "   ", email: "blank@example.com"), included: true),
        Recipient(attendee: Attendee(name: "Zoë Peeters", email: "zoe@example.be"), included: true),
    ]
    #expect(EmailRecipients.line(recipients) == #"Ann Peeters <ann@example.com>, bob@example.com, "Peeters, Ann" <ann2@example.com>, "Ann \"Boss\" \\ P" <boss@example.com>, "Dr. Who" <who@example.com>, blank@example.com, Zoë Peeters <zoe@example.be>"#)
}

@Test func lineIsEmptyWhenNobodyIsTicked() {
    #expect(EmailRecipients.line([Recipient(attendee: Attendee(name: "Ann", email: "ann@example.com"), included: false)]) == "")
}
```

In `CalendarTests`, `recipientsLeaveOutUnusableAddresses`: an event (built with the file's `event(attendees:organizer:)` helper) with attendees `ann@example.com`, `last,first@example.com` and `<bob@example.com>` gives recipients `["ann@example.com"]`.

In `MeetingPreparationTests`, `addRecipientRefusesAnUnusableAddress`: `MeetingActions.addRecipient(Attendee(name: "X", email: "a;b@example.com"), to: prepare(.none), selfAddresses: [])` leaves `recipients` empty.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path Packages/MuninnCore --filter 'EmailRecipientsTests|CalendarTests|MeetingPreparationTests'`
Expected: build failure, `EmailRecipients` not found.

- [ ] **Step 3: Implement `EmailRecipients`, and gate `RecipientBuilder.recipients` and `MeetingActions.addRecipient` on `isValidAddress`**

`isValidAddress` matches the whole string against `\A[^\s@,;:<>"()\[\]\\]+@[^\s@,;:<>"()\[\]\\]+\.[^\s@,;:<>"()\[\]\\]+\z` (the old sheet regex with the list separators added; `\A…\z`, because ICU's `$` also matches before a final newline). `line`: trim each name of whitespace and newlines; an empty name gives the bare address; a name containing any of `, ; : < > @ " ( ) [ ] \ .` is wrapped in `"…"` after escaping `\` as `\\` and then `"` as `\"`. `RecipientBuilder` skips an attendee whose address fails, like a resource; `addRecipient` returns the meeting unchanged. `Meeting.attendees` is not filtered.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/MuninnCore
git commit -m "Check recipient addresses and build the copied recipients line in MuninnCore"
```

---

### Task 2: One recap structure, rendered as HTML, plain text and an HTML document

**Depends on:** none

**Files:**
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Email/RecapEmail.swift`
- Modify: `Packages/MuninnCore/Tests/MuninnCoreTests/RecapEmailTests.swift`

**Interfaces:**
- Produces:
  ```swift
  extension RecapEmail {
      public struct Item: Equatable, Sendable { public var owner: String?; public var text: String }
      public struct Section: Equatable, Sendable { public var title: String; public var items: [Item] }
      public struct Content: Equatable, Sendable {
          public var greeting: String; public var intro: String; public var sections: [Section]; public var closing: String
      }
      /// One section per subject (its bullets, owner nil), then the actions section: the language's heading, and each
      /// subject's actions in order, owner resolved through speakerNames, text with " (dd/MM)" when the due date is valid.
      public static func content(summary: Summary, speakerNames: [String: String]) -> Content
      public static func plainText(summary: Summary, speakerNames: [String: String]) -> String
      public static func htmlDocument(summary: Summary, speakerNames: [String: String]) -> String
  }
  ```
  `html(summary:speakerNames:)`, `subject(...)` and `dueDate(_:)` keep their signatures and output.

- [ ] **Step 1: Write the failing tests** in `RecapEmailTests` (reuse `Self.summary(...)`):

```swift
@Test func contentOrdersSubjectsThenActions() {
    var s = Self.summary(language: "en", owner: "S1", due: "2026-11-12")
    s.subjects.append(Subject(title: "Hiring", bullets: [], actions: [ActionPoint(owner: "Kim", text: "Post the job", due: nil, sources: [1])]))
    #expect(RecapEmail.content(summary: s, speakerNames: ["S1": "Ann"]) == RecapEmail.Content(
        greeting: "Hi all,", intro: "Thanks for today. Here are the summary and next steps.",
        sections: [
            .init(title: "Pricing", items: [.init(owner: nil, text: "Agreed on tiers")]),
            .init(title: "Hiring", items: []),
            .init(title: "Action points", items: [.init(owner: "Ann", text: "Send quote (12/11)"), .init(owner: "Kim", text: "Post the job")]),
        ],
        closing: "Best regards,"
    ))
}

@Test func plainTextLayout() {
    let s = Self.summary(language: "en", title: "Q1 priorities", bullet: "Ship the import before the audit", owner: "S1", action: "send the revised quote", due: "2026-11-12")
    #expect(RecapEmail.plainText(summary: s, speakerNames: ["S1": "Ann"]) == """
    Hi all,

    Thanks for today. Here are the summary and next steps.

    Q1 priorities
    - Ship the import before the audit

    Action points
    - Ann: send the revised quote (12/11)

    Best regards,
    """)
}
```

Also, each as its own `@Test`:
- `plainTextOmitsAnInvalidDueDate`: due `"2026-13-40"` gives the line `- Jan: Send quote` with no parentheses.
- `plainTextCopyPerLanguage`: `nl` contains `Hallo allemaal,`, `Actiepunten`, `Met vriendelijke groeten,`; `fr` contains `Merci pour l'échange.` and `Points d'action` unescaped; `de` falls back to `Hi all,` and `Best regards,`.
- `plainTextEdgeCases`: a subject with no bullets is its title alone, followed by a blank line; with no actions, `Action points\n\nBest regards,`; a summary with no subjects is exactly `"Hi all,\n\nThanks for today. Here are the summary and next steps.\n\nAction points\n\nBest regards,"`.
- `plainTextKeepsSpecialCharactersLiteral`: bullet `R&D <beta> "q"` appears as `- R&D <beta> "q"`.
- `htmlDocumentDeclaresUTF8AndKeepsAccents`: with title `Réunion` and bullet `één afspraak`, the document starts with `<!DOCTYPE html>`, contains `<meta charset="utf-8">`, contains `<h3>Réunion</h3>` and `<li>één afspraak</li>`, contains `RecapEmail.html(...)` of the same summary, and ends with `</html>`.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path Packages/MuninnCore --filter RecapEmailTests`
Expected: build failure, `content`/`plainText`/`htmlDocument` not found.

- [ ] **Step 3: Implement `content`, then make `html` render it, and add `plainText` and `htmlDocument`**

`html` renders `content`: `<p>` greeting and intro, per section `<h3>` title and a `<ul>` (empty when the section has no items) of `<li>` items, an owned item as `<b>owner</b>: text`, then `<p>` closing; every text escaped, lines joined by `\n`. The existing HTML tests must pass unchanged. `plainText` joins blocks with a blank line: greeting, intro, each section (title, then `- ` + item lines, an owned item as `owner: text`), closing; no trailing newline. `htmlDocument` is exactly:

```
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
</head>
<body>
\(html(summary:speakerNames:))
</body>
</html>
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command. Expected: PASS, including the existing `dutchCopy`, `frenchAndFallbackCopy` and `escapesHTML`.

- [ ] **Step 5: Commit**

```bash
git add Packages/MuninnCore
git commit -m "Render the recap email from one structure as HTML, plain text and a UTF-8 document"
```

---

### Task 3: The Email recap sheet and toolbar command

**Depends on:** Task 1, Task 2

**Files:**
- Rename: `Muninn/Meetings/DraftSheet.swift` → `Muninn/Meetings/EmailRecapSheet.swift` (`git mv`; struct `EmailRecapSheet`)
- Create: `Muninn/Meetings/RecapPasteboard.swift`
- Modify: `Muninn/Meetings/MeetingToolbar.swift`, `Muninn/Views/MeetingDetail.swift`, `Muninn/AppModel+Meetings.swift` (`confirmUnsourcedItems` only)
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Presentation/MeetingCommands.swift` (rename the case only)
- Modify: `Packages/MuninnCore/Tests/MuninnCoreTests/MeetingCommandsTests.swift`

**Interfaces:**
- Consumes: `EmailRecipients.typedAddress`, `.isValidAddress`, `.line` (Task 1); `RecapEmail.content`, `.plainText`, `.htmlDocument` (Task 2).
- Produces: `MeetingCommand.emailRecap` (was `outlookDraft`); `EmailRecapSheet(meeting:summary:)`; `@MainActor enum RecapPasteboard { static func copy(_ text: String); static func copyRecap(_ summary: Summary, speakerNames: [String: String]) }`.

- [ ] **Step 1: Rename the command in the test first**: in `MeetingCommandsTests.exportReasons`, `[MeetingCommand.outlookDraft, .obsidian]` becomes `[MeetingCommand.emailRecap, .obsidian]` (same reasons as the old command). Run `swift test --package-path Packages/MuninnCore --filter MeetingCommandsTests`; expected: build failure, no member `emailRecap`.

- [ ] **Step 2: Rename `MeetingCommand.outlookDraft` to `emailRecap`** in `MeetingCommands.swift` (the `disabledReason` branch is unchanged). Run the Step 1 command; expected: PASS.

- [ ] **Step 3: Write `RecapPasteboard`**

`copy(_:)` clears `NSPasteboard.general` and sets the string as `.string`. `copyRecap` builds one `NSPasteboardItem` with `.html` (`Data(htmlDocument.utf8)`), `.rtf` and `.string` (`plainText`), clears the pasteboard and writes the item. The RTF: import the HTML document with `NSAttributedString(data:options: [.documentType: .html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)`, replace each font run with `NSFont.systemFont(ofSize:)` of the same size keeping its bold trait (so it isn't Times), then `rtf(from:documentAttributes:)`. If the RTF can't be made, write the HTML and the plain text without it.

- [ ] **Step 4: Rewrite the sheet** (`EmailRecapSheet`), keeping today's layout minus the "From" row and "Create draft":
- Title `Text("Email recap")`. Each part has a header row: its `SectionLabel` on the left, a Copy button on the right.
- A private `CopyButton(part:help:disabledReason:copy:)` view: borderless, small, `Label("Copy", systemImage: "doc.on.doc")`; when `copy()` returns true it shows `Label("Copied", systemImage: "checkmark")` for 1.5 seconds (a copy counter as the `.task(id:)` key, so a second copy restarts the timer) and posts `AccessibilityNotification.Announcement("Copied")`. `.accessibilityLabel("Copy \(part)")`, `.disabled(disabledReason != nil)`, `.help(disabledReason ?? help)`.
- **Recipients**: label "Recipients (N of M)" as today; Copy (`part: "recipients"`, help "Copy the recipients", disabled reason "Tick at least one recipient" when none is ticked) runs `RecapPasteboard.copy(EmailRecipients.line(meeting.recipients))`. In `RecipientsEditor`, `manual` becomes `EmailRecipients.typedAddress(query)`, and `candidates` drops search results whose address fails `EmailRecipients.isValidAddress`. Field placeholders, search and checkbox rows stay.
- **Subject**: Copy (`part: "subject"`, help "Copy the subject", disabled reason "Type a subject" when the trimmed field is empty) copies the trimmed field text.
- **Recap**: a non-selectable preview of `RecapEmail.content(summary:speakerNames: meeting.speakerNames)` in the same order as the copy: greeting, intro, each section's title (`Theme.subject`) and its items as `• text`, an owned item as `• **owner**: text` with the owner in bold, then closing; "There's no recap yet" when `summary` is nil. Copy (`part: "recap"`, help "Copy the recap", disabled reason "There's no recap yet" when `summary` is nil) asks `model.confirmUnsourcedItems(MeetingActions.unsourcedItemCount(in: summary), for: meeting.id)`: `.include` → `RecapPasteboard.copyRecap(summary, speakerNames: meeting.speakerNames)` and returns true; `.review` → `dismiss()` and returns false; `.cancel` → returns false.
- Problem cards (edit error, `model.actionErrors`) stay above the footer as today.
- Footer: one `Button("Done") { dismiss() }` with `.keyboardShortcut(recipientsFocused ? nil : .defaultAction)`; the root view gets `.onExitCommand { dismiss() }` so Escape closes.
- Copying calls no `AppModel.perform`, writes nothing to the meeting and records no Activity entry. Update the type's doc comment.

- [ ] **Step 5: Wire it up**
- `MeetingToolbar`: `openDraft` → `openEmailRecap`; `Label("Email recap", systemImage: "envelope")`; `.disabled(reason != nil)`; `.help(reason ?? "Copy the recipients, subject and recap into your mail app")` with `reason = MeetingCommands.disabledReason(.emailRecap, context)`.
- `MeetingDetail`: `showingDraft` → `showingEmailRecap`; `.sheet(isPresented: $showingEmailRecap) { EmailRecapSheet(meeting: meeting, summary: summary) }`.
- `AppModel.confirmUnsourcedItems`: explanation "They are marked in the recap editor. Nothing is copied or filed unless you include them."; doc comment "Before a recap leaves Muninn (copied or filed)".

- [ ] **Step 6: Build**

Run: `mise exec -- xcodegen generate`, then the Debug build from Global Constraints. Expected: `** BUILD SUCCEEDED **` (with `-quiet`: no errors, exit 0). `createDraft` still exists; nothing calls it now.

- [ ] **Step 7: Commit**

```bash
git add -A Muninn Packages/MuninnCore
git commit -m "Replace the Outlook draft sheet with the Email recap sheet"
```

---

### Task 4: Remove the draft action, the Graph draft call and Mail.ReadWrite

**Depends on:** Task 3

**Files:**
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Graph/GraphClient.swift`, `Graph/DeviceCodeAuthenticator.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Problems/Problem.swift`, `Problems/Problems.swift`, `Problems/ProblemTranslator.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Presentation/MeetingCommands.swift`, `Pipeline/MeetingActions.swift`
- Modify: `Packages/MuninnPlatform/Sources/MuninnSystem/KeychainStore.swift`
- Modify: `Muninn/AppModel+Meetings.swift`, `Muninn/AppModel.swift` (comments), `Muninn/Views/MeetingDetail.swift`, `Muninn/Views/SettingsView.swift`
- Test: `GraphTests.swift`, `ProblemTests.swift`, `ProblemTranslatorTests.swift`, `MeetingCommandsTests.swift`, `MeetingPreparationTests.swift` (all in `Packages/MuninnCore/Tests/MuninnCoreTests/`)

**Interfaces:**
- Produces: `DeviceCodeAuthenticator.scopes == ["offline_access", "User.Read", "Calendars.Read", "People.Read"]`; `MeetingActionError.exportInProgress` (was `draftOrExportInProgress`); `AppModel.RetryableAction` has only `.note`; `ActionSuccess` has only `.filed(URL)`.

- [ ] **Step 1: Change the tests first**
- `GraphTests`: both expected `scope` strings become `"offline_access User.Read Calendars.Read People.Read"`; add `@Test func scopesLeaveOutMailReadWrite() { #expect(!DeviceCodeAuthenticator.scopes.contains("Mail.ReadWrite")) }`; delete `draftRequestShape`; `graphHTTPErrorKeepsOnlyAKnownCode` calls `try await Self.client().searchPeople("x")` and expects `.http(status: 403, code: code, request: Self.graphRequest)` (the GET `/v1.0/me/people` facts).
- `ProblemTranslatorTests`: drop `.creatingDraft` from `connectionWithoutAnEngineAtAMicrosoftStage`'s arguments; `graphErrorWhileDrafting` becomes `graphErrorDetails` at `.readingCalendar` with `RequestFacts(method: "GET", path: "/v1.0/me/calendarView", host: "graph.microsoft.com")`, expecting the title "Muninn couldn't read the Work calendar" and the same detail assertions; in `graphErrorAtAnotherStageIsGeneric` the decoding case uses `.searchingPeople` ("Something went wrong while searching for people"); `microsoftUnreachableWhileDrafting` becomes `microsoftUnreachableWhileSearchingPeople` at `.searchingPeople`.
- `ProblemTests`: remove `outlookDraftFailed()` and `draftWithoutLink()` from every list; `stagePhrasesAndAreas` asserts `ProblemStage.searchingPeople.area == .outlook`; add `#expect(Problems.signInExpired(account: "Work").explanation == "Sign in again so Muninn can read the calendar and search people.")`.
- `MeetingCommandsTests`: delete `draftRefusalNamesWhatIsMissing`.
- `MeetingPreparationTests`: delete `canDraftRequiresAccountAndRecipient` and `noEventToDraftable`; `aMeetingWhoseAccountWasRemovedCannotDraft` becomes `accountRemovedNamesAMissingAccount`, keeping only its `accountRemoved` and `accountRemovedLabel` assertions.

Run `swift test --package-path Packages/MuninnCore --filter 'GraphTests|ProblemTests|ProblemTranslatorTests'`; expected: the scope and sign-in tests fail.

- [ ] **Step 2: Remove from MuninnCore and MuninnPlatform**
- `GraphClient`: delete `DraftResult`, `DraftResponse` and `createDraft`; `send(_ url: URL, extraHeaders: [String: String] = [:])` loses `method` and `body` (the request is a GET, `RequestFacts(method: "GET", url: url)`).
- `DeviceCodeAuthenticator.scopes`: drop `"Mail.ReadWrite"`.
- `ProblemStage.creatingDraft` and its `phrase`/`area` cases; its entries in `ProblemTranslator` (the Microsoft connection stages and the `(.http, .creatingDraft)` case) and `KeychainError.problem(in:)`.
- `Problems.outlookDraftFailed` and `Problems.draftWithoutLink`; `signInExpired`'s explanation becomes "Sign in again so Muninn can read the calendar and search people."
- `MeetingCommands.draftRefusal` and `MeetingActions.canDraft`; `accountRemoved`'s comment no longer mentions drafting.

- [ ] **Step 3: Remove from the app**
- `AppModel+Meetings`: delete `ActionSuccess.draftCreated`, `DraftOutcome`, `createDraft`, `RetryableAction.draft` and its `retryAction` branch, `MeetingActionError.noRecipients` and `.linkNotSaved`. `draftOrExportInProgress` → `exportInProgress`: `warning("A note is being filed", "Change the event once it has finished.")`; `isDraftOrExportRunning` → `isExportRunning`, checking `.filingNote` only. `eventUnsettled`'s explanation becomes "Muninn needs the calendar event before it can file the recap." Comments that say draft say note or export instead.
- `AppModel.swift`: the comments on `actionErrors`, `actionSuccesses`, `failedActions` and `eventChangesInFlight` drop "draft".
- `MeetingDetail.successCard`: drop the `.draftCreated` case ("Draft created", "Open in Outlook").
- `SettingsView` add-account question: "Name it after the organisation whose calendar it signs in to, for example Work or Acme."

- [ ] **Step 4: Verify**

Run the Core suite, the Platform suite, then `xcodegen generate` and the Debug build. Expected: all pass; build succeeds.

- [ ] **Step 5: Commit**

```bash
git add -A Muninn Packages
git commit -m "Remove the Outlook draft action, the Graph draft call and Mail.ReadWrite"
```

---

### Task 5: Drop the draft fields and the draft lock on the event

**Depends on:** Task 4

**Files:**
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Model/Meeting.swift`, `Pipeline/MeetingActions.swift`, `Pipeline/MeetingPreparation.swift`, `Presentation/SidebarSign.swift`, `Problems/Problems.swift`
- Modify: `Packages/MuninnPlatform/Sources/MuninnSpike/Commands/EndToEnd.swift`, `Commands/Summarize.swift`
- Modify: `Muninn/Meetings/Sidebar.swift`, `Muninn/Meetings/HeaderChips.swift`
- Test: `ModelTests.swift`, `RecordingGuardTests.swift`, `MeetingPreparationTests.swift`, `PresentationTests.swift`, `ProblemTests.swift`, and every test that passes `draftWebLink: nil` (`AccountManagementTests`, `ActivityTests`, `MeetingCommandsTests`, `NotePlannerTests`, `ObsidianTests`, `PipelineTests`, `ProcessingDisplayTests`, `StorageTests`, `SummaryTests`, `TranscriptSpeakersTests`)

**Interfaces:**
- Produces: `Meeting` without `draftWebLink` and `draftID` (properties, init parameters, decoding); `SidebarSign` without `.draftCreated`; `MeetingActions.canChangeEvent(m) == (m.exportedNotePath == nil)`.

- [ ] **Step 1: Change the tests first**
- `ModelTests.draftIDRoundTripsAndOlderFilesDecode` becomes `olderFilesWithDraftFieldsDecode`: encode a meeting with `StorageJSON`'s encoder, add `"draftID": "AAMk-draft"` and `"draftWebLink": "https://outlook.test/d"` to the JSON object, decode it, and expect the decoded meeting to equal the original; re-encoding it has neither key.
- `RecordingGuardTests.eventCanChangeUntilADraftOrExportExists` becomes `eventCanChangeUntilANoteIsFiled`: true for a ready meeting, false once `exportedNotePath = "a.md"`.
- `MeetingPreparationTests.aFetchedEventIsAppliedOnlyWhileNoDraftOrNoteExists` becomes `aFetchedEventIsAppliedOnlyWhileNoNoteExists`, keeping the applied and `exported` cases.
- `PresentationTests`: the `meeting(...)` helper loses `draftID`; `sign(for: meeting(exportedNotePath: "n.md"), …) == .filed` stays and the `.draftCreated` expectation goes.
- `ProblemTests`: add `#expect(Problems.eventNotChanged().explanation == "A note already exists for this meeting.")`.
- Remove `draftWebLink: nil` from every `Meeting(...)` call.

- [ ] **Step 2: Implement**
- `Meeting`: delete both properties, both init parameters and both decode lines (unknown keys are ignored when decoding).
- `MeetingActions.canChangeEvent` checks `exportedNotePath` only; its comment and `changeEvent`'s and `unsourcedItemCount`'s comments say note instead of draft (`unsourcedItemCount`: "a copied recap or a note").
- `SidebarSign`: drop `.draftCreated` and its check; `Sidebar.swift` drops the "Draft created" note.
- `Problems.eventNotChanged` explanation: "A note already exists for this meeting."
- `HeaderChips.helpText`: "The event can't be changed once the note is filed".
- `MeetingPreparation` and the two spike commands stop passing `draftWebLink`.

- [ ] **Step 3: Verify**

Run the Core suite, the Platform suite, `swift build -c release --product muninn-spike --package-path Packages/MuninnPlatform`, then `xcodegen generate` and the Debug build. Expected: all pass; both builds succeed.

- [ ] **Step 4: Commit**

```bash
git add -A Muninn Packages
git commit -m "Drop the stored draft fields; only a filed note locks the event"
```

---

### Task 6: Setup guide, changelog and the last draft mentions

**Depends on:** Task 5

**Files:**
- Modify: `docs/setup.md`, `CHANGELOG.md`

- [ ] **Step 1: `docs/setup.md`**: the `graph.microsoft.com` firewall row's reason becomes "calendar, people"; delete the `Mail.ReadWrite` scope row; after the scope table's paragraph add: "An app registered for an earlier version of Muninn can remove `Mail.ReadWrite`; Muninn no longer asks for it."

- [ ] **Step 2: `CHANGELOG.md`** (no release exists, so rewrite under `## [Unreleased]` in place):
- Added: "…and drafts a recap with action points that you send from Outlook." → "…and writes a recap with action points that you copy into any mail app."
- Changed: "…the engine, the Outlook draft and Obsidian…" → "…the engine, the email recap and Obsidian…".
- Changed: "Recipients are chosen in the Outlook draft sheet, which also shows the subject and a preview." → "The Email recap sheet copies the recipients, the subject and the recap, each with its own Copy button, to paste into any mail app. Recipients are chosen there too."

- [ ] **Step 3: Sweep**

Run: `rg -n -i 'draft|outlook|Mail\.ReadWrite' --glob '!docs/superpowers/**' --glob '!CHANGELOG.md' Muninn Packages docs README.md`
Expected, and nothing else: `ActivityArea.outlook` ("Outlook", people search's area), the `outlook.timezone` Prefer header and its tests, `TranscriptTextView`'s `draft` name field, the generic "draft recap" in `README.md`, `docs/spike.md` and the spike's `EndToEnd` output, and the redaction fixtures in `DiagnosticsTests`. Anything else is fixed in this task.

- [ ] **Step 4: Commit**

```bash
git add docs/setup.md CHANGELOG.md
git commit -m "Describe the email recap in the setup guide and changelog"
```

---

## Verification after the last task

- Core and Platform suites pass (report passed/total), the spike builds, and the Debug build succeeds.
- Manual paste checks, on a Debug build with a meeting whose recap has "Réunion" and "één" in a subject: paste each part into Apple Mail, TextEdit (rich text: the RTF, with headings, bullets and bold owners; plain text: the plain text), Proton Mail and Gmail on the web; accents survive everywhere. Proton Mail and Gmail need the owner's accounts and are done by the owner before merge.
- Delete every ad hoc build under `build/` when done (AGENTS.md: macOS may record an ad hoc copy's signature when a permission is granted).
