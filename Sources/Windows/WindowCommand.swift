/// A command that changes the focused window's frame.
public enum WindowCommand: CaseIterable, Hashable, Sendable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case centerHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case firstThird
    case centerThird
    case lastThird
    case firstTwoThirds
    case lastTwoThirds
    case maximize
    case almostMaximize
    case maximizeHeight
    case maximizeWidth
    case center
    case makeLarger
    case makeSmaller
    case moveLeft
    case moveRight
    case moveUp
    case moveDown
    case nextDisplay
    case previousDisplay
    case restore
    case toggleFullscreen

    public var title: String {
        switch self {
        case .leftHalf: return "Left Half"
        case .rightHalf: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .centerHalf: return "Center Half"
        case .topLeft: return "Top Left Quarter"
        case .topRight: return "Top Right Quarter"
        case .bottomLeft: return "Bottom Left Quarter"
        case .bottomRight: return "Bottom Right Quarter"
        case .firstThird: return "First Third"
        case .centerThird: return "Center Third"
        case .lastThird: return "Last Third"
        case .firstTwoThirds: return "First Two Thirds"
        case .lastTwoThirds: return "Last Two Thirds"
        case .maximize: return "Maximize"
        case .almostMaximize: return "Almost Maximize"
        case .maximizeHeight: return "Maximize Height"
        case .maximizeWidth: return "Maximize Width"
        case .center: return "Center"
        case .makeLarger: return "Make Larger"
        case .makeSmaller: return "Make Smaller"
        case .moveLeft: return "Move Left"
        case .moveRight: return "Move Right"
        case .moveUp: return "Move Up"
        case .moveDown: return "Move Down"
        case .nextDisplay: return "Next Display"
        case .previousDisplay: return "Previous Display"
        case .restore: return "Restore"
        case .toggleFullscreen: return "Toggle Fullscreen"
        }
    }

    /// The SF Symbol shown beside the command in the launcher.
    public var symbol: String {
        switch self {
        case .leftHalf: return "rectangle.lefthalf.inset.filled"
        case .rightHalf: return "rectangle.righthalf.inset.filled"
        case .topHalf: return "rectangle.tophalf.inset.filled"
        case .bottomHalf: return "rectangle.bottomhalf.inset.filled"
        case .centerHalf, .center: return "rectangle.inset.filled"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return "rectangle.split.2x2"
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds:
            return "rectangle.split.3x1"
        case .maximize, .almostMaximize, .toggleFullscreen: return "arrow.up.left.and.arrow.down.right"
        case .maximizeHeight: return "arrow.up.and.down"
        case .maximizeWidth: return "arrow.left.and.right"
        case .makeLarger: return "plus.magnifyingglass"
        case .makeSmaller: return "minus.magnifyingglass"
        case .moveLeft: return "arrow.left"
        case .moveRight: return "arrow.right"
        case .moveUp: return "arrow.up"
        case .moveDown: return "arrow.down"
        case .nextDisplay, .previousDisplay: return "display.2"
        case .restore: return "arrow.uturn.backward"
        }
    }
}
