import Foundation

// MARK: - İkili okuyucu

struct ByteReader {
    let bytes: [UInt8]
    var pos: Int

    init(_ data: Data) {
        self.bytes = [UInt8](data)
        // Yeni dizi 0-tabanlıdır. `data.startIndex` kullanmak, Data slice'larında
        // okumayı yanlış kaydırırdı.
        self.pos = 0
    }

    init(bytes: [UInt8], pos: Int = 0) {
        self.bytes = bytes
        self.pos = pos
    }

    var remaining: Int { bytes.count - pos }
    func has(_ n: Int) -> Bool { pos + n <= bytes.count }

    mutating func seek(_ p: Int) { pos = p }

    @inline(__always) mutating func u8() -> UInt8 {
        guard has(1) else { return 0 }
        defer { pos += 1 }
        return bytes[pos]
    }

    @inline(__always) mutating func u16() -> UInt16 {
        guard has(2) else { return 0 }
        defer { pos += 2 }
        return UInt16(bytes[pos]) | (UInt16(bytes[pos + 1]) << 8)
    }

    @inline(__always) mutating func u32() -> UInt32 {
        guard has(4) else { return 0 }
        defer { pos += 4 }
        return UInt32(bytes[pos])
            | (UInt32(bytes[pos + 1]) << 8)
            | (UInt32(bytes[pos + 2]) << 16)
            | (UInt32(bytes[pos + 3]) << 24)
    }

    /// UTF-16 dilimi (0 ile sonlandırılmış değil, ham).
    mutating func utf16(at offset: Int, length: Int) -> String {
        guard offset >= 0, offset + length * 2 <= bytes.count else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(length)
        for i in 0..<length {
            let p = offset + i * 2
            units.append(UInt16(bytes[p]) | (UInt16(bytes[p + 1]) << 8))
        }
        return String(utf16CodeUnits: units, count: units.count)
    }

    mutating func ascii(at offset: Int, length: Int) -> String {
        guard offset >= 0, offset + length <= bytes.count else { return "" }
        return String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
    }
}

// MARK: - String havuzu (hem AXML hem ARSC için)

struct ResStringPool {
    let strings: [String]
    let isUTF8: Bool

    subscript(index: Int) -> String? {
        guard index >= 0, index < strings.count else { return nil }
        return strings[index]
    }

    /// Chunk başlangıç ofsetinden ayrıştırır.
    static func parse(_ bytes: [UInt8], chunkStart: Int) -> ResStringPool? {
        var r = ByteReader(bytes: bytes, pos: chunkStart)
        let type = r.u16()
        guard type == 0x0001 else { return nil }
        _ = r.u16()               // headerSize (28)
        _ = r.u32()               // size
        let stringCount = Int(r.u32())
        _ = r.u32()               // styleCount
        let flags = r.u32()
        let stringsStart = Int(r.u32())
        _ = r.u32()               // stylesStart

        let isUTF8 = (flags & 0x100) != 0
        guard stringCount >= 0, stringCount < 2_000_000 else { return nil }

        let offsetsStart = chunkStart + 28
        guard offsetsStart + stringCount * 4 <= bytes.count else { return nil }

        var result: [String] = []
        result.reserveCapacity(stringCount)

        for i in 0..<stringCount {
            let off = Int(UInt32(bytes[offsetsStart + i * 4])
                | (UInt32(bytes[offsetsStart + i * 4 + 1]) << 8)
                | (UInt32(bytes[offsetsStart + i * 4 + 2]) << 16)
                | (UInt32(bytes[offsetsStart + i * 4 + 3]) << 24))
            var sr = ByteReader(bytes: bytes, pos: chunkStart + stringsStart + off)
            guard sr.remaining > 0 else {
                result.append("")
                continue
            }

            if isUTF8 {
                // u8 karakter uzunluğu (yüksek bit = uzun form), u8 bayt uzunluğu
                var charLen = Int(sr.u8())
                if charLen & 0x80 != 0 {
                    charLen = ((charLen & 0x7F) << 8) | Int(sr.u8())
                }
                var byteLen = Int(sr.u8())
                if byteLen & 0x80 != 0 {
                    byteLen = ((byteLen & 0x7F) << 8) | Int(sr.u8())
                }
                _ = charLen
                let start = sr.pos
                result.append(sr.ascii(at: start, length: byteLen))
            } else {
                var charLen = Int(sr.u16())
                if charLen & 0x8000 != 0 {
                    charLen = ((charLen & 0x7FFF) << 16) | Int(sr.u16())
                }
                let start = sr.pos
                result.append(sr.utf16(at: start, length: charLen))
            }
        }

        return ResStringPool(strings: result, isUTF8: isUTF8)
    }
}

