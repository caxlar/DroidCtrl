import SwiftUI

// MARK: - Bölümler

enum StudioSection: String, CaseIterable, Identifiable {
    case control = "Kumanda"
    case screen = "Ekran"
    case apps = "Uygulamalar"
    case files = "Dosyalar"
    case link = "Bağlantı"
    case telemetry = "Telemetri"
    case settings = "Ayarlar"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .control: return "gamecontroller"
        case .screen: return "desktopcomputer"
        case .apps: return "square.grid.2x2"
        case .files: return "tray.and.arrow.down"
        case .link: return "link"
        case .telemetry: return "waveform.path.ecg"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Kabuk

struct StudioShell: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var section: StudioSection = .control

    var body: some View {
        HStack(spacing: 0) {
            IconRail(selection: $section)
                .frame(width: Theme.railWidth)

            VStack(spacing: 0) {
                TopBar()
                    .frame(height: Theme.topBarHeight)

                VStack(spacing: 14) {
                    StageHeader(section: section)
                    StageScreen()
                    DeckSection(section: section)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 16)
            }
        }
        .background(StudioBackground())
        .preferredColorScheme(.dark)
        // Dosyayı pencereye bırak → APK kurulur, diğerleri cihaza gönderilir.
        .dropDestination(for: URL.self) { urls, _ in
            store.handleDroppedFiles(urls)
            return true
        }
    }
}

// MARK: - Üst çubuk

private struct TopBar: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Theme.accentGradient)
                    .frame(width: 24, height: 24)
                Text("DroidDeck")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }

            // Cihaz seçici
            Menu {
                ForEach(store.devices) { device in
                    Button {
                        store.selectedDeviceID = device.id
                    } label: {
                        if device.id == store.selectedDevice?.id {
                            Label(device.displayName, systemImage: "checkmark")
                        } else {
                            Text(device.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(store.selectedDevice?.state.isControllable == true
                              ? Theme.good : Theme.ink3)
                        .frame(width: 7, height: 7)
                    Text(store.selectedDevice?.displayName ?? "Cihaz seçilmedi")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                }
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke, lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()

            // Komut alanı (⌘K)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                Text("Komut veya cihazda ara…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink3)
                Spacer()
                Text("⌘K")
                    .font(.metric(10))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.stroke2, lineWidth: 1))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: 400)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke, lineWidth: 1))

            Spacer()

            // Telemetri özeti — hiç değer yoksa kutu çizilmez (boş kare kalmasın)
            if hasMetrics {
                HStack(spacing: 10) {
                    if let ram = store.telemetry.memUsedPercent {
                        Text("RAM").font(.metric(10)).foregroundStyle(Theme.ink3)
                        Text("\(ram)%").font(.metric(11.5)).foregroundStyle(Theme.ink)
                    }
                    if let cpu = store.telemetry.cpuPercent {
                        Text("CPU").font(.metric(10)).foregroundStyle(Theme.ink3)
                        Text("\(Int(cpu))%").font(.metric(11.5)).foregroundStyle(Theme.ink)
                    }
                    if let t = store.telemetry.temperatureC {
                        Text("\(t)°C").font(.metric(11.5))
                            .foregroundStyle(t >= 38 ? Theme.warn : Theme.ink2)
                    }
                }
                .fixedSize()
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke2, lineWidth: 1))
            }

            if let bat = store.telemetry.batteryPercent {
                HStack(spacing: 5) {
                    Image(systemName: "battery.75")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                    Text("\(bat)%").font(.metric(11.5)).foregroundStyle(Theme.ink)
                }
                .fixedSize()
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke2, lineWidth: 1))
            }
        }
        .padding(.horizontal, 16)
        .background(Color.white.opacity(0.035))
        .overlay(
            Rectangle().fill(Theme.stroke2).frame(height: 1),
            alignment: .bottom
        )
    }

    private var hasMetrics: Bool {
        store.telemetry.memUsedPercent != nil
            || store.telemetry.cpuPercent != nil
            || store.telemetry.temperatureC != nil
    }
}

// MARK: - İkon rayı

private struct IconRail: View {
    @Binding var selection: StudioSection

    var body: some View {
        VStack(spacing: 4) {
            ForEach(StudioSection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    ZStack {
                        if selection == section {
                            RoundedRectangle(cornerRadius: 11)
                                .fill(Theme.accent.opacity(0.17))
                        }
                        Image(systemName: section.icon)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(selection == section ? Theme.accent : Theme.ink3)
                    }
                    .frame(width: 42, height: 42)
                    .overlay(alignment: .leading) {
                        if selection == section {
                            Capsule()
                                .fill(Theme.accent)
                                .frame(width: 3, height: 20)
                                .shadow(color: Theme.accent.opacity(0.8), radius: 6)
                                .offset(x: -13)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(section.rawValue)
            }

            Spacer()
        }
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.018))
        .overlay(
            Rectangle().fill(Theme.stroke2).frame(width: 1),
            alignment: .trailing
        )
    }
}

// MARK: - Sahne başlığı

private struct StageHeader: View {
    @EnvironmentObject private var store: DeviceStore
    let section: StudioSection

    var body: some View {
        HStack(spacing: 12) {
            Text(section.rawValue)
                .font(.cardTitle)
                .foregroundStyle(Theme.ink)

            if store.previewActive {
                Pill(kind: .live,
                     text: "● CANLI\(store.telemetry.adbLatencyMS.map { " · \($0) ms" } ?? "")")
            } else {
                Pill(kind: .neutral, text: "Yayın kapalı")
            }

            Spacer()

            GhostButton(icon: "camera.viewfinder", title: "Ekran görüntüsü") {
                store.screenshot()
            }
            GhostButton(icon: "arrow.up.left.and.arrow.down.right", title: "Tam ekran") {
                store.openScrcpy()
            }
            GhostButton(icon: "lock.open", title: "Ekranı aç", prominent: true) {
                store.wakeAndUnlock()
            }
        }
    }
}

// MARK: - Sahne ekranı

private struct StageScreen: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        ZStack {
            // Canlı ışıma — cihazın "canlı" olduğunu hissettirir.
            if store.previewActive {
                Ellipse()
                    .fill(Theme.accent.opacity(0.22))
                    .frame(width: 620, height: 380)
                    .blur(radius: 60)
                    .allowsHitTesting(false)
            }

            RoundedRectangle(cornerRadius: 16)
                .fill(Color(hex: 0x05070A))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.6), radius: 34, y: 18)

            if store.previewActive {
                VideoSurface()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            } else {
                VStack(spacing: 12) {
                    Button {
                        store.startPreview()
                    } label: {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 58))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .buttonStyle(.plain)
                    .help("Önizlemeyi başlat")

                    Text("Ekranı Göster")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 340)
        .clipped()
    }
}

// MARK: - Güverte (bölüme göre değişir)

private struct DeckSection: View {
    @EnvironmentObject private var store: DeviceStore
    let section: StudioSection

    var body: some View {
        switch section {
        case .control:
            ControlDeck()
        case .screen:
            ScreenDeck()
        case .apps:
            AppsDeck()
        case .files:
            FilesDeck()
        case .link:
            LinkDeck()
        case .telemetry:
            TelemetryDeck()
        case .settings:
            SettingsDeck()
        }
    }
}
