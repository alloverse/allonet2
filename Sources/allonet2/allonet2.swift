
var alreadyInitialized = false
func InitializeAllonet()
{
    guard !alreadyInitialized else { return }
    alreadyInitialized = true
    print("Allonet initialization")
    RegisterStandardComponents()
}