// MARK: - Binary XML (AndroidManifest.xml)

enum LabelRef: Equatable {
    case literal(String)
    case resource(UInt32)
}

struct AxmlInfo {
    /// `<application android:label>`
    var applicationLabel: LabelRef?
    /// Ana ekrandan açılan aktivitenin `android:label`'ı (varsa önceliklidir).
    var launcherLabel: LabelRef?
    var launcherActivity: String?
    /// İkon kaynağı — gerekiyorsa.
    var applicationIcon: LabelRef?
}

struct AxmlParser {

    private static let androidNS = "http://schemas.android.com/apk/res/android"
    private static let attrLabel: UInt32 = 0x01010001
    private static let attrName: UInt32 = 0x01010003

    static func parse(_ data: Data) -> AxmlInfo {
        let bytes = [UInt8](data)
        var info = AxmlInfo()

        var r = ByteReader(bytes: bytes, pos: 0)
        let rootType = r.u16()
        guard rootType == 0x0003 else { return info }   // RES_XML_TYPE
        _ = r.u16()                                      // headerSize
        _ = r.u32()                                      // size

        // Yardımcı: öğe öznitelik adı indeksi -> android kaynak kimliği
        var resourceMap: [Int: UInt32] = [:]
        var stringPool: ResStringPool?
        var pos = 8

        // Önce tüm chunk'ları tara: string pool ve kaynak haritasını bul.
        while pos + 8 <= bytes.count {
            var c = ByteReader(bytes: bytes, pos: pos)
            let type = c.u16()
            let headerSize = Int(c.u16())
            let size = Int(c.u32())
            guard size >= 8, pos + size <= bytes.count else { break }

            if type == 0x0001, stringPool == nil {
                stringPool = ResStringPool.parse(bytes, chunkStart: pos)
            } else if type == 0x0180 {
                // RES_XML_RESOURCE_MAP: headerSize > size olursa count negatife
                // düşer ve `0..<count` Swift'te fatale trap yapar.
                guard headerSize <= size, pos + size <= bytes.count else { break }
                var m = ByteReader(bytes: bytes, pos: pos + headerSize)
                let count = max(0, (size - headerSize) / 4)
                for i in 0..<count {
                    resourceMap[i] = m.u32()
                }
            }
            pos += size
        }

        guard let pool = stringPool else { return info }

        // Şimdi öğeleri tara.
        pos = 8
        var elementStack: [String] = []
        var currentActivityName: String?
        var currentActivityLabel: LabelRef?
        var inActivity = false
        var filterHasMain = false
        var filterHasLauncher = false
        var launcherFound = false

        while pos + 8 <= bytes.count {
            var c = ByteReader(bytes: bytes, pos: pos)
            let type = c.u16()
            _ = c.u16()             // headerSize (bu geçişte gerekmiyor)
            let size = Int(c.u32())
            guard size >= 8, pos + size <= bytes.count else { break }

            switch type {
            case 0x0102: // START_ELEMENT
                var e = ByteReader(bytes: bytes, pos: pos + 8)
                _ = e.u32()             // lineNumber
                _ = e.u32()             // comment
                let nsIdx = Int(e.u32())
                let nameIdx = Int(e.u32())
                let attrStart = Int(e.u16())
                let attrSize = Int(e.u16())
                let attrCount = Int(e.u16())
                _ = e.u16()             // idIndex
                _ = e.u16()             // classIndex
                _ = e.u16()             // styleIndex

                let elementName = pool[nameIdx] ?? ""
                elementStack.append(elementName)

                let attrs = readAttributes(bytes: bytes,
                                           start: pos + 16 + attrStart,
                                           size: attrSize,
                                           count: attrCount,
                                           pool: pool,
                                           resourceMap: resourceMap,
                                           nsIndex: nsIdx)

                if elementName == "application" {
                    for attr in attrs where attr.resID == attrLabel || attr.name == "label" {
                        info.applicationLabel = attr.value
                    }
                    for attr in attrs where attr.resID == 0x01010002 || attr.name == "icon" {
                        info.applicationIcon = attr.value
                    }
                } else if elementName == "activity" || elementName == "activity-alias" {
                    inActivity = true
                    filterHasMain = false
                    filterHasLauncher = false
                    currentActivityName = nil
                    currentActivityLabel = nil
                    for attr in attrs {
                        if attr.resID == attrName || attr.name == "name" {
                            if case .literal(let v) = attr.value { currentActivityName = v }
                        }
                        if attr.resID == attrLabel || attr.name == "label" {
                            currentActivityLabel = attr.value
                        }
                    }
                } else if elementName == "intent-filter" {
                    // Her intent-filter AYRI değerlendirilmeli. Android'de bir
                    // aktivitenin launcher olması için MAIN ve LAUNCHER'ın AYNI
                    // filter içinde olması gerekir; bayraklar filter'lar arasında
                    // taşarsa olmayan bir aktivite launcher olarak seçilir ve
                    // yanlış etiket gösterilir.
                    filterHasMain = false
                    filterHasLauncher = false
                } else if elementName == "action", inActivity {
                    for attr in attrs where attr.name == "name" || attr.resID == attrName {
                        if case .literal(let v) = attr.value, v == "android.intent.action.MAIN" {
                            filterHasMain = true
                        }
                    }
                } else if elementName == "category", inActivity {
                    for attr in attrs where attr.name == "name" || attr.resID == attrName {
                        if case .literal(let v) = attr.value, v == "android.intent.category.LAUNCHER" {
                            filterHasLauncher = true
                        }
                    }
                }

            case 0x0103: // END_ELEMENT
                var e = ByteReader(bytes: bytes, pos: pos + 8)
                _ = e.u32()
                _ = e.u32()
                _ = e.u32()             // ns
                let nameIdx = Int(e.u32())
                let elementName = pool[nameIdx] ?? ""

                if elementName == "intent-filter", inActivity, filterHasMain, filterHasLauncher, !launcherFound {
                    launcherFound = true
                    info.launcherActivity = currentActivityName
                    info.launcherLabel = currentActivityLabel
                }
                if elementName == "activity" || elementName == "activity-alias" {
                    inActivity = false
                    currentActivityName = nil
                    currentActivityLabel = nil
                }
                _ = elementStack.popLast()

            default:
                break
            }

            pos += size
        }

        return info
    }

