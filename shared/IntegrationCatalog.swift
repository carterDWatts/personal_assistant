import Foundation

struct IntegrationDefinition: Decodable, Identifiable {
    struct Grant: Decodable, Identifiable {
        let id: String
        let action: String
        let slot: String
        let name: String
        let description: String
        let scopes: [String]
    }
    let id: String
    let name: String
    let action: String
    let auth: String
    let setupURL: String
    let instructions: String
    let capabilities: [String]
    let grants: [Grant]
}

/// Public setup metadata. Credentials and connection state always come from secure storage.
enum IntegrationCatalog {
    private struct Document: Decodable {
        let version: Int
        let providers: [IntegrationDefinition]
    }
    static func load(from url: URL) throws -> [IntegrationDefinition] {
        let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        guard document.version == 1 else { throw CocoaError(.coderReadCorrupt) }
        return document.providers
    }
    static let providers: [IntegrationDefinition] = {
        guard let url = Bundle.main.url(forResource: "integrations", withExtension: "json"),
              let definitions = try? load(from: url) else { return [] }
        return definitions
    }()
    static let accounts = providers.filter { $0.id != "google" }
    static var googleGrants: [IntegrationDefinition.Grant] { find("google")?.grants ?? [] }
    static func find(_ id: String) -> IntegrationDefinition? { providers.first { $0.id == id } }
    static func provider(for action: String) -> String? {
        providers.first { $0.action == action || $0.grants.contains { $0.action == action } }?.id
    }
    static func grant(for action: String) -> String? { googleGrants.first { $0.action == action }?.id }
    static func name(_ provider: String, grant: String? = nil) -> String {
        if let grant, let value = find(provider)?.grants.first(where: { $0.id == grant }) { return value.name }
        return find(provider)?.name ?? provider.capitalized
    }
}
