import Foundation
import KWWKAgent

func defaultCLISubagents(
    for tools: CodingTools,
    selection: BuiltinSubagentSelection = .all
) -> [SubagentDefinition] {
    SubagentDefinition.builtins(for: tools, selection: selection)
}
