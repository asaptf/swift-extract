import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct ExtractMacroPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ExtractableMacro.self,
        GuideMacro.self,
    ]
}
