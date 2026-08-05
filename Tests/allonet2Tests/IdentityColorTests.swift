import Testing
import Foundation
import PotentCBOR
@testable import allonet2

@MainActor
struct IdentityColorTests
{
    @Test func identityCarriesColorOverTheWire() throws
    {
        let identity = Identity(expectation: .existingUser, displayName: "Nevyn", emailAddress: "n@koja.works",
                                authenticationToken: "hunter2", color: .rgb(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        let decoded = try CBORDecoder().decode(Identity.self, from: try CBOREncoder().encode(identity))
        #expect(decoded == identity)
        #expect(decoded.color == .rgb(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
    }

    @Test func visorInfoCarriesColorOverTheWire() throws
    {
        let info = VisorInfo(displayName: "Nevyn", color: .hsv(hue: 0.5, saturation: 0.9, value: 1, alpha: 1))
        let decoded = try CBORDecoder().decode(VisorInfo.self, from: try CBOREncoder().encode(info))
        #expect(decoded == info)
    }

}
