struct Allonet
{
    private static var alreadyInitialized = false
    public static func Initialize()
    {
        guard !alreadyInitialized else { return }
        alreadyInitialized = true
        print("Allonet initialization")
        RegisterStandardComponents()
    }
}
