import Foundation
import Testing
@testable import KWWKAuth

@Suite("Subscriptions by store id")
struct OAuthSubscriptionsTests {
    @Test("Every login that carries a refresh token has a refresher under its own id, and no other has one")
    func refreshersMatchUpkeep() {
        #expect(Set(OAuthSubscriptions.providers.map(\.id)).count == OAuthSubscriptions.providers.count)
        for provider in OAuthSubscriptions.providers {
            let refresher = OAuthSubscriptions.refresher(providerId: provider.id)
            if provider.upkeep == .refreshed {
                #expect(refresher?.id == provider.id, "\(provider.id)")
            } else {
                #expect(refresher == nil, "\(provider.id)")
            }
        }
        #expect(Set(OAuthSubscriptions.refreshers().map(\.id)) == OAuthSubscriptions.refreshedIds)
        #expect(OAuthSubscriptions.refresher(providerId: "some-new-vendor") == nil)
    }

    @Test("Each site of a two-site vendor is renewed and read at its own site")
    func sites() {
        #expect((OAuthSubscriptions.refresher(providerId: "qoder-cn") as? QoderOAuthProvider)?.site == .cn)
        #expect((OAuthSubscriptions.refresher(providerId: "qoder") as? QoderOAuthProvider)?.site == .global)
        #expect((OAuthSubscriptions.refresher(providerId: "workbuddy-ai") as? WorkBuddyOAuthProvider)?.site == .international)
        #expect((OAuthSubscriptions.refresher(providerId: "workbuddy") as? WorkBuddyOAuthProvider)?.site == .china)
        #expect((OAuthSubscriptions.refresher(providerId: "kimi-coding") as? KimiCodingOAuthProvider)?.site == .china)
        #expect((OAuthSubscriptions.refresher(providerId: "kimi-coding-ai") as? KimiCodingOAuthProvider)?.site == .global)
        #expect(OAuthSubscriptions.provider(id: "kimi-coding-ai")?.name == "Kimi For Coding Global")
    }

    @Test("Usage is read only for subscriptions that can be signed in to")
    func usageIds() {
        let known = Set(OAuthSubscriptions.providers.map(\.id))
        #expect(OAuthSubscriptions.usageIds.isSubset(of: known))
        #expect(OAuthSubscriptions.usageIds.contains("kiro"))
        #expect(OAuthSubscriptions.usageIds.contains("kimi-coding"))
        #expect(OAuthSubscriptions.usageIds.contains("kimi-coding-ai"))
        // A key or a session has no windows kwwk reads.
        #expect(!OAuthSubscriptions.usageIds.contains("zai"))
        #expect(!OAuthSubscriptions.usageIds.contains("github-copilot"))
    }

    @Test("A Kimi refresher carries the fingerprint a host hands it")
    func kimiIdentity() {
        let identity = KimiDeviceIdentity(
            deviceId: "abc",
            deviceName: "server",
            deviceModel: "Linux",
            osVersion: "Linux"
        )
        let kimi = OAuthSubscriptions.refresher(
            providerId: "kimi-coding",
            kimiIdentity: identity
        ) as? KimiCodingOAuthProvider
        #expect(kimi?.identity?.deviceId == "abc")
    }

    @Test("A store id with no sign-in is refused by name")
    func unknownLogin() async {
        await #expect(throws: OAuthError.self) {
            _ = try await OAuthSubscriptions.login(providerId: "some-new-vendor", callbacks: OAuthLogin.Callbacks())
        }
        #expect(OAuthSubscriptions.provider(id: "some-new-vendor") == nil)
        #expect(OAuthSubscriptions.provider(id: "zai")?.upkeep == .permanent)
        #expect(OAuthSubscriptions.provider(id: "devin")?.upkeep == .session)
    }
}
