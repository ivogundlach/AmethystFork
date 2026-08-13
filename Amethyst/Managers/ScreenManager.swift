//
//  ScreenManager.swift
//  Amethyst
//
//  Created by Ian Ynda-Hummel on 12/23/15.
//  Copyright © 2015 Ian Ynda-Hummel. All rights reserved.
//

import Foundation
import Silica

/// Information about a layout for display in menus
struct LayoutMenuItemInfo {
    let key: String
    let name: String
    let isSelected: Bool
}

/// Defaults key holding the layout key most recently selected on any screen. Session state rather
/// than configuration: it lets a fresh launch and never-visited spaces open in the layout the user
/// last chose instead of silently resetting to the first configured one.
private let lastSelectedLayoutDefaultsKey = "lastSelectedLayoutKey"

protocol ScreenManagerDelegate: AnyObject {
    associatedtype Window: WindowType
    func applyWindowLimit(forScreenManager screenManager: ScreenManager<Self>, minimizingIn range: (_ windowCount: Int) -> Range<Int>)
    func activeWindowSet(forScreenManager screenManager: ScreenManager<Self>) -> WindowSet<Window>
    func onReflowInitiation()
    func onReflowCompletion()
}

final class ScreenManager<Delegate: ScreenManagerDelegate>: NSObject, Codable {
    typealias Window = Delegate.Window
    typealias Screen = Window.Screen

    enum CodingKeys: String, CodingKey {
        case layoutsBySpaceUUID
    }

    weak var delegate: Delegate?

    private(set) var screen: Screen?
    private(set) var space: Space?

    /// The last window that has been focused on the screen. This value is updated by the notification observations in
    /// `ObserveApplicationNotifications`.
    private(set) var lastFocusedWindow: Window?
    private let userConfiguration: UserConfiguration

    private let reflowOperationDispatchQueue = DispatchQueue(
        label: "ScreenManager.reflowOperationQueue",
        qos: .utility,
        attributes: [],
        autoreleaseFrequency: .inherit,
        target: nil
    )
    private let reflowOperationQueue = OperationQueue()

    // Coalesce reflow requests instead of cancelling in-flight frame assignments. Cancelling mid-pass
    // is the half-tiled / half-fullscreen failure mode: one window already received its new frame
    // while its partner still holds the previous layout's frame. A pending flag re-runs once the
    // current pass finishes, so bursts of events still collapse to a single clean layout.
    private var reflowInFlight = false
    private var reflowPending = false

    private var layouts: [Layout<Window>] = []
    private var currentLayoutIndexBySpaceUUID: [String: Int] = [:]
    private var layoutsBySpaceUUID: [String: [Layout<Window>]] = [:]
    private var currentLayoutIndex: Int = 0
    var previousLayoutKey: String?

    /// The layout to open with on a space that has no in-memory choice yet: the last one the user
    /// explicitly selected, or the first configured layout when nothing was ever selected (or the
    /// remembered layout is no longer enabled). Per-space layout lists share order and count --
    /// `decodedLayouts(from:)` maps onto the configured list -- and `updateSpace(to:)` swaps the
    /// space's list in before consulting this, so the index is valid for whichever list is active.
    private var defaultLayoutIndex: Int {
        guard let key = UserDefaults.standard.string(forKey: lastSelectedLayoutDefaultsKey) else {
            return 0
        }
        return layouts.firstIndex(where: { $0.layoutKey == key }) ?? 0
    }

    var currentLayout: Layout<Window>? {
        guard !layouts.isEmpty else {
            return nil
        }
        return layouts[currentLayoutIndex]
    }

    /// Returns layout info for all layouts in this screen manager, including selection state
    var layoutsInfo: [LayoutMenuItemInfo] {
        return layouts.enumerated().map { index, layout in
            LayoutMenuItemInfo(
                key: layout.layoutKey,
                name: layout.layoutName,
                isSelected: index == currentLayoutIndex
            )
        }
    }

    private let layoutNameWindowController: LayoutNameWindowController

