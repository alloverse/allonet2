import Testing
import Foundation
import PotentCBOR
@testable import allonet2

@MainActor
struct IdentityInvitationTests
{
    /// Identity as it was before invitations existed. Same property names, so its encoding is
    /// byte-for-byte what an older client puts on the wire.
    struct LegacyIdentity: Codable
    {
        let expectation: Identity.Expectation
        let displayName: String
        let emailAddress: String
        let authenticationToken: String
        let color: Color
    }

    @Test func identityCarriesInvitationOverTheWire() throws
    {
        let identity = Identity(expectation: .newUser, displayName: "Nevyn", emailAddress: "n@koja.works",
                                authenticationToken: "hunter2", invitation: "open-sesame")
        let decoded = try CBORDecoder().decode(Identity.self, from: try CBOREncoder().encode(identity))
        #expect(decoded == identity)
        #expect(decoded.invitation == "open-sesame")
    }

    /// An older client omits the key entirely. That has to decode to nil rather than throw, so such
    /// a client is turned away by the place's signup policy instead of by a decoding failure.
    @Test func identityWithoutInvitationDecodes() throws
    {
        let legacy = LegacyIdentity(expectation: .newUser, displayName: "Nevyn", emailAddress: "n@koja.works",
                                    authenticationToken: "hunter2", color: .white)
        let decoded = try CBORDecoder().decode(Identity.self, from: try CBOREncoder().encode(legacy))
        #expect(decoded.invitation == nil)
        #expect(decoded.emailAddress == "n@koja.works")
    }
}
