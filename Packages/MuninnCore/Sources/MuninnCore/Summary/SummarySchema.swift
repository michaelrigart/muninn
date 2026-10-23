public enum SummarySchema {
    public static var jsonSchema: JSONValue {
        object([
            "language": .object(["type": .string("string")]),
            "subjects": array(of: object([
                "title": .object(["type": .string("string")]),
                "bullets": array(of: object([
                    "text": .object(["type": .string("string")]),
                    "sources": array(of: .object(["type": .string("integer")])),
                ])),
                "actions": array(of: object([
                    "owner": .object(["type": .string("string")]),
                    "text": .object(["type": .string("string")]),
                    "due": .object(["type": .array([.string("string"), .string("null")])]),
                    "sources": array(of: .object(["type": .string("integer")])),
                ])),
            ])),
        ])
    }

    private static func object(_ properties: [String: JSONValue]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(properties.keys.sorted().map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }

    private static func array(of items: JSONValue) -> JSONValue {
        .object(["type": .string("array"), "items": items])
    }
}
