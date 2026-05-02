import Foundation

func applyResolvedAuth(
    _ auth: ResolvedProviderAuth,
    to headers: inout [String: String],
    merge: (_ headers: inout [String: String], _ name: String, _ value: String) -> Void = { headers, name, value in
        headers[name] = value
    }
) {
    for (name, value) in auth.headers {
        merge(&headers, name, value)
    }
    guard let token = auth.token, !token.isEmpty else { return }
    switch auth.scheme {
    case .none, .queryKey:
        break
    case .bearer:
        merge(&headers, "authorization", "Bearer \(token)")
    case .apiKeyHeader(let name):
        merge(&headers, name, token)
    }
}

func resolvedQueryKey(_ auth: ResolvedProviderAuth?, expectedName: String) -> String? {
    guard case .queryKey(let name) = auth?.scheme, name == expectedName else { return nil }
    return auth?.token
}
