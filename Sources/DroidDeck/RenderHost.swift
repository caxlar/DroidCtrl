import SwiftUI

/// Yalnızca `--render` için: `NavigationSplitView` ve `List` AppKit destekli
/// olduğundan ImageRenderer'da çizilmez. Düzeni doğrudan yan yana kurar.
/// Gerçek uygulama `ContentView` kullanır.
struct RenderHost: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SidebarPreview()
                    .frame(width: 300)

                Divider()

                if let device = store.selectedDevice {
                    RemotePanelContent(device: device)
                        .padding(20)
                } else {
                    Spacer()
                }
            }

            Divider()

            StatusBar()
        }
        .background(Color.white)
    }
}

/// Kenar çubuğundaki satırların düzenini gösterir (List render edilemediği için).
struct SidebarPreview: View {
    @EnvironmentObject private var store: DeviceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cihazlar")
                .font(.headline)
                .foregroundStyle(.secondary)

            ForEach(store.devices) { device in
                DeviceRow(device: device)
            }

            Text("render_found_mdns")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            ForEach(store.mdnsServices) { service in
                MDNSRow(service: service)
            }

            Text("render_manual_connect")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Text("192.168.1.4:5555")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))

            Spacer(minLength: 0)
        }
        .padding(16)
    }
}
