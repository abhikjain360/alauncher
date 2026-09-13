/// A launcher command supplied by the app shell, such as "Reload config".
/// Built-in commands take no arguments.
public struct BuiltInCommand: Sendable {
    public var title: String
    public var subtitle: String?
    public var aliases: [String]
    public var action: @MainActor @Sendable () -> Void

    public init(
        title: String,
        subtitle: String? = nil,
        aliases: [String] = [],
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.aliases = aliases
        self.action = action
    }
}
