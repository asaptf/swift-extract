import Extract
import Foundation
import Testing

@Extractable
struct NestedRoot {
    let label: String
    let child: NestedChild
    let tags: [String]
    let count: Int?
    let status: Status

    @Extractable
    struct NestedChild {
        let value: Double
        @Guide("secondary note") let note: String
    }

    enum Status: String, Codable, Sendable, CaseIterable {
        case open
        case closed
    }
}

extension NestedRoot.Status: Extractable {}

@Suite("Schema + decoding")
struct SchemaAndDecodeTests {
    @Test("schema includes nested types, optionals, arrays, guides, enums")
    func schemaShape() {
        let schema = NestedRoot.extractionSchema
        #expect(schema.type == .object)
        #expect(schema.title == "NestedRoot")
        #expect(schema.required?.contains("label") == true)
        #expect(schema.required?.contains("count") != true)

        let child = schema.properties?["child"]
        #expect(child?.type == .object)
        #expect(child?.properties?["note"]?.description?.contains("secondary") == true)

        let tags = schema.properties?["tags"]
        #expect(tags?.type == .array)
        #expect(tags?.items?.type == .string)

        let status = schema.properties?["status"]
        #expect(status?.type == .string)
        #expect(status?.enumValues?.contains("open") == true)
        #expect(status?.enumValues?.contains("closed") == true)

        let rendered = schema.renderJSONSchema()
        #expect(rendered.contains("\"type\""))
        #expect(rendered.contains("NestedRoot") || rendered.contains("label"))
    }

    @Test("Invoice schema matches hero type")
    func invoiceSchema() {
        // Invoice is defined in HeroAPITests
        let schema = Invoice.extractionSchema
        #expect(schema.properties?["vendor"] != nil)
        #expect(schema.properties?["dueDate"]?.format == "date-time")
        #expect(schema.properties?["total"]?.type == .number)
        #expect(schema.properties?["lineItems"]?.type == .array)
    }

    @Test("decodeExtracted strips fences and is lenient")
    func decodeExtracted() throws {
        let raw = """
            ```json
            {
              "label": "  root  ",
              "child": {"value": 1.5, "note":"hi"},
              "tags": ["a","b"],
              "count": null,
              "status": "open"
            }
            ```
            """
        let value = try NestedRoot.decodeExtracted(from: raw)
        #expect(value.label == "root")
        #expect(value.child.value == 1.5)
        #expect(value.tags == ["a", "b"])
        #expect(value.count == nil)
        #expect(value.status == .open)
    }
}
