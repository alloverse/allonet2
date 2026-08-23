import RealityKit
import simd
import AlloAudio

/// Feeds the `VoiceEngine`'s environment node where the listener and every speaking entity are,
/// once per rendered frame, in metres relative to the `SpatialAudioFieldComponent` entity.
///
/// The field entity is what makes this a system rather than a plain observer: a place is
/// rendered as a diorama, so the scene's root transform is in centimetres or less, and only
/// distances measured relative to the field are the real-world metres the audio engine expects.
public struct SpatialAudioPositionSystem: RealityKit.System
{
    public init(scene: Scene) {}

    /// Distance (metres) below which a source plays at full gain.
    public static var referenceDistance: Double = 1.5
    /// Distance (metres) beyond which a source is inaudible.
    public static var maxDistance: Double = 10.0
    /// Roll-off multiplier: 1.0 is realistic, 0.5 makes things heard twice as far, 2.0 half as far.
    public static var rolloff: Double = 2.0

    /// What an occluding collider does to a source: the environment node's floor, i.e. silence.
    private static let occludedAttenuation: Float = -100

    static let fieldQuery = EntityQuery(where: .has(SpatialAudioFieldComponent.self))
    static let listenerQuery = EntityQuery(where: .has(AudioListenerComponent.self))
    static let sourceQuery = EntityQuery(where: .has(VoiceSourceComponent.self))

    public func update(context: SceneUpdateContext)
    {
        var listenerIter = context.scene.performQuery(Self.listenerQuery).makeIterator()
        var fieldIter = context.scene.performQuery(Self.fieldQuery).makeIterator()
        guard let listenerEntity = listenerIter.next(),
              let fieldEntity = fieldIter.next()
        else { return }

        let listenerPosition = listenerEntity.position(relativeTo: fieldEntity)
        let axes = VoiceEngine.listenerAxes(of: listenerEntity.transformMatrix(relativeTo: fieldEntity))
        var pushedListener = Set<ObjectIdentifier>()

        for entity in context.entities(
            matching: Self.sourceQuery,
            updatingSystemWhen: .rendering
        ) {
            let source = entity.components[VoiceSourceComponent.self]!
            let engine = source.engine
            if pushedListener.insert(ObjectIdentifier(engine)).inserted
            {
                engine.setAttenuation(referenceDistance: Float(Self.referenceDistance),
                                      maximumDistance: Float(Self.maxDistance),
                                      rolloffFactor: Float(Self.rolloff))
                engine.setListener(position: listenerPosition, forward: axes.forward, up: axes.up)
            }

            let sourcePosition = entity.position(relativeTo: fieldEntity)
            engine.setPosition(sourcePosition, for: source.mediaId)

            // Attenuation alone leaves a distant source faint but audible; past maxDistance it is gone.
            engine.setAudible(VoiceEngine.isAudible(distance: simd_distance(listenerPosition, sourcePosition),
                                                    maxDistance: Float(Self.maxDistance),
                                                    wasAudible: engine.isAudible(source.mediaId)),
                              for: source.mediaId)

            let isOccluded: Bool
            // The raycast crashes on macOS 15
            if #available(macOS 26, *) {
                isOccluded = context.scene.raycast(
                    from: listenerPosition,
                    to: sourcePosition,
                    query: .nearest,
                    mask: AudioCollision.occluder,
                    relativeTo: fieldEntity
                ).count > 0
            } else {
                isOccluded = false
            }
            engine.setOcclusion(isOccluded ? Self.occludedAttenuation : 0, for: source.mediaId)
        }
    }

    public static func register()
    {
        AudioListenerComponent.registerComponent()
        SpatialAudioFieldComponent.registerComponent()
        VoiceSourceComponent.registerComponent()
        SpatialAudioPositionSystem.registerSystem()
    }
}

/// To make SpatialAudioPositionSystem understand where the listener is, you must mark it with an AudioListenerComponent. There must only be one entity with this component.
public struct AudioListenerComponent: RealityKit.Component
{
    public init() {}
}

/// Demarcates the spatial audio "root", whose coordinate system SpatialAudioPositionSystem uses to place audio. There must be only one entity with this component.
public struct SpatialAudioFieldComponent: RealityKit.Component
{
    public init() {}
}

/// Ties an entity to the voice stream coming out of it, so the position system knows which
/// engine source to move. Set and removed by `SpatialAudioPlayer`.
struct VoiceSourceComponent: RealityKit.Component
{
    let mediaId: String
    let engine: VoiceEngine
}

public struct AudioCollision
{
    public static let occluder: CollisionGroup = .init(rawValue: 1 << 2)
}
