import Testing
@testable import KWWKAI
@testable import KWWKCli

@Suite("Trae and Raccoon in the login list")
struct TraeRaccoonLoginTests {
    @Test("Each is signed in to in the browser, by a flow kwwk runs", arguments: ["trae", "trae-intl", "raccoon"])
    func listed(id: String) {
        #expect(loginProviders.contains { entry in
            if case .oauth = entry.flow { return entry.id == id }
            return false
        })
        #expect(OAuthSubscriptions.provider(id: id)?.upkeep == .refreshed)
        #expect(providerDescriptor(forStoreId: id)?.formTitle == nil)
    }
}
