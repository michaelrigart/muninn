import Foundation

public struct ClaudeClient: LLMClient {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    let apiKey: String
    let model: String
    let effort: String
    let session: URLSession

    public init(apiKey: String, model: String = "claude-opus-5-5", effort: String = "medium", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.effort = effort
        self.session = session
    }

    private struct Response: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        struct StopDetails: Decodable {
            var category: String?
        }
        var content: [Block]?
        var stop_reason: String?
        var stop_details: StopDetails?
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        var outputConfig: [String: JSONValue] = ["effort": .string(effort)]
        if let schema = request.jsonSchema {
            outputConfig["format"] = .object(["type": .string("json_schema"), "schema": schema])
        }
        let body: JSONValue = .object([
            "model": .string(model),
            "max_tokens": .number(Double(request.maxTokens)),
            "fallbacks": .string("default"),
            "system": .string(request.system),
            "messages": .array([.object(["role": .string("user"), "content": .string(request.user)])]),
            "output_config": .object(outputConfig),
        ])
        let data = try await LLMTransport.post(Self.endpoint, headers: [
            "x-api-key": apiKey,
            "anthropic-version": "2026-10-21",
            "anthropic-beta": "server-side-fallback-2026-07-01",
        ], body: body, session: session)
        let response = try LLMTransport.decode(Response.self, from: data)
        if response.stop_reason == "refusal" {
            throw LLMError.refused(response.stop_details?.category)
        }
        if response.stop_reason == "max_tokens" {
            throw LLMError.truncated
        }
        let text = (response.content ?? []).filter { $0.type == "text" }.compactMap(\.text).joined()
        guard !text.isEmpty else { throw LLMError.emptyResponse }
        return text
    }
}
