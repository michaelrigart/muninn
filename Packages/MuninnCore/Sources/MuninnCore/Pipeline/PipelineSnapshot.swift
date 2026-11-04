import Foundation

public enum PipelineStage: String, Codable, Hashable, Sendable, CaseIterable {
    case transcribing, identifyingSpeakers, cleaningUp, writingRecap

    public var step: Int {
        switch self {
        case .transcribing: 1
        case .identifyingSpeakers: 2
        case .cleaningUp: 3
        case .writingRecap: 4
        }
    }

    public var title: String {
        switch self {
        case .transcribing: "Transcribing"
        case .identifyingSpeakers: "Telling the speakers apart"
        case .cleaningUp: "Cleaning up the transcript"
        case .writingRecap: "Writing the recap"
        }
    }

    public var stepLabel: String {
        switch self {
        case .transcribing: "Transcribed"
        case .identifyingSpeakers: "Speakers"
        case .cleaningUp: "Cleaned up"
        case .writingRecap: "Recap"
        }
    }

    public var problemStage: ProblemStage {
        switch self {
        case .transcribing: .transcribing
        case .identifyingSpeakers: .identifyingSpeakers
        case .cleaningUp: .cleaningUp
        case .writingRecap: .writingRecap
        }
    }

    public var savedThing: String {
        switch self {
        case .transcribing, .identifyingSpeakers: "the transcript"
        case .cleaningUp: "the clean transcript"
        case .writingRecap: "the recap"
        }
    }
}

public struct PipelineWork: Equatable, Sendable {
    public var meetingID: MeetingID
    public var stage: PipelineStage
    public var engine: EngineKind?
    public var stageStartedAt: Date

    public init(meetingID: MeetingID, stage: PipelineStage, engine: EngineKind?, stageStartedAt: Date) {
        self.meetingID = meetingID
        self.stage = stage
        self.engine = engine
        self.stageStartedAt = stageStartedAt
    }
}

public struct PipelineSnapshot: Equatable, Sendable {
    public var current: PipelineWork?
    public var queued: [MeetingID]

    public init(current: PipelineWork?, queued: [MeetingID]) {
        self.current = current
        self.queued = queued
    }

    public static let idle = PipelineSnapshot(current: nil, queued: [])
}
