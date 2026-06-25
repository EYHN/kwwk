import Foundation

/// Region + credential resolution helpers for `BedrockProvider`, ported from
/// pi `packages/ai/src/api/bedrock-converse-stream.ts`
/// (`getStandardBedrockEndpointRegion`, ARN region extraction,
/// `getConfiguredBedrockRegion`, `getConfiguredBedrockCredentials`).
///
/// These are pure, side-effect-free string helpers so they can be unit-tested
/// directly without standing up a provider or stub HTTP client.
enum BedrockRegion {

    /// Region embedded in an inference-profile / model ARN, e.g.
    /// `arn:aws:bedrock:eu-west-1:1234:inference-profile/…` → `eu-west-1`.
    /// Also handles partition-qualified ARNs like `arn:aws-us-gov:bedrock:…`.
    static func fromARN(_ modelId: String) -> String? {
        guard modelId.hasPrefix("arn:aws") else { return nil }
        // arn:<partition>:bedrock:<region>:<account>:…
        let parts = modelId.split(separator: ":", omittingEmptySubsequences: false)
        // [arn, partition, service, region, account, resource…]
        guard parts.count >= 4, parts[2] == "bedrock" else { return nil }
        let region = String(parts[3])
        return isValidRegionToken(region) ? region : nil
    }

    /// Region of a *standard* AWS Bedrock runtime endpoint host:
    /// `bedrock-runtime.<region>.amazonaws.com` (also `-fips` and `.cn`).
    /// Returns nil for custom/VPC/proxy endpoints so we don't pin those.
    static func fromEndpointHost(_ baseUrl: String?) -> String? {
        guard let baseUrl, !baseUrl.isEmpty else { return nil }
        let host: String
        if let url = URL(string: baseUrl), let h = url.host {
            host = h
        } else {
            // Bare host (no scheme).
            host = baseUrl
        }
        let lower = host.lowercased()
        let prefixes = ["bedrock-runtime-fips.", "bedrock-runtime."]
        for prefix in prefixes where lower.hasPrefix(prefix) {
            var rest = String(lower.dropFirst(prefix.count))
            for suffix in [".amazonaws.com.cn", ".amazonaws.com"] where rest.hasSuffix(suffix) {
                rest.removeLast(suffix.count)
                return isValidRegionToken(rest) ? rest : nil
            }
        }
        return nil
    }

    /// Explicitly-configured region from env (`AWS_REGION` / `AWS_DEFAULT_REGION`).
    static func fromEnv(_ env: [String: String]) -> String? {
        if let r = env["AWS_REGION"], !r.isEmpty { return r }
        if let r = env["AWS_DEFAULT_REGION"], !r.isEmpty { return r }
        return nil
    }

    /// Full resolution order matching pi: ARN-embedded region > standard
    /// endpoint-host region > configured env region > provider fallback.
    ///
    /// `fallback` is the region the provider was constructed with (already
    /// honors env / `us-east-1`), so this never returns nil.
    static func resolve(
        modelId: String,
        baseUrl: String?,
        env: [String: String],
        fallback: String
    ) -> String {
        if let arn = fromARN(modelId) { return arn }
        if let host = fromEndpointHost(baseUrl) { return host }
        if let envRegion = fromEnv(env) { return envRegion }
        return fallback
    }

    /// A region token looks like `us-east-1`, `eu-west-3`, `ap-southeast-2`,
    /// `us-gov-west-1`, `cn-north-1` — lowercase letters/digits separated by
    /// hyphens, with at least one hyphen. Rejects empty / malformed hosts.
    private static func isValidRegionToken(_ s: String) -> Bool {
        guard !s.isEmpty, s.contains("-") else { return false }
        for ch in s.unicodeScalars {
            let ok = (ch >= "a" && ch <= "z") || (ch >= "0" && ch <= "9") || ch == "-"
            if !ok { return false }
        }
        return true
    }
}

/// Credential resolution for Bedrock, ported from pi's
/// `getConfiguredBedrockCredentials` plus best-effort `AWS_PROFILE` support
/// (reading `~/.aws/credentials`). pi delegates profile resolution to the AWS
/// SDK's shared-config chain; we do not depend on the SDK, so this is a
/// pragmatic subset: it reads static keys from the named profile.
enum BedrockCredentials {

    /// Static IAM keys from env (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`,
    /// optional `AWS_SESSION_TOKEN`).
    static func fromEnv(_ env: [String: String]) -> AWSSigV4.Credentials? {
        guard let key = env["AWS_ACCESS_KEY_ID"], !key.isEmpty,
              let secret = env["AWS_SECRET_ACCESS_KEY"], !secret.isEmpty else {
            return nil
        }
        let token = env["AWS_SESSION_TOKEN"]
        return AWSSigV4.Credentials(
            accessKeyId: key,
            secretAccessKey: secret,
            sessionToken: (token?.isEmpty == false) ? token : nil
        )
    }

    /// Best-effort static credentials for a named profile from
    /// `~/.aws/credentials` (or `$AWS_SHARED_CREDENTIALS_FILE`). Does NOT
    /// resolve SSO / `credential_process` / role-assumption profiles — those
    /// require the AWS SDK and are out of scope. Returns nil when the profile
    /// or its `aws_access_key_id` / `aws_secret_access_key` keys are absent.
    static func fromProfile(_ profile: String, env: [String: String]) -> AWSSigV4.Credentials? {
        let path = env["AWS_SHARED_CREDENTIALS_FILE"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".aws/credentials")
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard let section = iniSection(named: profile, in: contents) else { return nil }
        guard let key = section["aws_access_key_id"], !key.isEmpty,
              let secret = section["aws_secret_access_key"], !secret.isEmpty else {
            return nil
        }
        let token = section["aws_session_token"]
        return AWSSigV4.Credentials(
            accessKeyId: key,
            secretAccessKey: secret,
            sessionToken: (token?.isEmpty == false) ? token : nil
        )
    }

    /// Minimal INI parser: returns the key/value pairs under `[<name>]`.
    /// Exposed `internal` for unit tests.
    static func iniSection(named name: String, in contents: String) -> [String: String]? {
        var current: String?
        var result: [String: String] = [:]
        var found = false
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let header = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                // Support `[profile foo]` form used in ~/.aws/config.
                let normalized = header.hasPrefix("profile ")
                    ? String(header.dropFirst("profile ".count)).trimmingCharacters(in: .whitespaces)
                    : header
                current = normalized
                if normalized == name { found = true }
                continue
            }
            guard current == name, let eq = line.firstIndex(of: "=") else { continue }
            let k = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            result[k] = v
        }
        return found ? result : nil
    }
}
