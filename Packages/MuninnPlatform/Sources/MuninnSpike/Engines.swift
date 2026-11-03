import Foundation
import MuninnCore

enum Engines {
    static func describe(_ engine: EngineKind, settings: Settings) -> String {
        switch engine {
        case .macbook: "macbook \(settings.macbook.model) at \(settings.macbook.baseURL)"
        case .studio: "studio \(settings.studio.model) at \(settings.studio.baseURL)"
        case .claude: "claude \(settings.claudeModel) (effort \(settings.claudeEffort))"
        }
    }

    /// Settings with the model of one engine replaced for this run (`--llm-model`).
    static func settings(_ settings: Settings, overridingModel model: String?, for engine: EngineKind) -> Settings {
        guard let model, !model.isEmpty else { return settings }
        var result = settings
        switch engine {
        case .macbook: result.macbook.model = model
        case .studio: result.studio.model = model
        case .claude: result.claudeModel = model
        }
        return result
    }
}