    private struct Attr {
        var name: String?
        var resID: UInt32?
        var value: LabelRef?
    }

    private static func readAttributes(bytes: [UInt8],
                                       start: Int,
                                       size: Int,
                                       count: Int,
                                       pool: ResStringPool,
                                       resourceMap: [Int: UInt32],
                                       nsIndex: Int) -> [Attr] {
        guard size > 0, count > 0 else { return [] }
        var attrs: [Attr] = []
        attrs.reserveCapacity(count)

        for i in 0..<count {
            var a = ByteReader(bytes: bytes, pos: start + i * size)
            guard a.remaining >= 20 else { break }
            _ = a.u32()                       // ns
            let nameIdx = Int(a.u32())
            let rawValue = a.u32()
            _ = a.u16()                       // Res_value.size
            _ = a.u8()                        // res0
            let dataType = a.u8()
            let data = a.u32()

            var attr = Attr()
            attr.name = pool[nameIdx]
            attr.resID = resourceMap[nameIdx]

            if rawValue != 0xFFFFFFFF, let literal = pool[Int(rawValue)] {
                attr.value = .literal(literal)
            } else if dataType == 0x03, let s = pool[Int(data)] {
                attr.value = .literal(s)
            } else if dataType == 0x01 {
                attr.value = .resource(data)
            }

            attrs.append(attr)
        }
        return attrs
    }
}

// MARK: - ARSC (resources.arsc)

struct ArscTable {

