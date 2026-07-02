import AppKit
import Combine
import MediaRemoteAdapter

@MainActor
final class NotchMediaViewModel: ObservableObject {
    @Published var isOpen = false
    @Published var track: TrackInfo?

    var onHoverChange: ((Bool) -> Void)?
    var onToggle: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
}
