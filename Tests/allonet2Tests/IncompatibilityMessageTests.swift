import Testing
import Version
@testable import allonet2

@Suite struct IncompatibilityMessageTests
{
    let app = AppDescription(name: "Koja.Works", downloadURL: "https://koja.works/", URLProtocol: "koja")

    @Test func oldClientIsToldToUpdate()
    {
        let msg = app.incompatibilityMessage(client: Version("3.5.2")!, server: Version("3.6.0")!)
        #expect(msg.hasPrefix("Your Koja.Works app is too old"))
        #expect(msg.contains("https://koja.works/"))
        #expect(msg.hasSuffix("\n\nApp allonet 3.5.2, place allonet 3.6.0."))
    }

    @Test func newClientIsToldThePlaceIsBehind()
    {
        let msg = app.incompatibilityMessage(client: Version("3.7.0")!, server: Version("3.6.0")!)
        #expect(msg.hasPrefix("This place runs an older version"))
        #expect(!msg.contains("koja.works"))
        #expect(msg.hasSuffix("App allonet 3.7.0, place allonet 3.6.0."))
    }
}
