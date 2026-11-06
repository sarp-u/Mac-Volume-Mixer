import AudioRouterCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var router: RouterManager

    private var height: CGFloat {
        let contentHeight = max(180, CGFloat(router.apps.count) * 64 + 45)
        let screenHeight = max(180, (NSScreen.main?.visibleFrame.height ?? 800) - 80)
        return min(contentHeight, screenHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            MixerList()
            Divider()

            HStack {
                if let error = router.lastError {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button {
                    router.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Uygulama listesini yenile")

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(.borderless)
                .help("Çık")
            }
            .padding(10)
        }
        .frame(width: 430, height: height)
    }
}

private struct MixerList: View {
    @EnvironmentObject private var router: RouterManager

    var body: some View {
        Group {
            if router.apps.isEmpty {
                ContentUnavailableView(
                    "Ses uygulaması bulunamadı",
                    systemImage: "speaker.slash",
                    description: Text("Bir uygulamada ses başlatıp yenile düğmesine bas.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(router.apps) { app in
                            AppVolumeRow(app: app)
                            Divider().padding(.leading, 48)
                        }
                    }
                }
            }
        }
    }
}

private struct AppVolumeRow: View {
    let app: RoutedApp
    @EnvironmentObject private var router: RouterManager

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.group?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed")
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(app.name).fontWeight(.medium).lineLimit(1)
                    if app.isPlaying { Circle().fill(.green).frame(width: 6, height: 6) }
                    if app.isStarting { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("\(Int((app.settings.volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        router.setMuted(!app.settings.muted, forKey: app.key)
                    } label: {
                        Image(systemName: app.settings.muted ? "speaker.slash.fill" : "speaker.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(app.settings.muted ? .red : .secondary)

                    Slider(
                        value: Binding(
                            get: { app.settings.volume },
                            set: { router.setVolume($0, forKey: app.key) }
                        ),
                        in: 0...1
                    )
                }

                if let error = app.error {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .opacity(app.isRunning ? 1 : 0.55)
    }
}
