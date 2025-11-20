import Version
import Logging

@MainActor
public struct Allonet
{
    static var logger = Logger(label: "allonet")
    private static var alreadyInitialized = false
    @MainActor
    public static func Initialize()
    {
        guard !alreadyInitialized else { return }
        alreadyInitialized = true
        logger.notice("Allonet \(buildInfo().describe) initializing. ")
        RegisterStandardComponents()
    }
    
    public static func buildInfo() -> PackageBuild
    {
        return PackageBuild.info
    }
    
    public static func version() -> Version
    {
        return buildInfo().version
    }
}

public extension PackageBuild
{
    public var version: Version
    {
        return Version(tolerant: tag!)!
    }
    
    public var describe: String
    {
        if tag == nil,
           digest.isEmpty {
            return "dirty"
        }
        guard tag != nil else {
            return String(commit.prefix(8))
        }
        var desc = tag!
        if countSinceTag != 0 {
            desc += "-" + String(countSinceTag) + "-g" + commit.prefix(7)
        }
        if isDirty {
            desc += "-dirty"
        }
        return desc

    }
}

public extension Version
{
    func serverIsCompatibleWith(clientVersion: Version) -> Bool
    {
        return
            major == clientVersion.major &&
            minor == clientVersion.minor
    }
}
