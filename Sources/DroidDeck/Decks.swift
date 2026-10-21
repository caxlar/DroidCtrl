import SwiftUI

// MARK: - Kumanda güvertesi

struct ControlDeck: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var text = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {

            ModuleBox(title: "Gezinme") {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        TactileKey(icon: "chevron.left") { store.sendKey(.back) }
                        TactileKey(icon: "house.fill", subtitle: "Ana", prominent: true, wide: true) {
                            store.sendKey(.home)
                        }
                        TactileKey(icon: "chevron.up") { store.sendKey(.dpadUp) }
                        TactileKey(icon: "checkmark.circle") { store.sendKey(.dpadCenter) }
                        TactileKey(icon: "chevron.down") { store.sendKey(.dpadDown) }
                        TactileKey(icon: "chevron.right") { store.sendKey(.dpadRight) }
                        TactileKey(icon: "line.3.horizontal") { store.sendKey(.menu) }
                    }
                    HStack(spacing: 7) {
                        TactileKey(icon: "power") { store.sendKey(.power) }
                        TactileKey(icon: "info.circle") { store.sendKey(.info) }
                        TactileKey(icon: "magnifyingglass") { store.sendKey(.search) }
                        TactileKey(icon: "gearshape") { store.sendKey(.settings) }
                        TactileKey(icon: "chevron.up.2", subtitle: "Kanal", wide: true) { store.sendKey(.channelUp) }
                        TactileKey(icon: "chevron.down.2", subtitle: "Kanal", wide: true) { store.sendKey(.channelDown) }
                    }
                }
            }

            ModuleBox(title: "Medya") {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        TactileKey(icon: "backward.end.fill") { store.sendMedia(.previous) }
                        TactileKey(icon: "playpause.fill", prominent: true) { store.sendMedia(.playPause) }
                        TactileKey(icon: "forward.end.fill") { store.sendMedia(.next) }
                        TactileKey(icon: "speaker.slash.fill") { store.sendKey(.mute) }
                        TactileKey(icon: "speaker.wave.1.fill") { store.sendKey(.volumeDown) }
                        TactileKey(icon: "speaker.wave.3.fill") { store.sendKey(.volumeUp) }
                    }
                    HStack(spacing: 7) {
                        TactileKey(icon: "lock.open", subtitle: "Kilidi aç", wide: true) {
                            store.wakeAndUnlock()
                        }
                        TactileKey(icon: "camera.viewfinder", subtitle: "PNG", wide: true) {
                            store.screenshot()
                        }
                    }
                }
            }

            ModuleBox(title: "Klavye") {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        TextField("Cihaza yaz…", text: $text)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, 10)
                            .frame(height: 32)
                            .frame(width: 210)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke, lineWidth: 1))
                            .onSubmit(send)

                        GhostButton(icon: "paperplane.fill", title: "Gönder", prominent: true, action: send)
                    }
                    HStack(spacing: 7) {
                        TactileKey(icon: "return", subtitle: "Enter", wide: true) { store.sendRawKey(66) }
                        TactileKey(icon: "delete.left", subtitle: "Sil", wide: true) { store.sendRawKey(67) }
                        TactileKey(icon: "keyboard.chevron.compact.down", subtitle: "Gizle", wide: true) {
                            store.sendRawKey(111)   // ESC — klavyeyi kapatır
                        }
                    }
                    if !store.transferStatus.isEmpty {
                        Text(store.transferStatus)
                            .font(.metric(10.5))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(1)
                    }
                }
            }

            ModuleBox(title: "Kısayollar") {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        ForEach(store.apps.prefix(5)) { app in
                            Button {
                                store.launch(app)
                            } label: {
                                HStack(spacing: 8) {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Theme.accentGradient.opacity(0.85))
                                        .frame(width: 20, height: 20)
                                    Text(app.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 11)
                                .frame(height: 34)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
                                .overlay(RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Theme.stroke2, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                        if store.apps.count > 5 {
                            Text("+\(store.apps.count - 5)")
                                .font(.metric(11))
                                .foregroundStyle(Theme.ink3)
                                .padding(.leading, -2)
                        }
                    }
                    .fixedSize()

                    HStack(spacing: 14) {
                        HintKey(keys: ["⌘K"], text: "komut")
                        HintKey(keys: ["⌘E"], text: "tam ekran")
                        HintKey(keys: ["⌘U"], text: "ekranı aç")
                        HintKey(keys: ["Space"], text: "oynat")
                    }
                }
            }
        }
    }

    private func send() {
        guard !text.isEmpty else { return }
        store.sendText(text)
        text = ""
    }
}

private struct HintKey: View {
    let keys: [String]
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { k in
                Text(k)
                    .font(.metric(9.5))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.stroke2, lineWidth: 1))
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)
                .fixedSize()
        }
        .fixedSize()
    }
}

// MARK: - Ekran güvertesi

