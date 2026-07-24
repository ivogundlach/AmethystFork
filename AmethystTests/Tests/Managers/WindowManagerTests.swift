//
//  WindowManagerTests.swift
//  AmethystTests
//

@testable import Amethyst
import Cocoa
import Nimble
import Quick
import Silica

class WindowManagerTests: QuickSpec {
    /// Builds a `CGWindowListCopyWindowInfo`-shaped description.
    private static func windowDescription(id: UInt32, pid: Int32, layer: Int = 0) -> [String: AnyObject] {
        return [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer)
        ]
    }

    override func spec() {
        describe("finding untracked windows") {
            typealias Manager = WindowManager<SIApplication>
            let make = WindowManagerTests.windowDescription

            it("ignores windows it already tracks") {
                let pids = Manager.pidsOwningUntrackedWindows(
                    descriptions: [make(1, 100, 0), make(2, 200, 0)],
                    trackedIDs: [1, 2],
                    ownPID: 999
                )
                expect(pids).to(beEmpty())
            }

            it("reports the owner of a window that is on screen but untracked") {
                let pids = Manager.pidsOwningUntrackedWindows(
                    descriptions: [make(1, 100, 0), make(2, 200, 0)],
                    trackedIDs: [1],
                    ownPID: 999
                )
                expect(pids) == [200]
            }

            it("collapses several untracked windows of one app into a single pid") {
                let pids = Manager.pidsOwningUntrackedWindows(
                    descriptions: [make(1, 100, 0), make(2, 100, 0), make(3, 100, 0)],
                    trackedIDs: [],
                    ownPID: 999
                )
                expect(pids) == [100]
            }

            it("ignores windows above the normal window layer") {
                // Menus, HUDs, and the status bar are never managed; reconciling on them would
                // wake apps up on every layout change for nothing.
                let pids = Manager.pidsOwningUntrackedWindows(
                    descriptions: [make(1, 100, 25), make(2, 200, -1)],
                    trackedIDs: [],
                    ownPID: 999
                )
                expect(pids).to(beEmpty())
            }

            it("never reports itself") {
                let pids = Manager.pidsOwningUntrackedWindows(
                    descriptions: [make(1, 999, 0)],
                    trackedIDs: [],
                    ownPID: 999
                )
                expect(pids).to(beEmpty())
            }

            it("skips malformed descriptions rather than guessing") {
                let malformed: [String: AnyObject] = [kCGWindowLayer as String: NSNumber(value: 0)]
                let pids = Manager.pidsOwningUntrackedWindows(
                    descriptions: [malformed, make(2, 200, 0)],
                    trackedIDs: [],
                    ownPID: 999
                )
                expect(pids) == [200]
            }
        }
    }
}
