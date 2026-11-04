import MuninnCore
import SwiftUI

/// Lays its children out left to right and wraps to a new row when the next one doesn't fit.
struct ChipRow: Layout {
    var spacing: CGFloat = Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews)
        for (index, subview) in subviews.enumerated() {
            let origin = arrangement.origins[index]
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: arrangement.proposals[index])
        }
    }

    /// A chip wider than the row is proposed the row's width, so its label wraps instead of overflowing.
    private func arrange(width: CGFloat, _ subviews: Subviews) -> (origins: [CGPoint], proposals: [ProposedViewSize], size: CGSize) {
        var origins: [CGPoint] = []
        var proposals: [ProposedViewSize] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            var proposal = ProposedViewSize.unspecified
            var size = subview.sizeThatFits(proposal)
            if size.width > width {
                proposal = ProposedViewSize(width: width, height: nil)
                size = subview.sizeThatFits(proposal)
            }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            proposals.append(proposal)
            x += size.width
            widest = max(widest, x)
            x += spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, proposals, CGSize(width: widest, height: y + rowHeight))
    }
}

/// The calendar event chip and the popover for choosing another event.
struct EventChip: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let report: (Error) -> Void

    @State private var showing = false
    @State private var loading = false
    @State private var events: [CalendarEvent] = []
    @State private var failures: [Problem] = []

    private var changing: Bool { model.eventChangesInFlight.contains(meeting.id) }
    private var canChange: Bool { MeetingActions.canChangeEvent(meeting) }

    var body: some View {
        Button {
            showing = true
        } label: {
            chip
        }
        .buttonStyle(.token)
        .disabled(changing || !canChange)
        .help(helpText)
        .popover(isPresented: $showing, arrowEdge: .bottom) { chooser }
    }

    private var helpText: String {
        if !canChange { return "The event can't be changed once a draft or note exists" }
        if changing { return "Wait for the event change" }
        return "Choose the calendar event for this meeting"
    }

    private var chip: Token {
        if !meeting.candidateEvents.isEmpty {
            Token(label: "Which event was this?", systemImage: "questionmark.circle", role: .attention)
        } else if meeting.association != nil {
            Token(label: "Calendar event", systemImage: "calendar")
        } else {
            Token(label: "No event", systemImage: "calendar", role: .placeholder)
        }
    }

    private var otherEvents: [CalendarEvent] {
        let candidates = Set(meeting.candidateEvents.map(\.pickerID))
        return events.filter { !candidates.contains($0.pickerID) }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            ForEach(meeting.candidateEvents, id: \.pickerID) { ref in
                choice(ref, current: false)
            }
            if !meeting.candidateEvents.isEmpty {
                Divider()
            }
            Text("Events around \(meeting.startedAt.formatted(date: .omitted, time: .shortened))")
                .modifier(SectionLabel())
            if loading {
                ProgressView().controlSize(.small)
            } else if otherEvents.isEmpty && failures.isEmpty {
                Text(meeting.candidateEvents.isEmpty ? "No events within two hours of the start" : "No other events within two hours of the start")
                    .font(Theme.interface)
                    .foregroundStyle(Theme.secondaryText)
            }
            ForEach(otherEvents, id: \.pickerID) { event in
                choice(
                    CalendarEventRef(accountID: event.accountID, eventID: event.eventID, subject: event.subject, start: event.start),
                    current: isCurrent(event)
                )
            }
            ForEach(failures, id: \.self) { failure in
                ProblemCard(
                    problem: failure,
                    compact: true,
                    handlers: failureHandlers,
                    showInActivity: { model.showInActivity(failure) }
                )
            }
            if meeting.association != nil || !meeting.candidateEvents.isEmpty {
                Divider()
                Button("No event", action: clearEvent)
                    .buttonStyle(.plain)
                    .font(Theme.interface)
            }
        }
        .padding(Space.m)
        .frame(minWidth: 280, maxWidth: 420, alignment: .leading)
        .task { await load() }
    }

    private func choice(_ ref: CalendarEventRef, current: Bool) -> some View {
        Button {
            showing = false
            let id = meeting.id
            Task { await model.chooseEvent(ref, for: id) }
        } label: {
            Text("\(ref.subject) (\(ref.start.formatted(date: .omitted, time: .shortened)), \(accountName(ref.accountID)))")
                .font(Theme.interface)
                .fontWeight(current ? .semibold : .regular)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(.plain)
    }

    private func clearEvent() {
        showing = false
        if MeetingActions.clearingEventLosesDetails(meeting),
           Alerts.ask(
               "Remove the event from this meeting?",
               "The title and attendees came from the event and are cleared. Recipients you added stay.",
               buttons: ["Remove event", "Cancel"],
               destructive: 0
           ) != 0 {
            return
        }
        do {
            try model.dismissEventChoice(for: meeting.id)
        } catch {
            report(error)
        }
    }

    private var failureHandlers: ProblemHandlers {
        var handlers = model.problemHandlers(tryAgain: { Task { await load() } })
        handlers.signInAgain = {
            showing = false
            model.showSettings(.accounts)
        }
        return handlers
    }

    private func isCurrent(_ event: CalendarEvent) -> Bool {
        meeting.association?.accountID == event.accountID && meeting.association?.eventID == event.eventID
    }

    private func accountName(_ id: String) -> String {
        model.settings.accounts.first(where: { $0.id == id })?.displayName ?? id
    }

    private func load() async {
        loading = true
        let result = await model.eventsAround(meeting)
        events = result.events
        failures = result.failures
        loading = false
    }
}

