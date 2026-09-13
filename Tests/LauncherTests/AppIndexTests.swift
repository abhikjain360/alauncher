import Foundation
import Testing
@testable import Launcher

struct AppIndexTests {
    private func scan(_ directories: [String], exclude: [String] = []) -> [AppEntry] {
        AppIndex.scan(directories: directories, exclude: ExclusionList(exclude), alwaysInclude: [])
    }

    @Test("titles drop .app; keywords are CFBundleName, CFBundleDisplayName and the file name")
    func namesAndKeywords() throws {
        let dir = try TemporaryDirectory()
        try dir.makeApp("Apps/Visual Studio Code.app", bundleID: "test.alauncher.vscode", name: "Code", displayName: "VSCode")
        try dir.makeApp("Apps/Plain.app", bundleID: nil)

        let apps = scan([dir.path + "/Apps"])
        #expect(apps.map(\.title) == ["Plain", "Visual Studio Code"])
        let code = try #require(apps.last)
        #expect(code.keywords == ["Code", "VSCode"])
        #expect(code.bundleID == "test.alauncher.vscode")
        #expect(code.id == "app:\(dir.path)/Apps/Visual Studio Code.app")
        #expect(apps.first?.keywords == [])
        #expect(apps.first?.bundleID == nil)
    }

    @Test("non-app folders are scanned one level deeper, and nothing inside a bundle is")
    func nestedFolders() throws {
        let dir = try TemporaryDirectory()
        try dir.makeApp("Apps/Top.app", bundleID: "test.alauncher.top")
        try dir.makeApp("Apps/Top.app/Contents/Helpers/Helper.app", bundleID: "test.alauncher.helper")
        try dir.makeApp("Apps/Suite/Nested.app", bundleID: "test.alauncher.nested")
        try dir.makeApp("Apps/Suite/Deeper/TooDeep.app", bundleID: "test.alauncher.deep")

        let apps = scan(["\(dir.path)/Apps/"])
        #expect(apps.map(\.title) == ["Top", "Nested"])
        #expect(apps.last?.path == "\(dir.path)/Apps/Suite/Nested.app")
    }

    @Test("symlinked folders and bundles are followed, keeping the link's path as the id")
    func symlinks() throws {
        let dir = try TemporaryDirectory()
        let store = try dir.makeApp("Store/Real.app", bundleID: "test.alauncher.real")
        try dir.makeApp("Store/Folder/InFolder.app", bundleID: "test.alauncher.infolder")
        try dir.link("Apps/Real.app", to: store)
        try dir.link("Apps/Linked Folder", to: dir.path + "/Store/Folder")
        try dir.link("AppsLink", to: dir.path + "/Apps")

        let apps = scan([dir.path + "/AppsLink"])
        #expect(apps.map(\.path) == ["\(dir.path)/AppsLink/Real.app", "\(dir.path)/AppsLink/Linked Folder/InFolder.app"])
        #expect(apps.map(\.title) == ["Real", "InFolder"])
        #expect(realPath(apps[0].resolvedPath) == realPath(store))
    }

    @Test("a duplicate bundle id keeps the copy in the earlier folder")
    func dedupByBundleID() throws {
        let dir = try TemporaryDirectory()
        try dir.makeApp("First/Tool.app", bundleID: "test.alauncher.tool")
        try dir.makeApp("Second/Tool Copy.app", bundleID: "TEST.alauncher.TOOL")
        try dir.makeApp("Second/Unique.app", bundleID: "test.alauncher.unique")
        try dir.link("Second/Also Tool.app", to: dir.path + "/First/Tool.app")

        let apps = scan([dir.path + "/First", dir.path + "/Second"])
        #expect(apps.map(\.path) == ["\(dir.path)/First/Tool.app", "\(dir.path)/Second/Unique.app"])
    }

    @Test("exclude hides by title or path; an excluded copy doesn't claim its bundle id")
    func exclusion() throws {
        let dir = try TemporaryDirectory()
        try dir.makeApp("Apps/Chess.app", bundleID: "test.alauncher.chess")
        try dir.makeApp("Apps/Keep.app", bundleID: "test.alauncher.keep")
        try dir.makeApp("Apps/Games/Solitaire.app", bundleID: "test.alauncher.solitaire")
        try dir.makeApp("Apps/Tool.app", bundleID: "test.alauncher.tool")
        try dir.makeApp("Other/Tool.app", bundleID: "test.alauncher.tool")

        let apps = scan(
            [dir.path + "/Apps", dir.path + "/Other"],
            exclude: ["chess", dir.path + "/Apps/Games", dir.path + "/Apps/Tool.app"]
        )
        #expect(apps.map(\.path) == ["\(dir.path)/Apps/Keep.app", "\(dir.path)/Other/Tool.app"])
    }

    @Test("Finder is always included")
    func finderAlwaysIncluded() {
        let apps = AppIndex.scan(directories: [], exclude: ExclusionList([]))
        #expect(apps.map(\.path) == [AppIndex.finderPath])
        #expect(apps.first?.title == "Finder")
        #expect(apps.first?.bundleID == "com.apple.finder")
    }

    @Test("config paths expand ~ and environment variables")
    func pathExpansion() {
        #expect(PathExpansion.expand("~/Applications", home: "/Users/me") == "/Users/me/Applications")
        #expect(PathExpansion.expand("~", home: "/Users/me") == "/Users/me")
        #expect(PathExpansion.expand("/etc/profiles/per-user/$USER/bin", environment: ["USER": "me"]) == "/etc/profiles/per-user/me/bin")
        #expect(PathExpansion.expand("${HOME}/bin/", environment: ["HOME": "/h"]) == "/h/bin")
        #expect(PathExpansion.expand("/a/$NOT_SET_ANYWHERE/b", environment: [:]) == "/a/$NOT_SET_ANYWHERE/b")
        #expect(PathExpansion.expand("/cost/$5", environment: [:]) == "/cost/$5")
    }
}
