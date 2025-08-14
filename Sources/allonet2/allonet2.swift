import Version

public struct Allonet
{
    private static var alreadyInitialized = false
    public static func Initialize()
    {
        guard !alreadyInitialized else { return }
        alreadyInitialized = true
        print("Allonet \(buildInfo().describe) initialization")
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

extension PackageBuild
{
    public var version: Version
    {
        return Version(tolerant: tag!)!
    }
    
    var describe: String
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
