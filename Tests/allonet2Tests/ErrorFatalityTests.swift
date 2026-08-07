import XCTest
import PotentCBOR
import PotentCodables
@testable import allonet2

/// Whether an error is permanent is the raiser's to know: an app's error codes mean nothing to
/// allonet's tables. These cover that answer surviving the trip to the peer that has to act on it.
@MainActor
final class ErrorFatalityTests: XCTestCase
{
    /// Round-trip through the wire, as a response body does between place and visor.
    private func overTheWire(_ body: InteractionBody) throws -> InteractionBody
    {
        try CBORDecoder().decode(InteractionBody.self, from: CBOREncoder().encode(body))
    }

    /// The production case: KojaServ rejects a login in its own error domain, the place calls that
    /// permanent, and the visor has to hear it — its tables have no entry for `works.koja.error`.
    func testForeignDomainFatalitySurvivesTheWire() throws
    {
        let raised = AlloverseError(domain: "works.koja.error", code: 2,
                                    description: "Incorrect credentials.", overrideIsFatal: true)
        XCTAssertTrue(raised.isFatal)

        let received = AlloverseError(with: try overTheWire(raised.asBody))
        XCTAssertTrue(received.isFatal)
        XCTAssertEqual(received.domain, "works.koja.error")
        XCTAssertEqual(received.code, 2)
    }

    /// A place that refuses a login knows that's permanent even if the app that rejected it never
    /// said so, so its override outranks what came off the wire.
    func testPlaceOverrideOutranksWhatThePeerSaid() throws
    {
        let fromApp = AlloverseError(domain: "works.koja.error", code: 2, description: "Nope")
        XCTAssertFalse(fromApp.isFatal)

        let fromPlace = AlloverseError(with: try overTheWire(fromApp.asBody), overrideIsFatal: true)
        XCTAssertTrue(fromPlace.isFatal)
    }

    /// A peer that predates the flag sends no `isFatal` at all, and its codes still have to
    /// classify themselves through our own tables.
    func testBodyWithoutTheFlagFallsBackToTheCodeTables() throws
    {
        func legacyBody(code: Int, domain: String) throws -> InteractionBody
        {
            let old: AnyValue = ["error": ["domain": .string(domain), "code": .int(code),
                                           "description": "From a place that predates isFatal"]]
            return try CBORDecoder().decode(InteractionBody.self, from: CBOREncoder().encode(old))
        }

        let fatal = AlloverseError(with: try legacyBody(code: AlloverseErrorCode.incompatibleProtocolVersion.rawValue,
                                                        domain: AlloverseErrorCode.domain))
        XCTAssertTrue(fatal.isFatal, "A known-fatal code must stay fatal without the flag")

        let transient = AlloverseError(with: try legacyBody(code: AlloverseErrorCode.internalServerError.rawValue,
                                                            domain: AlloverseErrorCode.domain))
        XCTAssertFalse(transient.isFatal)

        let unknown = AlloverseError(with: try legacyBody(code: 2, domain: "works.koja.error"))
        XCTAssertFalse(unknown.isFatal, "Nothing to go on: retrying is the safer guess")
    }

    /// An unstated fatality mustn't add a key to the wire, or a peer that predates the flag has a
    /// field it never expected in every error it receives.
    func testUnstatedFatalityIsOmittedFromTheWire() throws
    {
        let plain = AlloverseError(code: AlloverseErrorCode.internalServerError, description: "Hiccup")
        let encoded = try CBORDecoder().decode(AnyValue.self, from: CBOREncoder().encode(plain.asBody))
        XCTAssertEqual(encoded["error"]?["isFatal"], .bool(false),
                       "Resolved rather than stated: false is what our tables say about this code")

        let unknownDomain = AlloverseError(domain: "works.koja.error", code: 2, description: "Nope")
        let encodedUnknown = try CBORDecoder().decode(AnyValue.self, from: CBOREncoder().encode(unknownDomain.asBody))
        XCTAssertEqual(encodedUnknown["error"]?["isFatal"], .bool(false))
    }
}
