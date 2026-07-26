import SwiftDiagnostics
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
        guard
            let arguments = node.arguments?.as(LabeledExprListSyntax.self),
            arguments.count == 1,
            let literal = arguments.first?.expression.as(StringLiteralExprSyntax.self),
            literal.segments.allSatisfy({ $0.is(StringSegmentSyntax.self) })
        else {
            context.diagnose(
                Diagnostic(
                    node: Syntax(node),
                    message: GuideDiagnostic.staticLiteralRequired
                )
            )
            return []
        }
        return []
    }
}

private enum GuideDiagnostic: DiagnosticMessage {
    case staticLiteralRequired

    var message: String {
        "@Guide requires a static string literal without interpolation."
    }

    var diagnosticID: MessageID {
        MessageID(domain: "ExtractMacros", id: "guideStaticLiteralRequired")
    }

    var severity: DiagnosticSeverity { .error }
}
