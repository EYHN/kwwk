import Foundation

/// Path boundary applied by kwwk's built-in file tools.
///
/// This is deliberately separate from `CodingTools`: `.readOnly` controls
/// which tools are registered, while `FileAccessPolicy` controls where the
/// path-bearing tools may operate. It is not an operating-system sandbox and
/// does not constrain Bash or custom tools.
public struct FileAccessPolicy: Sendable, Equatable {
    public enum Scope: Sendable, Equatable {
        case unrestricted
        case workspaceOnly
    }

    public var scope: Scope
    /// Extra roots available to read-like operations. Relative roots are
    /// resolved against the tool's workspace directory.
    public var additionalReadRoots: [String]
    /// Extra roots available to mutation operations. Relative roots are
    /// resolved against the tool's workspace directory.
    public var additionalWriteRoots: [String]

    public init(
        scope: Scope,
        additionalReadRoots: [String] = [],
        additionalWriteRoots: [String] = []
    ) {
        self.scope = scope
        self.additionalReadRoots = additionalReadRoots
        self.additionalWriteRoots = additionalWriteRoots
    }

    /// Preserve the historical SDK behavior: path-bearing tools may use any
    /// host path the process itself can access.
    public static let unrestricted = FileAccessPolicy(scope: .unrestricted)

    /// Restrict path-bearing tools to their workspace directory.
    public static let workspaceOnly = FileAccessPolicy(scope: .workspaceOnly)

    /// Restrict tools to the workspace plus explicit read/write roots.
    public static func workspaceOnly(
        additionalReadRoots: [String] = [],
        additionalWriteRoots: [String] = []
    ) -> FileAccessPolicy {
        FileAccessPolicy(
            scope: .workspaceOnly,
            additionalReadRoots: additionalReadRoots,
            additionalWriteRoots: additionalWriteRoots
        )
    }
}

/// The access being authorized. Write authorization is also used by `edit`,
/// even though edit reads the existing file before replacing its contents.
public enum FileAccessIntent: Sendable {
    case read
    case write
}
