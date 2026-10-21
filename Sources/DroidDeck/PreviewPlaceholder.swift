//
//  PreviewPlaceholder.swift — DroidDeck
//
//  Önizleme KAPALIYKEN ekran alanında gösterilen yer tutucu.
//
//  Kullanıcı isteği: siyah zemin, ortada büyük ▶ düğmesi. Tıklayınca canlı
//  akış başlar. Hazır görsel gösterilmez — ekran açık kalmadığı sürece
//  cihazda encoder yükü olmaz.
//

import SwiftUI

struct PreviewPlaceholder: View {
    /// ▶ düğmesine basıldığında çağrılır.
    let onPlay: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 18) {
                Button(action: onPlay) {
                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(hovering ? 0.22 : 0.14))
                            .frame(width: 118, height: 118)
                        Circle()
                            .stroke(Color.white.opacity(0.28), lineWidth: 1.5)
                            .frame(width: 118, height: 118)
                        Image(systemName: "play.fill")
                            .font(.system(size: 46, weight: .medium))
                            .foregroundStyle(.white)
                            // Optik hizalama: üçgen merkezden biraz sağda görünür.
                            .offset(x: 5)
                    }
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }

                Text("Ekranı Görüntülemek İçin Tıklayın")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
            }
        }
        .clipped()
    }
}
