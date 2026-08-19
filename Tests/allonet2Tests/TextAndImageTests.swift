import Testing
import Foundation
import PotentCBOR
@testable import allonet2

/// The wire shape of the two additions KojaServ uses to put a logo and a company name on a wall.
@MainActor
struct TextAndImageTests
{
    /// Components travel type-erased and are recovered through the registry, so the round trip that
    /// matters is the one through `AnyComponent` — not `Text` on its own.
    @Test func textRoundTripsThroughTheRegistry() throws
    {
        Text.register()
        let text = Text(string: "Koja\nWorks", height: 0.2, width: 1.5, wrap: true, fitToWidth: false,
                        halign: .left, valign: .top, color: .rgb(red: 0.1, green: 0.2, blue: 0.3, alpha: 1))
        let wire = try CBORDecoder().decode(AnyComponent.self, from: try CBOREncoder().encode(AnyComponent(text)))
        #expect(wire.decoded() as? Text == text)
    }

    /// Alignments are protocol, not Swift: they must stay readable strings for a non-Swift renderer.
    @Test func alignmentsTravelAsTheirNames() throws
    {
        let encoded = try JSONEncoder().encode(Text(string: "x", height: 0.1, width: 1, halign: .right, valign: .bottom))
        let json = String(data: encoded, encoding: .utf8)!
        #expect(json.contains("\"right\""))
        #expect(json.contains("\"bottom\""))
    }

    @Test func imageMaterialRoundTripsThroughTheRegistry() throws
    {
        Model.register()
        let model = Model(mesh: .plane(width: 1, depth: 1, cornerRadius: 0),
                          material: .image(asset: AssetID(hashing: Data("a logo".utf8))))
        let wire = try CBORDecoder().decode(AnyComponent.self, from: try CBOREncoder().encode(AnyComponent(model)))
        #expect(wire.decoded() as? Model == model)
    }

    /// `.image` carries an `AssetID`, so it inherits that type's rejection of anything that isn't a
    /// content address — a peer can't smuggle a path through the material.
    @Test func aMalformedAssetIdInAnImageMaterialIsRejected() throws
    {
        /// The same wire shape, but any string a peer likes for the id.
        struct HostileMaterial: Encodable
        {
            struct Image: Encodable { let asset: String }
            let image: Image
            init(_ asset: String) { image = Image(asset: asset) }
        }
        // Pin the shape first: a well-formed id in this exact payload does decode, so the throw
        // below is about the id and not about the layout.
        let good = AssetID(hashing: Data("a logo".utf8))
        #expect(try CBORDecoder().decode(Model.Material.self, from: try CBOREncoder().encode(HostileMaterial(good.description))) == .image(asset: good))

        #expect(throws: AssetError.malformedID("../../etc/passwd")) {
            try CBORDecoder().decode(Model.Material.self, from: try CBOREncoder().encode(HostileMaterial("../../etc/passwd")))
        }
    }
}
