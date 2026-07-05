// Sources/Quack/Mouse/MouseService.swift
import Foundation
import Combine
import QuackKit

/// Umbrella service for `Feature.mouse`. The coordinator starts/stops it when
/// the umbrella flag flips (any mouse sub-feature on); internally each unit
/// tracks its own toggle, so e.g. enabling smooth scrolling never installs
/// the button tap.
@MainActor
final class MouseService: ManagedService {
    let sensitivity: MouseSensitivityService
    private let smoother: ScrollSmootherService
    private let buttons: MouseButtonService

    private let settings: SettingsStore
    private var cancellable: AnyCancellable?
    private var started = false

    init(settings: SettingsStore, permissions: PermissionsManager) {
        self.settings = settings
        self.sensitivity = MouseSensitivityService(settings: settings)
        self.smoother = ScrollSmootherService(settings: settings, permissions: permissions)
        self.buttons = MouseButtonService(settings: settings, permissions: permissions)
    }

    func start() {
        guard !started else { return }
        started = true
        applyFlags()
        cancellable = settings.$settings
            .map { (sens: $0.mouseSensitivityEnabled,
                    scroll: $0.smoothScrollEnabled,
                    b4: $0.mouseButton4Action, b5: $0.mouseButton5Action) }
            .removeDuplicates(by: ==)
            .sink { [weak self] _ in Task { @MainActor in self?.applyFlags() } }
    }

    func stop() {
        guard started else { return }
        started = false
        cancellable = nil
        sensitivity.stop()
        smoother.stop()
        buttons.stop()
    }

    private func applyFlags() {
        let s = settings.settings
        s.mouseSensitivityEnabled ? sensitivity.start() : sensitivity.stop()
        s.smoothScrollEnabled ? smoother.start() : smoother.stop()
        let buttonsWanted = s.mouseButton4Action != MouseButtonAction.default_.rawValue
            || s.mouseButton5Action != MouseButtonAction.default_.rawValue
        buttonsWanted ? buttons.start() : buttons.stop()
    }
}
