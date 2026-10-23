import FluidAudio
import Foundation
import MuninnCore
import os

public enum SpeechModelID: String, CaseIterable, Sendable {
    case parakeetV3 = "parakeet-v3"
    case parakeetUltra = "parakeet-ultra"
    case whisperLargeV3Turbo = "whisper-large-v3-turbo"

    /// Live transcription streams through Parakeet only; Whisper is for the final pass.
    public var supportsLive: Bool { parakeetVersion != nil }

    /// The model live transcription uses for a stored setting: the setting itself when it can stream, otherwise Parakeet v3.
    public static func liveModel(named name: String) -> SpeechModelID {
        if let id = SpeechModelID(rawValue: name), id.supportsLive { return id }
        return .parakeetV3
    }

    var parakeetVersion: AsrModelVersion? {
        switch self {
        case .parakeetV3: .v3
        case .parakeetUltra: .ultra
        case .whisperLargeV3Turbo: nil
        }
    }
}

public enum SpeechError: Error, Equatable {
    case unsupportedModel(SpeechModelID)
    case alreadyStarted
}

public enum TranscriberFactory {
    public static func make(_ id: SpeechModelID) -> Transcribing {
        switch id {
        case .parakeetV3, .parakeetUltra: ParakeetTranscriber(model: id)
        case .whisperLargeV3Turbo: WhisperKitTranscriber()
        }
    }
}

enum SpeechLog {
    static let logger = Logger(subsystem: "be.netronix.muninn", category: "speech")
}

/// Runs an expensive load once per key; concurrent first callers share the same load and a
/// failed load is retried by the next caller.
actor KeyedLoadOnce<Key: Hashable & Sendable, Value> {
    private var tasks: [Key: Task<Value, Error>] = [:]

    func value(for key: Key, load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let task = tasks[key] { return try await task.value }
        let task = Task { try await load() }
        tasks[key] = task
        do {
            return try await task.value
        } catch {
            if tasks[key] == task { tasks[key] = nil }
            throw error
        }
    }
}

/// Lets one caller at a time into a model that is not safe to call concurrently.
actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

/// Process-wide Parakeet models; nothing downloads until a caller asks.
enum ParakeetModels {
    private static let models = KeyedLoadOnce<AsrModelVersion, AsrModels>()
    private static let managers = KeyedLoadOnce<AsrModelVersion, AsrManager>()
    private static let ctc = KeyedLoadOnce<String, CtcModels>()

    static func models(for version: AsrModelVersion) async throws -> AsrModels {
        try await models.value(for: version) { try await AsrModels.downloadAndLoad(version: version) }
    }

    static func manager(for version: AsrModelVersion) async throws -> AsrManager {
        try await managers.value(for: version) {
            let manager = AsrManager(config: .default)
            try await manager.loadModels(try await models(for: version))
            return manager
        }
    }

    static func ctcModels() async throws -> CtcModels {
        try await ctc.value(for: "ctc110m") { try await CtcModels.downloadAndLoad() }
    }
}
