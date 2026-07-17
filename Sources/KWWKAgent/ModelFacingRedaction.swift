import KWWKAI

/// Removes runtime-only child identifiers before structured data reaches a model.
func modelFacingJSON(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let object):
        return .object(object.reduce(into: [:]) { redacted, entry in
            guard entry.key != "child_session_id", entry.key != "childSessionId" else {
                return
            }
            redacted[entry.key] = modelFacingJSON(entry.value)
        })
    case .array(let values):
        return .array(values.map(modelFacingJSON))
    default:
        return value
    }
}