    struct ResValue {
        let dataType: UInt8
        let data: UInt32
    }

    struct TypeChunk {
        let typeId: UInt8
        let locale: String?       // "tr", "en", "pt-rBR" ...
        let isDefault: Bool
        let entries: [Int: ResValue]
    }

    struct Package {
        let id: UInt32
        let name: String
        /// Kaynak kimliğindeki tip baytı = tip indeksi + typeIdOffset.
        let typeIdOffset: Int
        let typeStrings: ResStringPool
        let keyStrings: ResStringPool
        let types: [TypeChunk]
    }

    let globalStrings: ResStringPool
    let packages: [Package]

    // MARK: Ayrıştırma

    static func parse(_ data: Data) -> ArscTable? {
        let bytes = [UInt8](data)
        var r = ByteReader(bytes: bytes, pos: 0)
        let type = r.u16()
        guard type == 0x0002 else { return nil }   // RES_TABLE_TYPE
        let headerSize = Int(r.u16())
        let tableSize = Int(r.u32())
        _ = r.u32()                                 // packageCount

        guard headerSize + 8 <= bytes.count else { return nil }

        var globalPool: ResStringPool?
        var packages: [Package] = []
        var pos = headerSize

        while pos + 8 <= bytes.count, pos < tableSize {
            var c = ByteReader(bytes: bytes, pos: pos)
            let chunkType = c.u16()
            let chunkHeaderSize = Int(c.u16())
            let chunkSize = Int(c.u32())
            guard chunkSize >= 8, pos + chunkSize <= bytes.count else { break }

            if chunkType == 0x0001 {
                if globalPool == nil {
                    globalPool = ResStringPool.parse(bytes, chunkStart: pos)
                }
            } else if chunkType == 0x0200 {
                if let pkg = parsePackage(bytes, start: pos, chunkSize: chunkSize,
                                          headerSize: chunkHeaderSize) {
                    packages.append(pkg)
                }
            }
            pos += chunkSize
        }

        guard let pool = globalPool else { return nil }
        return ArscTable(globalStrings: pool, packages: packages)
    }

