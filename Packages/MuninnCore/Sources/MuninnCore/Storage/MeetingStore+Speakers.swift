import Foundation

/// Who the lines of a speaker change go to: an existing speaker's label, or a new speaker.
public enum SpeakerTarget: Equatable, Sendable {
    case speaker(String)
    case new
}

/// The Markdown transcript files could not all be brought in line with a change that is already saved.
public struct TranscriptFilesNotUpdated: ProblemConvertible, Equatable, Sendable {
    public var details: ProblemDetails

    public init(_ error: Error) {
        let nsError = error as NSError
        let url = nsError.userInfo[NSURLErrorKey] as? URL
        details = ProblemDetails(errorDomain: nsError.domain, errorCode: nsError.code, path: (nsError.userInfo[NSFilePathErrorKey] as? String) ?? url?.path)
    }

    public func problem(in context: ProblemContext) -> Problem {
        Problems.transcriptFilesNotUpdated(details: details)
    }
}

/// The transcript as stored after a speaker change. `filesError` is nil when both Markdown files match `transcript.json`.
public struct SpeakerChangeResult: Equatable, Sendable {
    public var transcript: Transcript
    public var filesError: TranscriptFilesNotUpdated?

    public init(transcript: Transcript, filesError: TranscriptFilesNotUpdated?) {
        self.transcript = transcript
        self.filesError = filesError
    }
}

/// The meeting as stored after a rename. `filesError` is nil when both Markdown files show the new names.
public struct SpeakerRenameResult: Equatable, Sendable {
    public var meeting: Meeting
    public var filesError: TranscriptFilesNotUpdated?

    public init(meeting: Meeting, filesError: TranscriptFilesNotUpdated?) {
        self.meeting = meeting
        self.filesError = filesError
    }
}

extension MeetingStore {
    /// Gives the chosen lines to a speaker. `transcript.json` is the commit: when it can't be written nothing changes. The Markdown
    /// files follow, and a failure there is reported in the result because the change is already saved.
    public func changeSpeaker(of segmentIDs: Set<Int>, to target: SpeakerTarget, in id: MeetingID, userName: String) throws -> SpeakerChangeResult {
        Self.transcriptLock.lock()
        defer { Self.transcriptLock.unlock() }
        guard let stored = try loadTranscript(id) else { throw MeetingStoreError.noTranscript }
        let meeting = try load(id)
        let speaker: String
        switch target {
        case .speaker(let label):
            speaker = label
        case .new:
            speaker = TranscriptSpeakers.newLabel(transcript: stored, speakerNames: meeting.speakerNames, recapOwners: try recapOwners(id))
        }
        let changed = TranscriptSpeakers.changing(segmentIDs, to: speaker, in: stored)
        if changed != stored {
            let url = file(id, "transcript.json")
            try beforeSpeakerEditWrite?(url)
            try write(changed, to: url)
        }
        return SpeakerChangeResult(transcript: changed, filesError: rewriteMarkdown(meeting, transcript: changed, userName: userName).map(TranscriptFilesNotUpdated.init))
    }

    /// Names a speaker (a blank name puts the default back). `meeting.json` is the commit; `transcript.json` is never written.
    public func renameSpeaker(_ speaker: String, to name: String, in id: MeetingID, userName: String) throws -> SpeakerRenameResult {
        Self.transcriptLock.lock()
        defer { Self.transcriptLock.unlock() }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try beforeSpeakerEditWrite?(file(id, "meeting.json"))
        let meeting = try update(id) {
            if trimmed.isEmpty {
                $0.speakerNames.removeValue(forKey: speaker)
            } else {
                $0.speakerNames[speaker] = trimmed
            }
        }
        let filesError: Error?
        do {
            if let transcript = try loadTranscript(id) {
                filesError = rewriteMarkdown(meeting, transcript: transcript, userName: userName)
            } else {
                filesError = nil
            }
        } catch {
            filesError = error
        }
        return SpeakerRenameResult(meeting: meeting, filesError: filesError.map(TranscriptFilesNotUpdated.init))
    }

    /// Writes the Markdown files again from what is stored. Does nothing without a transcript; throws the first error.
    public func rewriteTranscriptMarkdown(_ id: MeetingID, userName: String) throws {
        Self.transcriptLock.lock()
        defer { Self.transcriptLock.unlock() }
        guard let transcript = try loadTranscript(id) else { return }
        if let error = rewriteMarkdown(try load(id), transcript: transcript, userName: userName) { throw error }
    }

    /// The owners of the actions in the current and the previous recap. A recap that doesn't exist names none; one that can't be read throws.
    private func recapOwners(_ id: MeetingID) throws -> [String] {
        let recaps = [try loadSummary(id), try loadPreviousSummary(id)].compactMap { $0 }
        return recaps.flatMap { $0.subjects.flatMap { $0.actions.map(\.owner) } }
    }

    /// Writes `transcript.md`, then `transcript.clean.md` when a clean transcript exists. Both are attempted; the first error is returned.
    private func rewriteMarkdown(_ meeting: Meeting, transcript: Transcript, userName: String) -> Error? {
        var firstError: Error?
        do {
            let url = transcriptMarkdownURL(meeting.id)
            try beforeSpeakerEditWrite?(url)
            try writeTranscriptMarkdown(transcript, clean: nil, to: url, title: meeting.title, speakerNames: meeting.speakerNames, userName: userName)
        } catch {
            firstError = error
        }
        do {
            if let clean = try loadClean(meeting.id) {
                let url = cleanTranscriptMarkdownURL(meeting.id)
                try beforeSpeakerEditWrite?(url)
                try writeTranscriptMarkdown(transcript, clean: clean, to: url, title: meeting.title, speakerNames: meeting.speakerNames, userName: userName)
            }
        } catch {
            firstError = firstError ?? error
        }
        return firstError
    }
}
