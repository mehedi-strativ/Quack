import Foundation
import AppKit
import AVFoundation

/// The selectable notification sounds for the "join now" toast: the bundled
/// Quack (default) plus four built-in macOS system sounds.
enum NotificationSound: String, CaseIterable, Identifiable {
    case quack, glass, ping, submarine, funk

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    /// macOS system sound name (in /System/Library/Sounds); nil = bundled Quack.
    var systemSoundName: String? {
        switch self {
        case .quack: return nil
        case .glass: return "Glass"
        case .ping: return "Ping"
        case .submarine: return "Submarine"
        case .funk: return "Funk"
        }
    }

    static func from(_ raw: String) -> NotificationSound { NotificationSound(rawValue: raw) ?? .quack }
}

/// Plays the selected notification sound.
@MainActor
final class QuackSound {
    private var quackPlayer: AVAudioPlayer?

    func play(_ sound: NotificationSound) {
        if let name = sound.systemSoundName {
            NSSound(named: name)?.play()
        } else {
            if quackPlayer == nil, let url = Bundle.main.url(forResource: "quack", withExtension: "mp3") {
                quackPlayer = try? AVAudioPlayer(contentsOf: url)
                quackPlayer?.prepareToPlay()
            }
            quackPlayer?.currentTime = 0
            quackPlayer?.play()
        }
    }
}
