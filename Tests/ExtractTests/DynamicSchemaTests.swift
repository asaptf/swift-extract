import Foundation
import Testing

@testable import Extract

private func personSchema() -> ExtractionSchema {
    .object(
        title: "Person",
        properties: [
            "name": .string(),
            "age": .integer(),
            "balance": .number(),
            "birthday": .string(format: "date"),
            "active": .boolean(),
            "role": .string(enumValues: ["admin", "user"]),
        ],
        required: ["name", "age"],
        propertyOrder: ["name", "age", "balance", "birthday", "active", "role"]
    )
}

private func invoiceSchema() -> ExtractionSchema {
    .object(
        properties: [
            "vendor": .string(description: "Supplier name"),
            "total": .number(),
            "tax": .number(),
            "lineItems": .array(
                items: .object(
                    properties: [
                        "description": .string(),
                        "amount": .number(),
                        "quantity": .integer(),
                    ],
                    required: ["description", "amount"]
                )
            ),
        ],
        required: ["vendor", "total", "lineItems"]
    )
}

@Suite("Dynamic schema API")
struct DynamicSchemaTests {
    @Test("schema extract returns JSONValue with native types")
    func happyPath() async throws {
        let json = """
            {"name":"Ada","age":36,"balance":10.5,"birthday":"1815-12-10","active":true,"role":"admin"}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        let value = try await Extract.from(
            "Ada Lovelace, age 36",
            schema: personSchema(),
            using: session
        )
        #expect(value["name"]?.stringValue == "Ada")
        #expect(value["age"]?.numberValue == 36)
        #expect(value["balance"]?.numberValue == Decimal(string: "10.5"))
        #expect(value["birthday"]?.stringValue == "1815-12-10")
        #expect(value["active"]?.boolValue == true)
        #expect(value["role"]?.stringValue == "admin")
    }

    @Test("schema-driven coercion accepts lenient decimals, bools and dates")
    func lenientCoercion() async throws {
        let json = """
            {"name":"Cy","age":"1","balance":"$1,234.50","birthday":"March 5, 2020","active":"yes","role":"USER"}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        let value = try await Extract.from("doc", schema: personSchema(), using: session)
        #expect(value["age"]?.numberValue == 1)
        #expect(value["balance"]?.numberValue == Decimal(string: "1234.50"))
        #expect(value["birthday"]?.stringValue == "2020-03-05")
        #expect(value["active"]?.boolValue == true)
        #expect(value["role"]?.stringValue == "user")
    }

