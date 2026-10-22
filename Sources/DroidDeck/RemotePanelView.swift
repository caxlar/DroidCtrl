import SwiftUI
import AppKit

struct RemotePanelView: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Group {
            if let device = store.selectedDevice {
                ScrollView {
                    RemotePanelContent(device: device)
                        .padding(20)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                ContentUnavailableView {
                    Label("no_devices_scan_main", systemImage: "tv.and.mediabox")
                } description: {
                    Text("select_device_first")
                } actions: {
                    HStack(spacing: 10) {
                        Button("scan_devices") {
                            store.refresh()
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            store.recoverConnection()
                        } label: {
                            Label("retry", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .help("restart_required")
                    }
                }
            }
        }
        .navigationTitle(store.selectedDevice?.displayName ?? "DroidCtrl")
    }
}

/// Kumanda panelinin asıl içeriği. `--render` ile düzen doğrulaması için
/// ScrollView'dan ayrı tutulur.
struct RemotePanelContent: View {
    @EnvironmentObject private var store: DeviceStore
    let device: AndroidDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Header(device: device)

            // Durum panosu / canlı telemetri — yalnızca okur, cihaza yük bindirmez.
            TelemetryStrip(telemetry: store.telemetry) {
                store.refreshTelemetry()
            }

            HStack(alignment: .top, spacing: 16) {
                NavigationCard()
                PreviewCard()
                TextCard()
            }

            // Bağlantı onarımı: cihaz seçiliyken Header'da küçük ve yerinde.
            HStack {
                Spacer()
                Button {
                    store.recoverConnection()
                } label: {
                    Label("repair_connection", systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)
                .help("repair_connection_help")
            }

            Card(title: "Hızlı Erişim", icon: "bolt") {
                HStack(alignment: .top, spacing: 24) {
                    UnlockPanel(store: store)
                    Divider().frame(height: 64)
                    LinkPanel(store: store)
                        .frame(maxWidth: 380)
                }
                TransferStatusView(status: store.transferStatus)
            }

            AppsCard()
        }
        // Dosyayı pencereye bırak → APK kurulur, diğerleri cihaza gönderilir.
        .dropDestination(for: URL.self) { urls, _ in
            store.handleDroppedFiles(urls)
            return true
        }
    }
}

// MARK: - Başlık

private struct Header: View {
    @EnvironmentObject private var store: DeviceStore
    let device: AndroidDevice

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: DeviceIcon.name(for: device))
                .font(.system(size: 34))
                .foregroundStyle(Color.blue)
                .frame(width: 52, height: 52)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(device.displayName)
                        .font(.title2.weight(.semibold))
                    StateBadge(state: device.state)
                }
                Text(device.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                store.openScrcpy()
            } label: {
                Label("Tam Ekran", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(store.scrcpyPath == nil || !device.state.isControllable)
            .help(store.scrcpyPath == nil
                  ? "scrcpy kurulu değil — brew install scrcpy"
                  : "Cihaz ekranını ayrı, büyük bir pencerede açar. Küçük önizleme için 'Ekran' kartındaki ▶ butonunu kullanın.")

            Button {
                store.refresh()
            } label: {
                Label("Yenile", systemImage: "arrow.clockwise")
            }
            .controlSize(.large)
        }
    }
}

// MARK: - Yeniden kullanılabilir buton

struct RemoteButton: View {
    let icon: String
    let title: String
    var isProminent: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .medium))
                Text(LocalizedStringKey(title))
                    .font(.caption2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: 68, height: 58)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(isProminent ? Color.blue.opacity(0.20) : Color.gray.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(Color.gray.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Gezinme kartı

struct NavigationCard: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Card(title: "Gezinme", icon: "dpad") {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    RemoteButton(icon: "arrow.uturn.left", title: "Geri") {
                        store.sendKey(.back)
                    }
                    RemoteButton(icon: "house.fill", title: "Ana Sayfa") {
                        store.sendKey(.home)
                    }
                    RemoteButton(icon: "ellipsis", title: "Menü") {
                        store.sendKey(.menu)
                    }
                }

                HStack(spacing: 10) {
                    RemoteButton(icon: "chevron.up", title: "Yukarı") {
                        store.sendKey(.dpadUp)
                    }
                    RemoteButton(icon: "circle.fill", title: "Tamam", isProminent: true) {
                        store.sendKey(.dpadCenter)
                    }
                    RemoteButton(icon: "chevron.down", title: "Aşağı") {
                        store.sendKey(.dpadDown)
                    }
                }

                HStack(spacing: 10) {
                    RemoteButton(icon: "chevron.left", title: "Sol") {
                        store.sendKey(.dpadLeft)
                    }
                    RemoteButton(icon: "gearshape.fill", title: "Ayarlar") {
                        store.sendKey(.settings)
                    }
                    RemoteButton(icon: "chevron.right", title: "Sağ") {
                        store.sendKey(.dpadRight)
                    }
                }

                HStack(spacing: 10) {
                    RemoteButton(icon: "power", title: "Güç") {
                        store.sendKey(.power)
                    }
                    RemoteButton(icon: "info.circle.fill", title: "Bilgi") {
                        store.sendKey(.info)
                    }
                    RemoteButton(icon: "magnifyingglass", title: "Ara") {
                        store.sendKey(.search)
                    }
                }

                Divider().padding(.vertical, 2)

                // İnce ses satırı (medya kartının yerine geçiyor)
                HStack(spacing: 10) {
                    RemoteButton(icon: "speaker.wave.1.fill", title: "Ses −") {
                        store.sendKey(.volumeDown)
                    }
                    RemoteButton(icon: "speaker.slash.fill", title: "Sessiz") {
                        store.sendKey(.mute)
                    }
                    RemoteButton(icon: "speaker.wave.3.fill", title: "Ses +") {
                        store.sendKey(.volumeUp)
                    }
                }
            }
        }
    }
}

