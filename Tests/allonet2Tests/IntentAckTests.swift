import Testing
import simd
@testable import allonet2

@MainActor
struct IntentAckTests
{
    /// Acking a changeset rebuilds currentIntent. It must keep app-owned fields: wiping the held
    /// direction let the client's own state ack stop its avatar after a single step.
    @Test func ackPreservesMoveDirection() async throws
    {
        let client = makeTestClient()
        client.stayConnected()
        await awaitClientState(client, { $0.avatarId != nil })

        client.moveDirection = SIMD2<Float>(0, 1)
        client.session(client.session, didReceivePlaceChangeSet: PlaceChangeSet(changes: [], fromRevision: 0, toRevision: 1))

        #expect(client.moveDirection == SIMD2<Float>(0, 1))
        #expect(client.currentIntent.ackStateRev == 1)

        client.disconnect()
    }
}
