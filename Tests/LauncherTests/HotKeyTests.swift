import Carbon.HIToolbox
import Core
import Testing
@testable import Launcher

/// Only the pure `KeySpec` → Carbon mapping; nothing here registers a hotkey.
struct HotKeyTests {
    private func carbonKey(_ text: String) throws -> Result<HotKeyMapping.CarbonKey, HotKeyMapping.Failure> {
        HotKeyMapping.carbonKey(for: try #require(KeySpec.parse(text)))
    }

    @Test("cmd+space maps to kVK_Space with cmdKey")
    func defaultHotkey() throws {
        #expect(try carbonKey("cmd+space") == .success(.init(keyCode: 49, modifiers: UInt32(cmdKey))))
        #expect(HotKeyMapping.carbonKey(for: LauncherDefaults.hotkey) == .success(.init(keyCode: 49, modifiers: UInt32(cmdKey))))
    }

    @Test("each side-less modifier maps to its Carbon flag")
    func modifiers() throws {
        #expect(try carbonKey("ctrl+option+shift+cmd+k") == .success(.init(
            keyCode: 40,
            modifiers: UInt32(cmdKey | optionKey | shiftKey | controlKey)
        )))
        let single: [(String, Int)] = [
            ("cmd+a", cmdKey), ("command+a", cmdKey), ("option+a", optionKey), ("alt+a", optionKey),
            ("shift+a", shiftKey), ("ctrl+a", controlKey), ("control+a", controlKey),
        ]
        for (text, flag) in single {
            #expect(try carbonKey(text) == .success(.init(keyCode: 0, modifiers: UInt32(flag))), "\(text)")
        }
        #expect(try carbonKey("f13") == .success(.init(keyCode: 105, modifiers: 0)))
    }

    @Test("side-specific modifiers are rejected, naming the key and the fix")
    func sideSpecificModifiers() throws {
        for text in ["right_option+space", "left_cmd+space", "cmd_right+space", "right_shift+a", "left_ctrl+b", "cmd+right_option+space"] {
            guard case .failure(.sideSpecificModifier) = try carbonKey(text) else {
                Issue.record("\(text) was accepted")
                continue
            }
        }
        let result = try carbonKey("right_option+space")
        #expect(result == .failure(.sideSpecificModifier(.rightOption)))
        if case .failure(let failure) = result {
            #expect(failure.description.contains("right_option"))
            #expect(failure.description.contains("use option"))
        }
    }

    @Test("fn and modifier-only specs are rejected")
    func otherFailures() throws {
        #expect(try carbonKey("fn+space") == .failure(.functionModifier))
        #expect(try carbonKey("cmd") == .failure(.missingKey))
    }
}

/// The press/release bookkeeping only; nothing is registered with Carbon.
@MainActor
struct HotKeyStateTests {
    @Test("holding the hotkey toggles once, and a lost key-up can't wedge it")
    func pressAndRelease() {
        var fired = 0
        let hotKey = HotKey { fired += 1 }
        hotKey.handle(pressed: true, now: 10)
        hotKey.handle(pressed: true, now: 10.4)
        hotKey.handle(pressed: true, now: 10.9)
        #expect(fired == 1)

        hotKey.handle(pressed: false, now: 11)
        hotKey.handle(pressed: true, now: 11.1)
        #expect(fired == 2)

        // That press's key-up never arrives.
        hotKey.handle(pressed: true, now: 20)
        #expect(fired == 3)
        #expect(hotKey.registeredSpec == nil)
    }
}

private enum LauncherDefaults {
    static let hotkey = LauncherSettings().hotkey
}
