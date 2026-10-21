import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            RemotePanelView()
        }
        .frame(minWidth: 980, minHeight: 640)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusBar()
        }
        .sheet(isPresented: $store.showPairingSheet) {
            PairingView()
        }
    }
}

// MARK: - Kenar çubuğu

struct SidebarView: View {
    @EnvironmentObject private var store: DeviceStore
    @State private var showManualConnect = true

    var body: some View {
        List(selection: $store.selectedDeviceID) {
            Section("Cihazlar") {
                if store.devices.isEmpty {
                    Label("Kayıtlı cihaz yok", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.devices) { device in
                    DeviceRow(device: device)
                        .tag(device.id)
                        .contextMenu {
                            Button("Bağlantıyı Kes") {
                                store.disconnect(device)
                            }
                            .disabled(device.connection != .wifi)
                        }
                }
            }

            Section("Ağda Bulunanlar (mDNS)") {
                if store.undiscoveredMDNS.isEmpty {
                    Text("mDNS servisi görünmüyor")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.undiscoveredMDNS) { service in
                    MDNSRow(service: service)
                }
            }

            Section {
                DisclosureGroup(isExpanded: $showManualConnect) {
                    TextField("192.168.1.4:5555", text: $store.manualEndpoint)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { store.connect(to: store.manualEndpoint) }

                    HStack(spacing: 6) {
                        Button {
                            store.connect(to: store.manualEndpoint)
                        } label: {
                            Label("Bağlan", systemImage: "link")
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.manualEndpoint.trimmingCharacters(in: .whitespaces).isEmpty)

                        Button {
                            let ip = store.manualEndpoint
                                .split(separator: ":").first
                                .map(String.init)?
                                .trimmingCharacters(in: .whitespaces) ?? ""
                            store.beginPairing(ip: ip)
                        } label: {
                            Label("Eşleştir", systemImage: "link.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .help("İlk kez bağlanıyorsanız eşleştirme gerekir. Adımlar sihirbazda anlatılır.")
                    }

                    Text("Telefon/tablet: **Kablosuz hata ayıklama** açık olmalı ve port 5555 değil, rastgele bir sayıdır. En kolayı sağdaki listeden **Eşleştir**'e basmak. Android TV'lerde genelde IP:5555 kullanılır.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Label("Elle Bağlan", systemImage: "network")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("DroidDeck")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refresh()
                } label: {
                    Label("Yenile", systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanning)
                .help("Cihazları ve mDNS servislerini yeniden tara")
            }
        }
    }
}

// MARK: - Satır görünümleri

struct DeviceRow: View {
    let device: AndroidDevice

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: DeviceIcon.name(for: device))
                .font(.title3)
                .foregroundStyle(device.state.isControllable ? Color.accentColor : Color.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(device.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            StateBadge(state: device.state)
        }
        .padding(.vertical, 3)
    }
}

struct MDNSRow: View {
    @EnvironmentObject private var store: DeviceStore
    let service: MDNSService

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: service.isLegacyConnect ? "wifi" : "lock.shield")
                .foregroundStyle(.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.instance)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(service.isLegacyConnect
                     ? "\(service.endpoint) · doğrudan bağlantı"
                     : "\(service.endpoint) · güvenli bağlantı")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            HStack(spacing: 4) {
                Button("Bağlan") {
                    store.connect(service)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Doğrudan bağlanmayı dener. Eşleşik cihazlar buradan açılır.")

                Button {
                    store.beginPairing(ip: service.host)
                } label: {
                    Image(systemName: "link.badge.plus")
                }
                .controlSize(.small)
                .help("Eşleştirme sihirbazını aç — cihaz bu bilgisayarla eşleşmemişse gerekir.")
            }
        }
        .padding(.vertical, 2)
    }
}

struct StateBadge: View {
    let state: DeviceState

    var body: some View {
        Text(state.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch state {
        case .ready: return Color.green.opacity(0.18)
        case .unauthorized: return Color.orange.opacity(0.20)
        case .offline: return Color.red.opacity(0.18)
        case .unknown: return Color.gray.opacity(0.18)
        }
    }

    private var foreground: Color {
        switch state {
        case .ready: return .green
        case .unauthorized: return .orange
        case .offline: return .red
        case .unknown: return .secondary
        }
    }
}

enum DeviceIcon {
    static func name(for device: AndroidDevice) -> String {
        let haystack = [device.model, device.product, device.serial]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if haystack.contains("tv") || haystack.contains("televizyon") {
            return "tv.fill"
        }
        if haystack.contains("tablet") || haystack.contains("tab ") || haystack.contains("pad") {
            return "ipad"
        }
        return "iphone"
    }
}

// MARK: - Durum çubuğu

struct StatusBar: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: store.adbPath == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(store.adbPath == nil ? Color.orange : Color.green)
            Text(store.adbPath == nil ? "adb bulunamadı" : "adb: \(store.adbPath ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Divider().frame(height: 14)

            Image(systemName: store.scrcpyPath == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(store.scrcpyPath == nil ? Color.orange : Color.green)
            Text(store.scrcpyPath == nil ? "scrcpy yok (brew install scrcpy)" : "scrcpy: hazır")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if let error = store.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if store.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }
}
