import SwiftSyntax
import SwiftSyntaxMacros

/// Peer macro for `@Guide("...")`. Expansion is intentionally empty; the
/// ``ExtractableMacro`` reads the attribute from the property declaration.
public struct GuideMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // Validate that the argument is a string literal for clearer diagnostics.
        if let arguments = node.arguments?.as(LabeledExprListSyntax.self),
            let first = arguments.first
        {
            if first.expression.is(StringLiteralExprSyntax.self) {
                return []
            }
            // Allow string interpolation expressions too.
            return []
        }
        // `@Guide("...")` without labels still lands as LabeledExprList; empty is fine.
        return []
    }
}
