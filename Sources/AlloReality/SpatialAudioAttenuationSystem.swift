import RealityKit
import simd

/// Attenuate audio by adjusting SpatialAudioComponents' gain manually every frame. This is needed on macOS because we're displaying a diorama, where the full transform at the root node is actually in centimeters or less, and we can't tell RealityKit to use `roomRoot` as the audio spatial field.
// TODO: Better solution: Instead of setting audioListener, we should do the vision pro hack on macos as well!! That way, the spatial field uses real world coordinates without any kind of scaling or custom listener position or anything — it’s just a real spatial audio field with correct distances. We might need this attenuation system to do "audio hidden by wall" etc though...
public struct SpatialAudioAttenuationSystem: RealityKit.System
{
    public init(scene: Scene) {}
    
    /// The reference distance (in meters) for the distance attenuation model. Distances below this value produce full gain.
    public static var referenceDistance: Double = 1.0
    /// The maximum distance (in meters) beyond which audio gain is clamped to 0.
    public static var maxDistance: Double = 10.0
    /// The rolloff multiplier, where 1.0 is a realistic roll-off, 0.5 would make things be heard twice as far, and 2.0 half as far. This'll probably be moved over to a Component setting later, just like regular RealityKit.
    public static var rolloff: Double = 1.6
    
    static let fieldQuery = EntityQuery(where: .has(SpatialAudioFieldComponent.self))
    static let listenerQuery = EntityQuery(where: .has(AudioListenerComponent.self))
    static let spatialAudioQuery = EntityQuery(where: .has(SpatialAudioComponent.self))
    
    
    public func update(context: SceneUpdateContext)
    {
        // Find the first entity with AudioListenerComponent
        var listenIter = context.scene.performQuery(Self.listenerQuery).makeIterator()
        var fieldIter = context.scene.performQuery(Self.fieldQuery).makeIterator()
        guard let listenerEntity = listenIter.next(),
              let fieldEntity = fieldIter.next()
        else {
            // No listener found, nothing to update
            return
        }
        let listenerPosition = listenerEntity.position(relativeTo: fieldEntity)
        
        // Iterate all spatial audio entities
        for entity in context.entities(
            matching: Self.spatialAudioQuery,
            updatingSystemWhen: .rendering
        ) {
            var spatialAudio = entity.components[SpatialAudioComponent.self]!
            let sourcePosition = entity.position(relativeTo: fieldEntity)
            let distance = Double(simd_distance(listenerPosition, sourcePosition))
            let rolloff = Self.rolloff
            
            let isOccluded: Bool
            // The raycast crashes on macOS 15
            if #available(macOS 26,*) {
                let audioCollisions = context.scene.raycast(
                    from: listenerPosition,
                    to: sourcePosition,
                    query: .nearest,
                    mask: AudioCollision.occluder,
                    relativeTo: fieldEntity
                )
                isOccluded = audioCollisions.count > 0
            } else {
                isOccluded = false
            }
            
            let ref = Self.referenceDistance
            let maxDist = Self.maxDistance
            
            let newGain: Double
            if distance >= maxDist || isOccluded {
                newGain = -.infinity
            } else if distance < ref {
                newGain = 0.0
            } else {
                newGain = 20.0 * log10(ref / distance) * rolloff
            }
            
            // Treat changes smaller than 2% in linear amplitude as noise:
            let linearTolerance = 0.02
            let epsilonDB = 20.0 * log10(1.0 + linearTolerance)  // ≈ 0.173 dB
            if abs(spatialAudio.gain - newGain) > epsilonDB
            {
                //print("\tSource: \(entity.name) \(distance)m away at \(sourcePosition)\(isOccluded ? " (occluded)":""). Gain: \(spatialAudio.gain) -> \(newGain)")
                spatialAudio.gain = newGain
                entity.components[SpatialAudioComponent.self] = spatialAudio
            }
        }
    }
    
    public static func register()
    {
        AudioListenerComponent.registerComponent()
        SpatialAudioFieldComponent.registerComponent()
        SpatialAudioAttenuationSystem.registerSystem()
    }
}

/// To make SpatialAudioAttenuationSystem understand where the listener is, you must mark it with an AudioListenerComponent, since it can't reach RealityKitContent.audioListener. There must only be one entity with this component.
public struct AudioListenerComponent: RealityKit.Component
{
    public init() {}
}

/// Demarcates the spatial audio "root", which SpatialAudioAttenuationSystem should use as the coordinate system to do audio attenuation. There must be only one entity with this component.
public struct SpatialAudioFieldComponent: RealityKit.Component
{
    public init() {}
}

public struct AudioCollision
{
    public static let occluder: CollisionGroup = .init(rawValue: 1 << 2)
}