struct ScreenDeck: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ModuleBox(title: "Önizleme kalitesi") {
                HStack(spacing: 7) {
                    ForEach(PreviewQuality.allCases) { q in
                        Button {
                            store.previewQuality = q
                            if store.previewActive {
                                store.stopPreview()
                                store.startPreview()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(q.rawValue)
                                    .font(.system(size: 12, weight: .medium))
                                Text("\(q.maxSize)px · \(q.maxFPS) fps")
                                    .font(.metric(9))
                                    .foregroundStyle(Theme.ink3)
                            }
                            .padding(.horizontal, 11)
                            .frame(height: 40, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 9)
                                .fill(store.previewQuality == q
                                      ? Theme.accent.opacity(0.20) : Theme.panel))
                            .overlay(RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(store.previewQuality == q
                                              ? Theme.accent.opacity(0.42) : Theme.stroke,
                                              lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            ModuleBox(title: "Yayın") {
                HStack(spacing: 7) {
                    TactileKey(icon: store.previewActive ? "stop.fill" : "play.fill",
                               subtitle: store.previewActive ? "Durdur" : "Başlat",
                               prominent: true, wide: true) {
                        store.previewActive ? store.stopPreview() : store.startPreview()
                    }
                    TactileKey(icon: "arrow.clockwise", subtitle: "Yenile", wide: true) {
                        store.stopPreview()
                        store.startPreview()
                    }
                    TactileKey(icon: "camera.viewfinder", subtitle: "PNG", wide: true) {
                        store.screenshot()
                    }
                }
            }
        }
    }
}

// MARK: - Uygulamalar güvertesi

struct AppsDeck: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        ModuleBox(title: "Uygulamalar · \(store.labelStatus.isEmpty ? "\(store.apps.count)" : store.labelStatus)") {
            HStack(spacing: 8) {
                ForEach(store.apps) { app in
                    Button {
                        store.launch(app)
                    } label: {
                        VStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 9)
                                .fill(Theme.accentGradient.opacity(0.8))
                                .frame(width: 30, height: 30)
                            Text(app.displayName)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(Theme.ink2)
                                .lineLimit(1)
                                .frame(width: 62)
                        }
                        .padding(.vertical, 9)
                        .frame(width: 76)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 11)
                            .strokeBorder(Theme.stroke2, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("\(app.displayName)\n\(app.packageName)")
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Dosyalar güvertesi

struct FilesDeck: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ModuleBox(title: "Dosya gönder") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("APK, resim veya videoyu bu pencereye bırakın.\nAPK kurulur, diğerleri cihaza gönderilir.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink3)
                    if !store.transferStatus.isEmpty {
                        Text(store.transferStatus)
                            .font(.metric(11))
                            .foregroundStyle(Theme.ink2)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}

// MARK: - Bağlantı güvertesi

struct LinkDeck: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var text = ""

    var body: some View {
        ModuleBox(title: "Cihazda bağlantı aç") {
            HStack(spacing: 8) {
                TextField("https://…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 11)
                    .frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke, lineWidth: 1))
                    .onSubmit(send)

                GhostButton(icon: "arrow.up.right", title: "Cihazda Aç", prominent: true, action: send)

                if !store.transferStatus.isEmpty {
                    Text(store.transferStatus)
                        .font(.metric(11))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
            }
        }
    }

    private func send() {
        store.sendURL(text)
        text = ""
    }
}

// MARK: - Telemetri güvertesi

struct TelemetryDeck: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        ModuleBox(title: "Canlı telemetri") {
            HStack(spacing: 18) {
                Metric(label: "RAM",
                       value: store.telemetry.memUsedPercent.map { "\($0)%" } ?? "–",
                       detail: memDetail,
                       tone: tone(store.telemetry.memUsedPercent, warn: 85, bad: 95))
                Metric(label: "CPU",
                       value: store.telemetry.cpuPercent.map { "\(Int($0))%" } ?? "–",
                       detail: store.telemetry.cpuLoad1.map { String(format: "yük %.2f", $0) },
                       tone: tone(store.telemetry.cpuPercent.map { Int($0) }, warn: 80, bad: 95))
                Metric(label: "Pil",
                       value: store.telemetry.batteryPercent.map { "\($0)%" } ?? "–",
                       detail: store.telemetry.temperatureC.map { "\($0)°C" },
                       tone: Theme.ink)
                Metric(label: "Depolama",
                       value: store.telemetry.storageUsedPercent.map { "\($0)%" } ?? "–",
                       detail: storageDetail,
                       tone: tone(store.telemetry.storageUsedPercent, warn: 90, bad: 97))
                Metric(label: "Bağlantı",
                       value: store.telemetry.adbLatencyMS.map { "\($0) ms" } ?? "–",
                       detail: nil,
                       tone: tone(store.telemetry.adbLatencyMS.map { $0 / 10 }, warn: 25, bad: 100))

                Spacer()

                GhostButton(icon: "arrow.clockwise", title: "Yenile") {
                    store.refreshTelemetry()
                }
            }
        }
    }

    private func tone(_ v: Int?, warn: Int, bad: Int) -> Color {
        guard let v else { return Theme.ink }
        if v >= bad { return Theme.bad }
        if v >= warn { return Theme.warn }
        return Theme.ink
    }

    private var memDetail: String? {
        guard let total = store.telemetry.memTotalMB,
              let avail = store.telemetry.memAvailableMB else { return nil }
        return String(format: "%.1f / %.1f GB", Double(total - avail) / 1024, Double(total) / 1024)
    }

    private var storageDetail: String? {
        guard let used = store.telemetry.storageUsedGB,
              let total = store.telemetry.storageTotalGB else { return nil }
        return String(format: "%.0f / %.0f GB", used, total)
    }
}

// MARK: - Ayarlar güvertesi

struct SettingsDeck: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ModuleBox(title: "Araçlar") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.adbPath.map { "adb: \($0)" } ?? "adb bulunamadı")
                        .font(.metric(10.5))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        GhostButton(icon: "arrow.triangle.2.circlepath", title: "ADB'yi yeniden başlat") {
                            store.restartADBServer()
                        }
                        GhostButton(icon: "arrow.clockwise", title: "Araç yollarını yenile") {
                            store.reloadToolPaths()
                        }
                    }
                }
            }
        }
    }
}
