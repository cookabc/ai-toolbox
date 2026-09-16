import AppKit
import SwiftUI

/// Sizes the menu-bar panel to its content and pins its **top** edge to the bottom of
/// the menu bar.
///
/// The panel is content-fitted so it never leaves a blank area under short content, but
/// a fitted height means the window's size changes as you switch tools — and two
/// separate things go wrong when it does.
///
/// 1. **The window is left larger than its content.** `MenuBarExtra` sizes its window
///    from the content, but the two do not stay in lockstep: the window measured 593pt
///    while the content had already settled at 323pt. The window has no background of
///    its own, so the 270pt the content does not cover is simply transparent — which
///    reads as an empty panel hanging between the menu-bar icon and the content. So the
///    frame is set here, explicitly, instead of being left to follow.
///
/// 2. **A height change moves the top.** AppKit resizes a window by keeping its
///    *origin* (bottom-left), so a panel that hangs off the menu bar drifts away from
///    the icon every time it shrinks.
///
/// Both are fixed in a single `setFrame`, which is the point: the new origin is computed
/// from the new height, so the panel is never observable in a state where one has been
/// applied and the other has not.
///
/// The target comes from the **screen**, never from the window — a window whose top has
/// already slipped is the one thing you cannot use to decide where the top should be,
/// because doing so *ratifies* the drift.
struct PanelTopAnchor: NSViewRepresentable {
    /// The height the content needs, chrome included. `nil` leaves the window's height
    /// alone and only anchors the top, which is what makes the anchor usable on a window
    /// whose size is driven from elsewhere.
    var height: CGFloat?

    func makeNSView(context: Context) -> NSView { AnchorView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        MainActor.assumeIsolated {
            (nsView as? AnchorView)?.apply(height: height)
        }
    }

