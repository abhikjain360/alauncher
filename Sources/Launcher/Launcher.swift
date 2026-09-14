import Core
import Foundation

/// Types text into an app: `targetPID`'s, or whatever app is frontmost when nil. Without
/// permission to type, `copyIfNoPermission` puts the text on the clipboard instead.
public typealias InsertText = @MainActor (_ text: String, _ targetPID: pid_t?, _ copyIfNoPermission: Bool) -> Void

/// The launcher's entry points for the app shell.
@MainActor
public enum Launcher {
    private static var controller: LauncherController?
    private static var configStore: ConfigStore?
    private static var previousOnChange: ((Config) -> Void)?

    /// Registers the hotkey, builds the index and follows config changes. `insert` types a
    /// picked emoji, or a `mode = "type"` command's output.
    ///
    /// `configStore.onChange` is chained rather than replaced: a handler set before
    /// this call keeps being called first. One set after it replaces the launcher's.
    public static func start(configStore: ConfigStore, commands: [BuiltInCommand], insert: @escaping InsertText) {
        guard controller == nil else { return }
        let controller = LauncherController(config: configStore.current, builtIns: commands, insert: insert)
        self.controller = controller
        self.configStore = configStore

        let previous = configStore.onChange
        previousOnChange = previous
        configStore.onChange = { config in
            previous?(config)
            // ConfigStore calls this on the main queue.
            MainActor.assumeIsolated { Launcher.controller?.apply(config) }
        }
        controller.start()
    }

    public static func show() {
        controller?.show()
    }

    public static func toggle() {
        controller?.toggle()
    }

    /// Unregisters the hotkey, hides the panel and stops following the config.
    /// Scripts that are still running are left to finish.
    public static func stop() {
        controller?.stop()
        controller = nil
        configStore?.onChange = previousOnChange
        configStore = nil
        previousOnChange = nil
    }
}