    private static func parsePackage(_ bytes: [UInt8], start: Int, chunkSize: Int, headerSize: Int) -> Package? {
        var r = ByteReader(bytes: bytes, pos: start + 8)
        let id = r.u32()
        // char16 name[128] = 256 bayt
        let nameOffset = r.pos
        r.seek(nameOffset + 256)
        let typeStrings = Int(r.u32())
        _ = r.u32()                                 // lastPublicType
        let keyStrings = Int(r.u32())
        _ = r.u32()                                 // lastPublicKey

        var nameUnits: [UInt16] = []
        for i in 0..<128 {
            let p = nameOffset + i * 2
            guard p + 1 < bytes.count else { break }
            let unit = UInt16(bytes[p]) | (UInt16(bytes[p + 1]) << 8)
            if unit == 0 { break }
            nameUnits.append(unit)
        }
        let packageName = String(utf16CodeUnits: nameUnits, count: nameUnits.count)

        guard typeStrings > 0, keyStrings > 0 else { return nil }
        guard let typePool = ResStringPool.parse(bytes, chunkStart: start + typeStrings) else { return nil }
        guard let keyPool = ResStringPool.parse(bytes, chunkStart: start + keyStrings) else { return nil }

        // Tip chunk'ları
        var types: [TypeChunk] = []
        var pos = start + headerSize
        let end = start + chunkSize

        while pos + 8 <= end {
            var c = ByteReader(bytes: bytes, pos: pos)
            let chunkType = c.u16()
            let chunkHeaderSize = Int(c.u16())
            let chunkLen = Int(c.u32())
            guard chunkLen >= 8, pos + chunkLen <= end else { break }

            if chunkType == 0x0201 {   // RES_TABLE_TYPE_TYPE
                var t = ByteReader(bytes: bytes, pos: pos + 8)
                let typeId = t.u8()
                let flags = t.u8()
                _ = t.u16()                       // reserved
                let entryCount = Int(t.u32())
                let entriesStart = Int(t.u32())

                // ResTable_config — ilk 4 bayt config boyutu
                var cfg = ByteReader(bytes: bytes, pos: pos + 20)
                let cfgSize = Int(cfg.u32())
                let cfgEnd = min(pos + 20 + max(cfgSize, 4), pos + chunkHeaderSize)

                // Locale alanları doğrudan indekslenir; chunk SINAIRLARI İÇİNDE
                // olduklarını doğrula — aksi halde bozuk/kesilmiş dosyada
                // dizi sınırları aşılır ve süreç fatale düşer.
                var locale: String?
                let localeOffset = pos + 20 + 8
                if cfgSize >= 12,
                   localeOffset + 4 <= bytes.count,
                   localeOffset + 4 <= cfgEnd {
                    let l0 = bytes[localeOffset]
                    let l1 = bytes[localeOffset + 1]
                    let c0 = bytes[localeOffset + 2]
                    let c1 = bytes[localeOffset + 3]
                    if l0 != 0 {
                        let lang = String(decoding: [l0, l1].filter { $0 != 0 }, as: UTF8.self)
                        if c0 != 0 {
                            let country = String(decoding: [c0, c1].filter { $0 != 0 }, as: UTF8.self)
                            locale = "r" + country
                            locale = lang + locale!
                        } else {
                            locale = lang
                        }
                    }
                }

                let isSparse = (flags & 0x01) != 0      // FLAG_SPARSE
                let isOffset16 = (flags & 0x02) != 0    // FLAG_OFFSET16
                var entries: [Int: ResValue] = [:]

                var o = ByteReader(bytes: bytes, pos: pos + chunkHeaderSize)

                if isSparse {
                    // (girdi indeksi, gerçek_ofset / 4) çiftleri
                    for _ in 0..<entryCount {
                        guard o.remaining >= 4 else { break }
                        let idx = Int(o.u16())
                        let raw = o.u16()
                        if raw == 0xFFFF { continue }
                        if let value = readEntry(bytes: bytes, at: pos + entriesStart + Int(raw) * 4) {
                            entries[idx] = value
                        }
                    }
                } else if isOffset16 {
                    // 16-bit ofsetler: gerçek ofset = değer * 4, 0xFFFF = girdi yok
                    for i in 0..<entryCount {
                        guard o.remaining >= 2 else { break }
                        let raw = o.u16()
                        if raw == 0xFFFF { continue }
                        if let value = readEntry(bytes: bytes, at: pos + entriesStart + Int(raw) * 4) {
                            entries[i] = value
                        }
                    }
                } else {
                    // 32-bit ofsetler: 0xFFFFFFFF = girdi yok
                    for i in 0..<entryCount {
                        guard o.remaining >= 4 else { break }
                        let raw = o.u32()
                        if raw == 0xFFFFFFFF { continue }
                        if let value = readEntry(bytes: bytes, at: pos + entriesStart + Int(raw)) {
                            entries[i] = value
                        }
                    }
                }

                types.append(TypeChunk(typeId: typeId,
                                       locale: locale,
                                       isDefault: locale == nil,
                                       entries: entries))
            }

            pos += chunkLen
        }

        // typeIdOffset (ResTable_package son alanı) — header 288 bayt ve üstüyse bulunur.
        var typeIdOffset = 0
        if headerSize >= 288 {
            let p = start + 284
            if p + 4 <= bytes.count {
                typeIdOffset = Int(UInt32(bytes[p]) | (UInt32(bytes[p + 1]) << 8)
                                   | (UInt32(bytes[p + 2]) << 16) | (UInt32(bytes[p + 3]) << 24))
            }
        }

        return Package(id: id,
                       name: packageName,
                       typeIdOffset: typeIdOffset,
                       typeStrings: typePool,
                       keyStrings: keyPool,
                       types: types)
    }

