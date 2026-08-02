// Sources/Quack/MenuBar/MenuBarCrushMonitor.swift
import AppKit
import QuackKit

/// Watches Quack's own 4 menu-bar items (duck, countdown, CPU-temp, activity
/// timer) and, when the notch crushes one, hides lower-priority items to free
/// space — then reveals them again once it's stably safe. See
/// docs/superpowers/specs/2026-08-02-menu-bar-crush-guard-design.md.
///
/// Deliberately much simpler than the removed hidden-bar feature: these are
/// items Quack owns directly, so `button.window.frame` is real, readable
/// AppKit state regardless of window-server capture/mapping status. No AX,
/// no CGWindowList, no screen recording.
@MainActor
final class MenuBarCrushMonitor {

    /// One of Quack's own items, described entirely through closures so this
    /// file doesn't need to know how each owner stores/hides its item.
    struct Participant {
        let id: String
        let priority: Int
        let frameMinX: () -> CGFloat?
        let isVisible: () -> Bool
        let setHidden: (Bool) -> Void
    }

    private let participants: [Participant]
    private let screenReader = NotchScreenReader()
    private var crushHidden: Set<String> = []
    private var clearStreak = 0
    private var timer: Timer?

    init(participants: [Participant]) {
        self.participants = participants
    }

    /// Wires up the real 4 items in their approved priority order:
    /// duck > countdown > temperature > timer.
    static func makeDefault(env: AppEnvironment, statusController: StatusItemController) -> MenuBarCrushMonitor {
        MenuBarCrushMonitor(participants: [
            Participant(
                id: "duck", priority: 0,
                frameMinX: { [weak statusController] in statusController?.duckFrameMinX },
                isVisible: { [weak statusController] in statusController?.duckIsVisible ?? false },
                setHidden: { [weak statusController] hidden in statusController?.setDuckCrushHidden(hidden) }
            ),
            Participant(
                id: "countdown", priority: 1,
                frameMinX: { [weak statusController] in statusController?.countdownFrameMinX },
                isVisible: { [weak statusController] in statusController?.countdownIsVisible ?? false },
                setHidden: { [weak statusController] hidden in statusController?.setCountdownCrushHidden(hidden) }
            ),
            Participant(
                id: "temperature", priority: 2,
                frameMinX: { [weak env] in env?.temperatureMenuBarItem?.button?.window?.frame.minX },
                isVisible: { [weak env] in env?.temperatureMenuBarItem?.isVisible ?? false },
                setHidden: { [weak env] hidden in env?.temperatureMenuBarItem?.isVisible = !hidden }
            ),
            Participant(
                id: "timer", priority: 3,
                frameMinX: { [weak env] in env?.timeAwarenessMenuBarItem?.button?.window?.frame.minX },
                isVisible: { [weak env] in env?.timeAwarenessMenuBarItem?.isVisible ?? false },
                setHidden: { [weak env] hidden in env?.timeAwarenessMenuBarItem?.isVisible = !hidden }
            ),
        ])
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let notch = screenReader.currentLayout()?.span

        var items: [MenuBarCrushGuard.Item] = []
        for p in participants {
            guard let minX = p.frameMinX() else { continue }   // item not created yet
            let visible = p.isVisible()
            // Something external (e.g. the user re-enabling a toggle) made a
            // previously crush-hidden item visible again — drop our own
            // bookkeeping so we don't later fight that.
            if visible { crushHidden.remove(p.id) }
            items.append(.init(id: p.id, priority: p.priority, isVisible: visible, frameMinX: minX))
        }

        let decision = MenuBarCrushGuard.decide(items: items, notch: notch, clearStreak: clearStreak)
        switch decision.action {
        case .hide(let id):
            crushHidden.insert(id)
            participants.first { $0.id == id }?.setHidden(true)
        case .reveal(let id):
            crushHidden.remove(id)
            participants.first { $0.id == id }?.setHidden(false)
        case nil:
            break
        }
        clearStreak = decision.isClear ? clearStreak + 1 : 0
    }
}
