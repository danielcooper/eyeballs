import EyeballsCore
import Foundation
import Testing

struct NavigationCommandTests {
    @Test(arguments: [
        ("eyeballs://", NavigationCommand.showMain),
        ("eyeballs:", NavigationCommand.showMain),
        ("eyeballs://stack/3", NavigationCommand.stack(3)),
        ("eyeballs://thread/41", NavigationCommand.thread(41)),
        ("EYEBALLS://Stack/3", NavigationCommand.stack(3)),
        ("eyeballs://stack/3/", NavigationCommand.stack(3)),
    ])
    func parsesNavigationURLs(text: String, expected: NavigationCommand) throws {
        let url = try #require(URL(string: text))
        #expect(NavigationCommand(url: url, scheme: "eyeballs") == expected)
    }

    @Test(arguments: [
        "eyeballs-debug://stack/3",
        "https://stack/3",
        "eyeballs://stack",
        "eyeballs://stack/0",
        "eyeballs://stack/-2",
        "eyeballs://stack/03",
        "eyeballs://stack/three",
        "eyeballs://stack/3/extra",
        "eyeballs://review/3",
        "eyeballs://open?path=/etc/passwd",
        "eyeballs://stack/3#top",
        "eyeballs://stack/99999999999999999999",
    ])
    func rejectsEverythingElse(text: String) throws {
        let url = try #require(URL(string: text))
        #expect(NavigationCommand(url: url, scheme: "eyeballs") == nil)
    }

    @Test func acceptsTheDebugSchemeWhenAskedTo() throws {
        let url = try #require(URL(string: "eyeballs-debug://thread/7"))
        #expect(NavigationCommand(url: url, scheme: "eyeballs-debug") == .thread(7))
    }
}