// MARK: - Ekran önizleme kartı

struct PreviewCard: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Card(title: "Ekran", icon: "desktopcomputer") {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black)

                    if store.previewActive {
                        VideoSurface()
                    } else {
                        VStack(spacing: 8) {
                            Button {
                                store.startPreview()
                            } label: {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 46))
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                            .buttonStyle(.plain)
                            .help("start_preview_help")

                            Text("show_screen")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }

                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                store.openScrcpy()
                            } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(Color.black.opacity(0.55), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .help("fullscreen_help")
                        }
                        Spacer()
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 232)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.gray.opacity(0.22), lineWidth: 1)
                )

                HStack(spacing: 8) {
                    if store.previewActive {
                        Button {
                            store.stopPreview()
                        } label: {
                            Label("Durdur", systemImage: "stop.fill")
                        }
                        .controlSize(.small)

                        Button {
                            store.stopPreview()
                            store.startPreview()
                        } label: {
                            Label("Yenile", systemImage: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .help("restart_preview_help")
                    } else {
                        Button {
                            store.startPreview()
                        } label: {
                            Label("show_screen", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    Button {
                        store.openScrcpy()
                    } label: {
                        Label("zoom", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .controlSize(.small)

                    Spacer()

                    if let temperature = store.deviceTemperature {
                        Label("\(temperature)°C",
                              systemImage: temperature >= ThermalLimit.warnCelsius
                                  ? "thermometer.high" : "thermometer.medium")
                            .font(.caption2)
                            .foregroundStyle(temperature >= ThermalLimit.warnCelsius ? Color.orange : Color.secondary)
                            .help(String(format: NSLocalizedString("thermal_info", comment: ""), ThermalLimit.stopCelsius))
                    }

                    if !store.previewStatus.isEmpty {
                        Text(store.previewStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                // Cihaza bindirilen yük — encoder yükü ≈ piksel × kare hızı.
                HStack(spacing: 8) {
                    Text("device_load")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Picker("Kalite", selection: $store.previewQuality) {
                        ForEach(PreviewQuality.allCases) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .labelsHidden()
                    .frame(width: 140)

                    Text("\(store.previewQuality.detail)  ·  \(String(format: "%.1f", store.previewQuality.megapixelsPerSecond)) MP/s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer()
                }
                            .help("quality_low_desc")
                        }
                    }
                }
}

// MARK: - Klavye kartı

struct TextCard: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var text = ""

    var body: some View {
        Card(title: "Klavye", icon: "keyboard.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("write_focused")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            TextField(LocalizedStringKey("type_text_placeholder"), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        store.sendText(text)
                        text = ""
                    }

                HStack(spacing: 8) {
                    Button("send") {
                        store.sendText(text)
                        text = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)

                    Button("Temizle") {
                        text = ""
                    }
                }

                Divider().padding(.vertical, 2)

                Text("shortcuts")
                    .font(.caption.weight(.semibold))

                HStack(spacing: 10) {
                    RemoteButton(icon: "return", title: "Enter") {
                        store.sendRawKey(66)
                    }
                    RemoteButton(icon: "delete.left.fill", title: "Sil") {
                        store.sendRawKey(67)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Uygulamalar kartı

struct AppsCard: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        Card(title: "Uygulamalar", icon: "square.grid.2x2.fill") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Uygulama ara…", text: $store.appFilter)
                        .textFieldStyle(.plain)

                    Button {
                        store.loadApps()
                    } label: {
                        Label("Listele", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isLoadingApps || store.selectedDevice?.state.isControllable != true)

                    Button {
                        store.resetLabels()
                    } label: {
                        Image(systemName: "arrow.counterclockwise.circle")
                    }
                    .controlSize(.small)
                    .disabled(store.isLoadingApps || store.selectedDevice?.state.isControllable != true)
                    .help("reset_labels_help")

                    if store.isLoadingApps {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if !store.labelStatus.isEmpty {
                        Text(store.labelStatus)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

                if store.apps.isEmpty {
                    Text("app_list_empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 18)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                        ForEach(store.filteredApps) { app in
                            AppTile(app: app)
                        }
                    }
                }
            }
        }
    }
}

struct AppTile: View {
    @EnvironmentObject private var store: DeviceStore
    let app: AndroidApp

    var body: some View {
        Button {
            store.launch(app)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(app.packageName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("open") { store.launch(app) }
            Button("Durdur") { store.forceStop(app) }
            Button("copy_package_name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.packageName, forType: .string)
            }
        }
    }
}

// MARK: - Kart kabı

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(.secondary)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.gray.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.gray.opacity(0.18), lineWidth: 1)
        )
    }
}
