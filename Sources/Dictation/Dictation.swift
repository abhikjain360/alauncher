import AppKit
import Core
import Overlay

/// The dictation entry points the app wires up.
@MainActor
public enum Dictation {
    private static var controller: DictationController?
    private static var historyStore: DictationHistory?

    /// Starts the key monitor, prepares the model (downloading it on first run), and follows config changes.
    ///
    /// Config changes arrive through `configStore.onChange`, which this wraps: a handler the app
    /// installed earlier keeps being called first. An app that sets `onChange` after this call
    /// must call the handler it replaces.
    public static func start(configStore: ConfigStore) {
        guard controller == nil else { return }
        let history = sharedHistory(limit: configStore.current.dictation.historyLimit)
        let controller = DictationController(configStore: configStore, history: history)
        self.controller = controller
        controller.start()
    }

    public static func stop() {
        controller?.stop()
        controller = nil
    }

    /// For launcher commands.
    public static func copyLastDictation() {
        if let controller {
            controller.copyLastDictation()
            return
        }
        guard let record = sharedHistory(limit: Config().dictation.historyLimit).records.last else {
            OverlayPill.shared.flash("no dictation yet", duration: 1.5)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.bestText, forType: .string)
        OverlayPill.shared.flash("copied last dictation", duration: 1.2)
    }

    /// Re-runs the LLM step of the last dictation and inserts the result into the frontmost app.
    public static func retryLastDictation() {
        guard let controller else {
            OverlayPill.shared.flash("dictation is off", isError: true)
            return
        }
        controller.retryLastDictation()
    }

    /// Types `text` into the frontmost app the way dictation does, for the launcher's emoji.
    /// Without permission to post key events it goes on the clipboard instead.
    public static func insert(_ text: String, settings: InsertSettings) {
        guard Inserter.shared.canPostEvents else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            OverlayPill.shared.flash("copied (no permission to type)")
            return
        }
        Task {
            let result = await Inserter.shared.insert(text, targetPID: nil, settings: settings)
            guard let aborted = result.aborted else { return }
            Log.main("insert: \(text.count) chars from the launcher not inserted (\(aborted.rawValue))")
            OverlayPill.shared.flash("not inserted", isError: true)
        }
    }

    /// Oldest first.
    public static var history: [DictationRecord] {
        controller?.records ?? sharedHistory(limit: Config().dictation.historyLimit).records
    }

    private static func sharedHistory(limit: Int) -> DictationHistory {
        if let historyStore { return historyStore }
        let store = DictationHistory(limit: limit)
        historyStore = store
        return store
    }
}
