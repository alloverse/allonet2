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

    @Test func identityAndVisorInfoCarryAProfileImage() throws
    {
        let id = AssetID(hashing: Data("a face".utf8)).description
        let identity = Identity(expectation: .existingUser, displayName: "Nevyn", emailAddress: "n@koja.works",
                                authenticationToken: "hunter2", color: .white, profileImage: id)
        #expect(try CBORDecoder().decode(Identity.self, from: try CBOREncoder().encode(identity)) == identity)

        let info = VisorInfo(displayName: "Nevyn", profileImage: id)
        let decoded = try CBORDecoder().decode(VisorInfo.self, from: try CBOREncoder().encode(info))
        #expect(decoded == info)
        #expect(decoded.profileImage == id)
    }

    /// Having no picture is a state a user is genuinely in, not a missing value — which is why this
    /// is optional where `color`, which everyone always has, is not.
    @Test func aMissingProfileImageDecodesAsNone() throws
    {
        let encoded = try CBOREncoder().encode(VisorInfo(displayName: "Nevyn", color: .cyan))
        #expect(!encoded.contains(Data("profileImage".utf8)), "no picture should omit the key entirely")

        let decoded = try CBORDecoder().decode(VisorInfo.self, from: encoded)
        #expect(decoded.profileImage == nil)
        #expect(decoded.displayName == "Nevyn")
    }
}
