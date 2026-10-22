import Foundation

/// Uygulama etiketlerini diskte tutar; aynı cihaza ikinci bağlanışta
/// APK çözümlemesi tekrarlanmaz.
final class LabelCache {

    private let fileURL: URL
    private let queue = DispatchQueue(label: "droiddeck.labelcache")
    private var map: [String: String]
    private var dirty = false

    init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = FileManager.default.contents(atPath: fileURL.path),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
    }

    /// Cihaz seri numarasına göre kalıcı önbellek.
    ///
    /// Örnekler tekilleştirilir: aksi halde iki eşzamanlı `loadApps` aynı
    /// dosya için ayrı örnekler oluşturup son yazan öncekinin yeni
    /// girdilerini dosyaya hiç yazmadan ezerdi (last-writer-wins).
    private static let instanceQueue = DispatchQueue(label: "droiddeck.labelcache.instances")
    private static var instances: [String: LabelCache] = [:]

    static func forSerial(_ serial: String) -> LabelCache {
        instanceQueue.sync {
            if let existing = instances[serial] {
                return existing
            }

            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
                    .appendingPathComponent("Library/Application Support")
            let dir = base.appendingPathComponent("DroidCtrl", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let safe = serial.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "-")
            let cache = LabelCache(fileURL: dir.appendingPathComponent("labels-\(safe).json"))
            instances[serial] = cache
            return cache
        }
    }

    func label(for packageName: String) -> String? {
        queue.sync { map[packageName] }
    }

    func store(_ label: String, for packageName: String) {
        queue.sync {
            guard map[packageName] != label else { return }
            map[packageName] = label
            dirty = true
        }
    }

    func save() {
        queue.sync {
            guard dirty else { return }
            do {
                let data = try JSONEncoder().encode(map)
                try data.write(to: fileURL, options: .atomic)
                // Yalnızca BAŞARILI yazımda temizle. Aksi halde bir sonraki
                // save() hiçbir şey yapmaz ve değişiklikler sessizce kaybolur.
                dirty = false
            } catch {
                // Yazma hatası (disk dolu, izin vb.): dirty kalsın ki
                // sonraki save() tekrar denesin.
            }
        }
    }

    /// Tüm önbelleği siler — uygulama etiketi değiştiğinde (uygulama
    /// güncellendiğinde) kullanıcının yeniden çözümlemesini sağlar.
    func clear() {
        queue.sync {
            map = [:]
            dirty = true
        }
        save()
    }
}
