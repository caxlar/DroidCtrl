import SwiftUI

// MARK: - Telemetri şeridi
//
// Bilinçli olarak SADE: UI daha sonra yeniden tasarlanacak. Buradaki amaç
// sayıyı doğru ve okunur göstermek, süslemek değil.

struct TelemetryStrip: View {
    let telemetry: DeviceTelemetry
    let onRefresh: () -> Void

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatChip(icon: "memorychip",
                         label: "RAM",
                         value: telemetry.memUsedPercent.map { "\($0)%" } ?? "–",
                         detail: memDetail,
                         warn: (telemetry.memUsedPercent ?? 0) >= 85,
                         danger: (telemetry.memUsedPercent ?? 0) >= 95)

                StatChip(icon: "cpu",
                         label: "CPU",
                         value: telemetry.cpuPercent.map { "\(Int($0))%" } ?? "–",
                         detail: telemetry.cpuLoad1.map { String(format: "yük %.2f", $0) },
                         warn: (telemetry.cpuPercent ?? 0) >= 80,
                         danger: (telemetry.cpuPercent ?? 0) >= 95)

                StatChip(icon: "battery.75",
                         label: "Pil",
                         value: telemetry.batteryPercent.map { "\($0)%" } ?? "–",
                         detail: telemetry.temperatureC.map { "\($0)°C" },
                         warn: (telemetry.temperatureC ?? 0) >= 38,
                         danger: (telemetry.temperatureC ?? 0) >= 42)

                StatChip(icon: "internaldrive",
                         label: "Depolama",
                         value: telemetry.storageUsedPercent.map { "\($0)%" } ?? "–",
                         detail: storageDetail,
                         warn: (telemetry.storageUsedPercent ?? 0) >= 90,
                         danger: (telemetry.storageUsedPercent ?? 0) >= 97)

                StatChip(icon: "wifi",
                         label: "Bağlantı",
                         value: telemetry.adbLatencyMS.map { "\($0) ms" } ?? "–",
                         detail: nil,
                         warn: (telemetry.adbLatencyMS ?? 0) >= 250,
                         danger: (telemetry.adbLatencyMS ?? 0) >= 1000)
            }

            HStack {
                Text("son okuma: \(telemetry.collectedAt.map { Self.timeFormatter.string(from: $0) } ?? "–")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .controlSize(.mini)
                .help("Hemen yeniden oku")
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var memDetail: String? {
        guard let total = telemetry.memTotalMB, let avail = telemetry.memAvailableMB else { return nil }
        let usedGB = Double(total - avail) / 1024
        let totalGB = Double(total) / 1024
        return String(format: "%.1f / %.1f GB", usedGB, totalGB)
    }

    private var storageDetail: String? {
        guard let total = telemetry.storageTotalGB, let used = telemetry.storageUsedGB else { return nil }
        return String(format: "%.0f / %.0f GB", used, total)
    }
}

private struct StatChip: View {
    let icon: String
    let label: String
    let value: String
    let detail: String?
    let warn: Bool
    let danger: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .foregroundStyle(danger ? Color.red : (warn ? Color.orange : Color.primary))
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Kilidi aç

struct UnlockPanel: View {
    @ObservedObject var store: DeviceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                store.wakeAndUnlock()
            } label: {
                Label("Ekranı Aç / Kilidi Aç", systemImage: "lock.open")
            }
            .disabled(store.selectedDevice == nil)

            if !store.unlockStatus.isEmpty {
                Text(store.unlockStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - URL / link gönder

struct LinkPanel: View {
    @ObservedObject var store: DeviceStore
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("https://…", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Cihazda Aç", action: send)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func send() {
        store.sendURL(text)
        text = ""
    }
}

// MARK: - Dosya aktarım durumu

struct TransferStatusView: View {
    let status: String

    var body: some View {
        if !status.isEmpty {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Bağlantı: onarım + kablosuz kurulum

/// Cihazdan bağımsız bağlantı araçları. Burada hiçbir cihaza özel bilgi yoktur.
struct ConnectionPanel: View {
    @ObservedObject var store: DeviceStore

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.recoverConnection()
            } label: {
                Label("Bağlantıyı Onar", systemImage: "arrow.triangle.2.circlepath")
            }
            .controlSize(.small)
            .help("adb'yi yeniden başlatıp tekrar dener — bağlantı takıldığında")
        }
    }
}

// MARK: - Dosya bırakma hedefi

/// Pencerenin herhangi bir yerine dosya bırakılmasını kabul eder.
struct DropTargetModifier: ViewModifier {
    @ObservedObject var store: DeviceStore

    func body(content: Content) -> some View {
        content.dropDestination(for: URL.self) { urls, _ in
            store.handleDroppedFiles(urls)
            return true
        }
    }
}
