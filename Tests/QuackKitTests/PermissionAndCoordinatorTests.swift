import Testing
@testable import QuackKit

@Suite struct PermissionStatusMapperTests {
    @Test func accessibilityMapping() {
        #expect(PermissionStatusMapper.accessibility(isTrusted: true) == .granted)
        #expect(PermissionStatusMapper.accessibility(isTrusted: false) == .notRequested)
    }

    @Test func screenRecordingMapping() {
        #expect(PermissionStatusMapper.screenRecording(hasAccess: true) == .granted)
        #expect(PermissionStatusMapper.screenRecording(hasAccess: false) == .notRequested)
    }

    @Test func screenRecordingIsAKnownPermissionKind() {
        #expect(PermissionKind.allCases.contains(.screenRecording))
        #expect(PermissionKind.screenRecording.displayName == "Screen Recording")
    }
}

@MainActor
private final class SpyService: ManagedService {
    var startCount = 0
    var stopCount = 0
    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
}

@Suite @MainActor struct AppCoordinatorTests {

    private func make(_ initial: QuackSettings) -> (AppCoordinator, SettingsStore, [Feature: SpyService]) {
        let store = SettingsStore(backing: InMemoryKeyValueStore(), key: "t")
        store.replace(with: initial)
        let services: [Feature: SpyService] = [
            .brightness: SpyService(), .temperature: SpyService(),
        ]
        let coord = AppCoordinator(store: store, services: services.mapValues { $0 as ManagedService })
        return (coord, store, services)
    }

    @Test func startsOnlyEnabledFeaturesOnActivate() {
        var s = QuackSettings()
        s.brightnessEnabled = false
        let (coord, _, services) = make(s)
        coord.activate()
        #expect(services[.brightness]!.startCount == 0)
        #expect(services[.temperature]!.startCount == 0)
    }

    @Test func flipFlagStartsAndStopsService() {
        var s = QuackSettings()
        s.brightnessEnabled = false
        let (coord, store, services) = make(s)
        coord.activate()
        #expect(services[.brightness]!.startCount == 0)

        store.update { $0.brightnessEnabled = true }
        #expect(services[.brightness]!.startCount == 1)

        store.update { $0.brightnessEnabled = false }
        #expect(services[.brightness]!.stopCount == 1)
    }
}