    @MainActor
    final class AnchorView: NSView {
        private var observers: [NSObjectProtocol] = []
        private var watchdog: Timer?
        private var desiredHeight: CGFloat?
        /// Consecutive watchdog ticks that found the frame wrong. Correction waits for a
        /// few so a frame that is merely mid-layout is left alone.
        private var missedTicks = 0
        /// After a correction the watchdog stands down briefly, so a system placement
        /// that disagrees with us cannot turn into a fast oscillation.
        private var cooldownUntil = Date.distantPast

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            stopWatchdog()
            guard let window else { return }
            let center = NotificationCenter.default
            // didResize / didMove: the frame changed underneath us, so re-apply.
            // didBecomeKey: the system has just (re)placed the panel as it opened.
            // didChangeScreen: the reference moved, so re-anchor on the new display.
            // They are safe to observe because the target is absolute — a correction is
            // a no-op when the panel is already right.
            for name in [
                NSWindow.didResizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didChangeScreenNotification,
            ] {
                observers.append(center.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncFrame() }
                })
            }
            // The display arrangement changed, so the menu bar may have moved with it.
            observers.append(center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncFrame() }
            })
            // Correct immediately: the panel may already be wrong before this view
            // entered the hierarchy, and waiting for the next resize would leave that
            // on screen indefinitely.
            syncFrame()
            startWatchdog()
        }

        func apply(height: CGFloat?) {
            guard let height else { return }
            guard abs(height - (desiredHeight ?? -1)) > 0.5 else { return }
            desiredHeight = height
            syncFrame()
        }

        /// The menu bar's bottom edge on the screen the window is actually on.
        ///
        /// `visibleFrame` is per-screen and excludes that screen's menu bar, so its
        /// `maxY` is exactly where a menu-bar panel's top belongs. A screen *without* a
        /// menu bar (measured: inset 0) yields the screen top, which is also the right
        /// answer — there is nothing to hang from there.
        ///
        /// Only `window.screen` is consulted, never `NSScreen.main`. `main` follows the
        /// key window and was measured returning different screens within a single
        /// process, and a screen that is not the panel's own would pin the panel to a
        /// completely wrong place. When `screen` is momentarily nil the caller does
        /// nothing — the watchdog retries, which is far safer than a wrong jump.
        ///
        /// `NSStatusBar.system.thickness` is deliberately not used either: it reports
        /// 22pt while the actual reserve measures 33pt here, so it would pin the panel
        /// too high.
        private static func menuBarBottom(for window: NSWindow) -> CGFloat? {
            window.screen?.visibleFrame.maxY
        }

        /// The frame's height for a given content height. A borderless window's frame is
        /// its content rect, but deriving the difference keeps this correct if the panel
        /// ever gains a title bar.
        private static func frameHeight(for contentHeight: CGFloat, window: NSWindow) -> CGFloat {
            let frame = window.frame
            return contentHeight + (frame.height - window.contentRect(forFrameRect: frame).height)
        }

        private static func currentContentHeight(_ window: NSWindow) -> CGFloat {
            window.contentRect(forFrameRect: window.frame).height
        }

        /// Applies the content's height and the menu-bar anchoring together.
        ///
        /// Corrects in **both** directions, because both are wrong: keeping the origin
        /// means shrinking content drags the top down while growing content pushes it up
        /// under the menu bar. Snapping to one fixed, screen-derived target makes the
        /// result deterministic and convergent — repeated corrections agree instead of
        /// oscillating.
        private func syncFrame() {
            guard let window, let menuBarBottom = Self.menuBarBottom(for: window) else { return }
            let height = Self.frameHeight(
                for: desiredHeight ?? Self.currentContentHeight(window),
                window: window
            )
            // Leave the window alone when it already matches: this runs from several
            // observers, and re-setting an identical frame is what turns a correction
            // into a feedback loop.
            guard abs(window.frame.height - height) > 0.5
                    || abs(window.frame.maxY - menuBarBottom) > 0.5 else {
                missedTicks = 0
                return
            }
            window.setFrame(
                NSRect(
                    x: window.frame.minX,
                    y: menuBarBottom - height,
                    width: window.frame.width,
                    height: height
                ),
                display: true
            )
            missedTicks = 0
            cooldownUntil = Date().addingTimeInterval(0.3)
        }

        private func startWatchdog() {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            watchdog = timer
            // `.common` rather than the default mode: the default does not run while a
            // menu or a mouse-tracking loop is being tracked, which is exactly when the
            // panel is on screen.
            RunLoop.main.add(timer, forMode: .common)
        }

        /// Notifications cover the cases we can name; this covers the ones we cannot.
        /// A menu-bar panel can be placed — or re-placed — without a resize we observe,
        /// so the frame is also checked on a timer. It needs the mismatch to persist
        /// across consecutive ticks before acting, so it never fights a transient layout
        /// pass, and it stands down after each correction.
        private func tick() {
            // `isVisible` is the usual signal; occlusion and key status are belt and
            // braces, because a panel that reports neither would leave the watchdog
            // silent on exactly the frame it exists to catch.
            guard let window,
                  window.isVisible || window.isKeyWindow || window.occlusionState.contains(.visible)
            else {
                missedTicks = 0
                return
            }
            guard let menuBarBottom = Self.menuBarBottom(for: window) else { return }
            let height = Self.frameHeight(
                for: desiredHeight ?? Self.currentContentHeight(window),
                window: window
            )
            guard abs(window.frame.height - height) > 0.5
                    || abs(window.frame.maxY - menuBarBottom) > 0.5 else {
                missedTicks = 0
                return
            }
            guard Date() >= cooldownUntil else { return }
            missedTicks += 1
            guard missedTicks >= 2 else { return }
            syncFrame()
            missedTicks = 0
            cooldownUntil = Date().addingTimeInterval(0.5)
        }

        private func stopWatchdog() {
            watchdog?.invalidate()
            watchdog = nil
        }

        private func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        isolated deinit {
            MainActor.assumeIsolated {
                stopObserving()
                stopWatchdog()
            }
        }
    }
}
