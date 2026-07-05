import SwiftUI

/// The media player as a compact strip pinned at the bottom of the unified
/// notch panel: artwork + title/artist + transport controls.
struct MediaStripView: View {
    @ObservedObject var model: NotchContentViewModel

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(NotchTheme.hairline).frame(height: 1)
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.track?.payload.title ?? "Nothing playing")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(NotchTheme.textPrimary).lineLimit(1)
                    Text(model.track?.payload.artist ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(NotchTheme.textMuted).lineLimit(1)
                }
                Spacer(minLength: 8)
                if model.track != nil {
                    HStack(spacing: 14) {
                        button("backward.fill") { model.onPrevious?() }
                        button((model.track?.payload.isPlaying ?? false) ? "pause.fill" : "play.fill") { model.onToggle?() }
                        button("forward.fill") { model.onNext?() }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(NotchTheme.strip)
    }

    @ViewBuilder
    private var artwork: some View {
        if let art = model.track?.payload.artwork {
            Image(nsImage: art).resizable().aspectRatio(contentMode: .fit)
                .frame(width: 28, height: 28).clipShape(RoundedRectangle(cornerRadius: 5))
        } else {
            RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12))
                .frame(width: 28, height: 28)
                .overlay(Image(systemName: "music.note").font(.system(size: 12)).foregroundStyle(NotchTheme.textMuted))
        }
    }

    private func button(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Image(systemName: symbol).font(.system(size: 13))
            .contentShape(Rectangle()).onTapGesture(perform: action)
    }
}
