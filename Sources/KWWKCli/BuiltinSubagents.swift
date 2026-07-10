import Foundation
import KWWKAgent

func defaultCLISubagents(
    for tools: CodingTools,
    selection: BuiltinSubagentSelection = .all,
    runInBackgroundByDefault: Bool = false
) -> [SubagentDefinition] {
    var definitions = SubagentDefinition.builtins(for: tools, selection: selection)
    if runInBackgroundByDefault {
        for index in definitions.indices {
            definitions[index].runInBackgroundByDefault = true
        }
    }
    return definitions
}