    private static func readEntry(bytes: [UInt8], at offset: Int) -> ResValue? {
        guard offset >= 0, offset + 8 <= bytes.count else { return nil }
        var e = ByteReader(bytes: bytes, pos: offset)
        let size = Int(e.u16())
        let flags = e.u16()
        let keyField = e.u32()

        let isComplex = (flags & 0x0001) != 0   // FLAG_COMPLEX
        let isCompact = (flags & 0x0008) != 0   // FLAG_COMPACT

        if isComplex { return nil }             // etiket için ilgisiz (bag/map)

        if isCompact {
            // Kompakt girdi: yalnızca 8 bayt, Res_value YOK.
            //   u16 -> key indeksi (normal `size` alanında)
            //   u16 -> alt bayt: FLAG_*, ÜST BAYT: dataType
            //   u32 -> data (normal `key` alanında)
            let dataType = UInt8((flags >> 8) & 0xFF)
            return ResValue(dataType: dataType, data: keyField)
        }

        // Normal girdi: Res_value, ResTable_entry başlığından (size bayt) hemen sonra.
        let valueOffset = offset + size
        guard valueOffset + 8 <= bytes.count else { return nil }

        var v = ByteReader(bytes: bytes, pos: valueOffset)
        _ = v.u16()                                  // Res_value.size
        _ = v.u8()                                   // res0
        let dataType = v.u8()
        let data = v.u32()
        return ResValue(dataType: dataType, data: data)
    }

    // MARK: Çözümleme

    /// Bir kaynak kimliğini (0x7fXXYYYY) metne çevirir.
    func resolve(id: UInt32, locale: String?, depth: Int = 0) -> String? {
        guard depth < 5 else { return nil }

        let packageId = (id >> 24) & 0xFF
        let typeByte = (id >> 16) & 0xFF
        let entryId = Int(id & 0xFFFF)

        guard let package = packages.first(where: { $0.id == packageId }) else { return nil }

        // Tip baytı = tip indeksi (1 tabanlı) + typeIdOffset
        let candidates = package.types.filter { Int($0.typeId) + package.typeIdOffset == Int(typeByte) }
        guard !candidates.isEmpty else { return nil }

        let ranked = candidates.sorted { a, b in
            rank(a, locale) < rank(b, locale)
        }

        for chunk in ranked {
            guard let value = chunk.entries[entryId] else { continue }
            switch value.dataType {
            case 0x03:  // TYPE_STRING
                return globalStrings[Int(value.data)]
            case 0x01, 0x07:  // TYPE_REFERENCE / TYPE_DYNAMIC_REFERENCE
                if let nested = resolve(id: value.data, locale: locale, depth: depth + 1) {
                    return nested
                }
            default:
                continue
            }
        }
        return nil
    }

    private func rank(_ chunk: TypeChunk, _ locale: String?) -> Int {
        guard let wanted = locale, !wanted.isEmpty else {
            return chunk.isDefault ? 0 : 5
        }
        if let l = chunk.locale {
            if l == wanted { return 0 }
            if l.hasPrefix(wanted) || wanted.hasPrefix(l) { return 1 }
            return 4
        }
        return 2   // varsayılan yapılandıрма
    }
}

// MARK: - APK etiket çözümleyici

struct ApkLabelResult {
    let packageName: String
    let label: String?
    let source: String
}

enum ApkLabel {

    /// Manifest + ARSC üzerinden gerçek uygulama adını çözer.
    static func resolve(packageName: String,
                        manifest: Data,
                        arsc: Data?,
                        locale: String? = nil) -> ApkLabelResult {
        let info = AxmlParser.parse(manifest)

        // ARSC yalnızca BİR KEZ ayrıştırılır. Her LabelRef için tekrarlamak,
        // 50 MB'lık tablolarda bellek ve süreyi gereksiz yere katlıyordu.
        let table: ArscTable? = arsc.flatMap { ArscTable.parse($0) }

        func materialize(_ ref: LabelRef?) -> String? {
            guard let ref else { return nil }
            switch ref {
            case .literal(let s):
                return s.isEmpty ? nil : s
            case .resource(let id):
                return table?.resolve(id: id, locale: locale)
            }
        }

        // Öncelik: ana ekran aktivitesinin etiketi, yoksa uygulamanın etiketi.
        if let s = materialize(info.launcherLabel) {
            return ApkLabelResult(packageName: packageName, label: s, source: "launcher-activity")
        }
        if let s = materialize(info.applicationLabel) {
            return ApkLabelResult(packageName: packageName, label: s, source: "application")
        }
        return ApkLabelResult(packageName: packageName, label: nil, source: "bulunamadı")
    }
}