    @Test("locale controls decimal separators on schema extract")
    func localeAwareNumbers() async throws {
        let json = """
            {"name":"Eva","age":1,"balance":"1.234,56","birthday":"03/04/2020","active":true,"role":"user"}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        let value = try await Extract.from(
            "doc",
            schema: personSchema(),
            using: session,
            options: ExtractionOptions(locale: Locale(identifier: "es_ES"))
        )
        #expect(value["balance"]?.numberValue == Decimal(string: "1234.56"))
        #expect(value["birthday"]?.stringValue == "2020-04-03")
    }

    @Test("missing required field repairs on the second attempt")
    func repairMissingRequired() async throws {
        let bad = """
            {"age":36}
            """
        let good = """
            {"name":"Ada","age":36}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [bad, good]))
        let result = try await Extract.detailed(
            from: .text("Ada is 36"),
            schema: personSchema(),
            using: session
        )
        #expect(result.value["name"]?.stringValue == "Ada")
        #expect(result.attempts == 2)
    }

    @Test("invariant closure repairs then returns under reportViolations")
    func invariantClosure() async throws {
        let first = """
            {"vendor":"Acme","total":99,"tax":1,"lineItems":[{"description":"Widget","amount":10,"quantity":1}]}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [first, first, first]))
        let check: @Sendable (JSONValue) throws -> Void = { value in
            let total = value["total"]?.numberValue ?? 0
            let items = value["lineItems"]?.arrayValue ?? []
            let sum = items.reduce(Decimal(0)) { $0 + ($1["amount"]?.numberValue ?? 0) }
            if !Extract.isApproximatelyEqual(total, to: sum) {
                throw InvariantValidationError(
                    path: "total",
                    expected: "line items ≈ \(sum)",
                    found: "\(total)"
                )
            }
        }
        let result = try await Extract.detailed(
            from: .text("Acme invoice total 99 items 10"),
            schema: invoiceSchema(),
            invariants: check,
            using: session,
            options: ExtractionOptions(maxRetries: 1, invariantPolicy: .reportViolations)
        )
        #expect(result.value["vendor"]?.stringValue == "Acme")
        #expect(!result.invariantViolations.isEmpty)
        #expect(result.invariantViolations[0].path == "total")
    }

    @Test("from throws when invariant closure fails under strict policy")
    func invariantThrowsFrom() async throws {
        let json = """
            {"vendor":"Acme","total":99,"tax":0,"lineItems":[{"description":"W","amount":10}]}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json, json, json]))
        let check: @Sendable (JSONValue) throws -> Void = { value in
            throw InvariantValidationError(path: "total", expected: "10", found: "99")
        }
        await #expect(throws: ExtractionError.self) {
            _ = try await Extract.from(
                "doc",
                schema: invoiceSchema(),
                invariants: check,
                using: session,
                options: ExtractionOptions(maxRetries: 0)
            )
        }
    }

    @Test("grounding walks the runtime schema")
    func groundingUsesSchema() async throws {
        let json = """
            {"name":"Ada","age":36}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        let result = try await Extract.detailed(
            from: .text("Ada Lovelace is 36 years old"),
            schema: personSchema(),
            using: session
        )
        let name = result.signals.fields.first { $0.path == "name" }
        #expect(name?.grounding == .verbatim)
        let age = result.signals.fields.first { $0.path == "age" }
        #expect(age != nil)
    }

    @Test("nested arrays coerce item objects and ignore unknown keys")
    func nestedTables() async throws {
        let json = """
            {
              "vendor":"Acme",
              "total":15.5,
              "extra":"drop me",
              "lineItems":[
                {"description":"Widget","amount":"10.00","quantity":2,"ignored":true},
                {"description":"Bolt","amount":5.5,"quantity":"1"}
              ]
            }
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [json]))
        let value = try await Extract.from("invoice", schema: invoiceSchema(), using: session)
        #expect(value["extra"] == nil)
        #expect(value["lineItems"]?.arrayValue?.count == 2)
        #expect(value["lineItems"]?[0]?["description"]?.stringValue == "Widget")
        #expect(value["lineItems"]?[0]?["amount"]?.numberValue == Decimal(string: "10.00"))
        #expect(value["lineItems"]?[0]?["ignored"] == nil)
        #expect(value["lineItems"]?[1]?["quantity"]?.numberValue == 1)
    }

    @Test("optional null is kept; fractional integer is rejected then repaired")
    func nullAndIntegerRepair() async throws {
        let bad = """
            {"name":"Ada","age":36.5,"role":null}
            """
        let good = """
            {"name":"Ada","age":36,"role":null}
            """
        let session = ExtractionSession.mock(MockLanguageModel(responses: [bad, good]))
        let value = try await Extract.from("doc", schema: personSchema(), using: session)
        #expect(value["age"]?.numberValue == 36)
        #expect(value["role"] == .null)
    }

    @Test("JSONValue round-trips through Codable")
    func jsonValueCodable() throws {
        let tree = JSONValue.object([
            "name": .string("Ada"),
            "ok": .bool(true),
            "n": .number(Decimal(string: "7.66")!),
            "missing": .null,
            "items": .array([.string("a")]),
        ])
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == tree)
        #expect(decoded["n"]?.numberValue == Decimal(string: "7.66"))
    }

    @Test("direct schema decode without a model")
    func decodeExtractedUsesCoercion() throws {
        let json = """
            {"name":"Ada","age":"36","active":"no"}
            """
        let value = try DynamicExtractionContext.$schema.withValue(personSchema()) {
            try JSONValue.decodeExtracted(from: json)
        }
        #expect(value["name"]?.stringValue == "Ada")
        #expect(value["age"]?.numberValue == 36)
        #expect(value["active"]?.boolValue == false)
    }
}