    init(screen: Screen, delegate: Delegate, userConfiguration: UserConfiguration) {
        self.screen = screen
        self.delegate = delegate
        self.userConfiguration = userConfiguration

        layoutNameWindowController = LayoutNameWindowController(windowNibName: "LayoutNameWindow")

        super.init()

        layouts = LayoutType.layoutsWithConfiguration(userConfiguration)

        reflowOperationQueue.underlyingQueue = reflowOperationDispatchQueue
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let layoutsBySpaceUUID = try values.decode([String: [[String: Data]]].self, forKey: .layoutsBySpaceUUID)

        self.userConfiguration = UserConfiguration.shared
        self.layoutsBySpaceUUID = try layoutsBySpaceUUID.mapValues { keyedLayouts -> [Layout<Window>] in
            return try ScreenManager<Delegate>.decodedLayouts(from: keyedLayouts, userConfiguration: UserConfiguration.shared)
        }

        layoutNameWindowController = LayoutNameWindowController(windowNibName: "LayoutNameWindow")
    }

    /**
     Takes the list of layouts and inserts decoded layouts where appropriate.

     - Parameters:
        - encodedLayouts: A list of encoded layouts to be restored.
        - userConfiguration: User configuration defining the list of layouts.
     */
    static func decodedLayouts(from encodedLayouts: [[String: Data]], userConfiguration: UserConfiguration) throws -> [Layout<Window>] {
        let layouts: [Layout<Window>] = LayoutType.layoutsWithConfiguration(userConfiguration)
        var decodedLayouts: [Layout<Window>] = encodedLayouts.compactMap { layout in
            guard let keyData = layout["key"], let key = String(data: keyData, encoding: .utf8) else {
                return nil
            }

            guard let data = layout["data"] else {
                return nil
            }

            do {
                return try LayoutType<Window>.decoded(data: data, key: key)
            } catch {
                log.error("Failed to to decode layout: \(key)")
            }

            return nil
        }

        // Yes this is quadratic, but if your layout list is long enough for that to be significant what are you even doing?
        return layouts.map { layout -> Layout<Window> in
            guard let decodedLayoutIndex = decodedLayouts.firstIndex(where: { $0.layoutKey == layout.layoutKey }) else {
                return layout
            }

            return decodedLayouts.remove(at: decodedLayoutIndex)
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        let layoutsBySpaceUUID = try self.layoutsBySpaceUUID.mapValues { layouts in
            return try layouts.map { layout -> [String: Data] in
                let layoutKey = layout.layoutKey.data(using: .utf8)!
                let encodedLayout = try LayoutType.encoded(layout: layout)
                return ["key": layoutKey, "data": encodedLayout]
            }
        }
        try values.encode(layoutsBySpaceUUID, forKey: .layoutsBySpaceUUID)
    }

    func updateScreen(to screen: Screen) {
        self.screen = screen
    }

    func updateSpace(to space: Space) {
        if let currentSpace = self.space {
            currentLayoutIndexBySpaceUUID[currentSpace.uuid] = currentLayoutIndex
        }

        self.space = space

        // Layouts come first: a screen manager restored from disk has no `layouts` until they are
        // swapped in here, and both the bounds check and the remembered-layout lookup in
        // `setCurrentLayoutIndex` need the real list. (Setting the index before this, as the code
        // used to, silently discarded the lookup on the restored path.)
        if let layouts = layoutsBySpaceUUID[space.uuid] {
            self.layouts = layouts
        } else {
            self.layouts = LayoutType.layoutsWithConfiguration(userConfiguration)
            layoutsBySpaceUUID[space.uuid] = layouts
        }

        setCurrentLayoutIndex(currentLayoutIndexBySpaceUUID[space.uuid] ?? defaultLayoutIndex, changingSpace: true)
    }

    func distributeEvent(_ change: Change<Window>) {
        switch change {
        case let .add(window: window):
            lastFocusedWindow = window
        case let .focusChanged(window):
            lastFocusedWindow = window
        case let .remove(window):
            if lastFocusedWindow == window {
                lastFocusedWindow = nil
            }
        case .windowSwap, .applicationActivate, .applicationDeactivate, .spaceChange, .layoutChange, .tabChange, .none, .unknown:
            break
        }

        log.debug("Screen: \(screen?.screenID() ?? "unknown") reflow -- Window Change: \(change)")

        guard let space, let layouts = layoutsBySpaceUUID[space.uuid] else {
            log.warning("Trying to distribute an event to a screen with no space")
            return
        }

        for layout in layouts {
            if let layout = layout as? StatefulLayout {
                layout.updateWithChange(change)
            }
        }
    }

    func setNeedsReflow() {
        reflowPending = true
        startReflowIfNeeded()
    }

    private func startReflowIfNeeded() {
        guard reflowPending, !reflowInFlight else {
            return
        }

        reflowPending = false
        reflowInFlight = true

        log.debug("Screen: \(screen?.screenID() ?? "unknown") reflow")

        DispatchQueue.main.async {
            self.minimizeWindows()
            self.reflow()
        }
    }

    private func finishReflowPass() {
        reflowInFlight = false
        startReflowIfNeeded()
    }

    private func minimizeWindows() {
        let mainPaneCount = (currentLayout as? PanedLayout)?.mainPaneCount ?? 0

        guard UserConfiguration.shared.tilingEnabled, let windowLimit = UserConfiguration.shared.windowMaxCount() else {
            return
        }
        let shouldInsertAtFront = UserConfiguration.shared.sendNewWindowsToMainPane()
        delegate?.applyWindowLimit(forScreenManager: self, minimizingIn: { windowCount in
            if windowLimit > windowCount {
                // Not enough windows to minimize.
                return 0 ..< 0
            }
            if !(currentLayout is PanedLayout) {
                // Minimize from the back, for layouts like floating/fullscreen.
                if shouldInsertAtFront {
                    return windowLimit ..< windowCount
                } else {
                    return 0 ..< windowCount - windowLimit
                }
            }
            if windowLimit <= mainPaneCount {
                // Don't minimize main panes. This allowing varying main pane count to pin windows.
                guard windowCount >= mainPaneCount else {return 0 ..< 0}
                return mainPaneCount ..< windowCount
            }
            // Minimize the oldest non-main panes.
            if shouldInsertAtFront {
                return windowLimit ..< windowCount
            } else {
                return mainPaneCount ..< windowCount + mainPaneCount - windowLimit
            }
        })
    }

    private func reflow() {
        guard let screen = screen else {
            finishReflowPass()
            return
        }

        guard userConfiguration.tilingEnabled else {
            finishReflowPass()
            return
        }

        // During rapid Space transitions, activation/focus notifications can arrive before
        // this screen manager updates its tracked Space. Catch up rather than skip: a skipped
        // reflow leaves windows on the previous layout's frames until something else asks again.
        if let currentSpace = CGSpacesInfo<Window>.currentSpaceForScreen(screen), currentSpace.id != space?.id {
            updateSpace(to: currentSpace)
        }

        guard space?.type == CGSSpaceTypeUser else {
            finishReflowPass()
            return
        }

        guard let currentSpace = CGSpacesInfo<Window>.currentSpaceForScreen(screen), currentSpace.id == space?.id else {
            finishReflowPass()
            return
        }

        guard let windows = delegate?.activeWindowSet(forScreenManager: self) else {
            finishReflowPass()
            return
        }

        guard let layout = currentLayout, let frameAssignments = layout.frameAssignments(windows, on: screen) else {
            finishReflowPass()
            return
        }

        // TODO: fix mff
//        let mouseFollowsFocus = userConfiguration.mouseFollowsFocus()

        let completeOperation = BlockOperation()

        // The complete operation should execute the completion delegate call.
        // Read isCancelled on the operation queue before hopping to main -- by the time main
        // runs the BlockOperation may already be released, so it must not be captured unowned
        // into the nested async (that crash is what brought the process down on first reflow).
        completeOperation.addExecutionBlock { [weak self] in
            let wasCancelled = completeOperation.isCancelled
            DispatchQueue.main.async {
                if !wasCancelled {
                    self?.delegate?.onReflowCompletion()
                }
                // Always release the in-flight latch, cancelled or not, so coalesced requests run.
                self?.finishReflowPass()
                // TODO: fix mff
//                if mouseFollowsFocus {
//                    if case .windowSwap(let window, _) = event {
//                        window.focus()
//                    }
//                }
            }
        }

        // The completion should be dependent on all assignments finishing
        frameAssignments.forEach { completeOperation.addDependency($0) }

        // Start the operation
        delegate?.onReflowInitiation()
        reflowOperationQueue.addOperations(frameAssignments, waitUntilFinished: false)
        reflowOperationQueue.addOperation(completeOperation)
    }

    func updateCurrentLayout(_ updater: (Layout<Window>) -> Void) {
        guard let layout = currentLayout else {
            return
        }
        updater(layout)
        setNeedsReflow()
    }

    func cycleLayoutForward() {
        setCurrentLayoutIndex((currentLayoutIndex + 1) % layouts.count)
        setNeedsReflow()
    }

    func cycleLayoutBackward() {
        setCurrentLayoutIndex((currentLayoutIndex == 0 ? layouts.count : currentLayoutIndex) - 1)
        setNeedsReflow()
    }

    func selectLayout(_ layoutString: String) {
        guard let currentLayoutKey = currentLayout?.layoutKey else {
            return
        }

        let nextLayoutKey = currentLayoutKey == layoutString ? previousLayoutKey : layoutString

        guard let layoutIndex = layouts.firstIndex(where: { $0.layoutKey == nextLayoutKey }) else {
            // Selecting the active layout toggles back to the previous one, but there isn't always
            // a previous one -- nothing has been toggled yet this session, or the remembered layout
            // is no longer enabled. Re-applying the current layout is the useful reading of the
            // request: the user asked for this layout, and if the windows have drifted out of it
            // (a missed reflow, a window resized by hand) doing nothing at all looks like the
            // command was ignored.
            setNeedsReflow()
            return
        }

        setCurrentLayoutIndex(layoutIndex)
        setNeedsReflow()
        previousLayoutKey = currentLayoutKey
    }

    private func setCurrentLayoutIndex(_ index: Int, changingSpace: Bool = false) {
        guard (0..<layouts.count).contains(index) else {
            return
        }

        currentLayoutIndex = index

        if !changingSpace {
            // A space change only restores a remembered index; an explicit selection is what gets
            // persisted for the next launch.
            UserDefaults.standard.set(layouts[index].layoutKey, forKey: lastSelectedLayoutDefaultsKey)
        }

        guard !changingSpace || userConfiguration.enablesLayoutHUDOnSpaceChange() else {
            return
        }

        DispatchQueue.main.async {
            self.displayLayoutHUD()
        }
    }

    func shrinkMainPane() {
        guard let panedLayout = currentLayout as? PanedLayout else {
            return
        }
        panedLayout.shrinkMainPane()
    }

    func expandMainPane() {
        guard let panedLayout = currentLayout as? PanedLayout else {
            return
        }
        panedLayout.expandMainPane()
    }

    func nextWindowIDCounterClockwise() -> Window.WindowID? {
        guard let layout = currentLayout as? StatefulLayout else {
            return nil
        }

        return layout.nextWindowIDCounterClockwise()
    }

    func nextWindowIDClockwise() -> Window.WindowID? {
        guard let statefulLayout = currentLayout as? StatefulLayout else {
            return nil
        }

        return statefulLayout.nextWindowIDClockwise()
    }

    func displayLayoutHUD() {
        guard userConfiguration.enablesLayoutHUD(), space?.type == CGSSpaceTypeUser else {
            return
        }

        let currentLayoutName = currentLayout.flatMap({ $0.layoutName }) ?? "None"
        let currentLayoutDescription = currentLayout?.layoutDescription ?? ""

        displayCustomHUD(title: currentLayoutName, description: currentLayoutDescription)
    }

    @objc func hideLayoutHUD(_ sender: AnyObject) {
        layoutNameWindowController.close()
    }

    func displayCustomHUD(title: String, description: String = "") {
        guard let screen = screen else {
            return
        }

        guard space?.type == CGSSpaceTypeUser else {
            return
        }

        defer {
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideLayoutHUD(_:)), object: nil)
            perform(#selector(hideLayoutHUD(_:)), with: nil, afterDelay: 0.6)
        }

        guard let layoutNameWindow = layoutNameWindowController.window as? LayoutNameWindow else {
            return
        }

        // Use new displayNotification method with dynamic sizing
        layoutNameWindow.displayNotification(title: title, description: description)

        // Center the window after resizing
        let screenFrame = screen.frame()
        let screenCenter = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
        let windowOrigin = CGPoint(
            x: screenCenter.x - layoutNameWindow.frame.width / 2.0,
            y: screenCenter.y - layoutNameWindow.frame.height / 2.0
        )
        layoutNameWindow.setFrameOrigin(NSPointFromCGPoint(windowOrigin))

        layoutNameWindowController.showWindow(self)
    }
}

extension ScreenManager: Comparable {
    static func < (lhs: ScreenManager<Delegate>, rhs: ScreenManager<Delegate>) -> Bool {
        guard let lhsScreen = lhs.screen, let rhsScreen = rhs.screen else {
            return false
        }

        let originX1 = lhsScreen.frameWithoutDockOrMenu().origin.x
        let originX2 = rhsScreen.frameWithoutDockOrMenu().origin.x

        return originX1 < originX2
    }
}