/// The "<account> · <client>" chip and the popover for changing either.
struct DetailsChip: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting
    let edit: ((inout Meeting) -> Void) -> Void

    @State private var showing = false
    @State private var pickerRevision = 0

    private var accountRemoved: Bool {
        MeetingActions.accountRemoved(meeting, accounts: model.settings.accounts)
    }

    private var accountName: String? {
        guard let id = meeting.accountID else { return nil }
        if accountRemoved { return "Account removed" }
        return model.settings.accounts.first(where: { $0.id == id })?.displayName
    }

    var body: some View {
        let label = MeetingLabels.detailsChip(accountName: accountName, client: meeting.client)
        Button {
            showing = true
        } label: {
            Token(
                label: label,
                systemImage: "building.2",
                role: accountRemoved ? .attention : (accountName == nil && meeting.client == nil ? .placeholder : .normal)
            )
        }
        .buttonStyle(.token)
        .help("Change the account and client")
        .popover(isPresented: $showing, arrowEdge: .bottom) { details }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Picker("Account", selection: accountBinding) {
                Text("None").tag(String?.none)
                if accountRemoved, let removed = meeting.accountID {
                    Text(MeetingActions.accountRemovedLabel).tag(Optional(removed))
                }
                ForEach(model.settings.accounts, id: \.id) { account in
                    Text(account.displayName).tag(Optional(account.id))
                }
            }
            .id(pickerRevision)
            HStack(spacing: Space.xs) {
                Text("Client")
                CommitTextField(title: "Client", value: meeting.client ?? "") { client in
                    let trimmed = client.trimmingCharacters(in: .whitespacesAndNewlines)
                    edit { $0.client = trimmed.isEmpty ? nil : trimmed }
                }
                .textFieldStyle(.roundedBorder)
            }
        }
        .font(Theme.interface)
        .padding(Space.m)
        .frame(minWidth: 320)
    }

    private var accountBinding: Binding<String?> {
        Binding(
            get: { meeting.accountID },
            set: { account in
                guard account != meeting.accountID else { return }
                if MeetingActions.accountChangeDropsEvent(meeting, to: account), !confirmDropsEvent(to: account) {
                    pickerRevision += 1
                    return
                }
                edit {
                    $0.accountID = account
                    if let association = $0.association, association.accountID != account { $0.association = nil }
                }
            }
        )
    }

    private func confirmDropsEvent(to account: String?) -> Bool {
        let accounts = model.settings.accounts
        let question: String
        if let account {
            question = "Change the account to \(accounts.first(where: { $0.id == account })?.displayName ?? account)?"
        } else {
            question = "Remove the account from this meeting?"
        }
        let eventAccount = meeting.association.map { association in
            accounts.first(where: { $0.id == association.accountID })?.displayName ?? "a removed account"
        } ?? ""
        return Alerts.ask(
            question,
            "This meeting's calendar event is in \(eventAccount). Changing the account removes the event from the meeting; its title and attendees stay.",
            buttons: ["Change account", "Cancel"]
        ) == 0
    }
}

private extension CalendarEvent {
    var pickerID: String { "\(accountID)|\(eventID)" }
}

private extension CalendarEventRef {
    var pickerID: String { "\(accountID)|\(eventID)" }
}
