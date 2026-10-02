import RepoPromptApp

@main
enum RepoPromptExecutable {
    @MainActor
    static func main() {
        RepoPromptApplicationLauncher.main()
    }
}
