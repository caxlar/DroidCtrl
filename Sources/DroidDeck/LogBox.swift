import Foundation

/// Sunucu sürecinin çıktısını iş parçacığı güvenli biçimde toplar.
final class LogBox {
    private let lock = NSLock()
    private var storage = ""

    func append(_ text: String) {
        lock.lock()
        storage += text
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
