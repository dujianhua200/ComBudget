import Foundation
import zlib

// =============================================================================
// 极简 ZIP 容器（.xlsx 的本质就是一个 zip 包）
//
// 读：解析中央目录 + 本地头，deflate 用系统 zlib 做 raw inflate
// 写：只用 store（不压缩）方式打包，Excel / Numbers / WPS 均可正常打开
//
// 为什么不引第三方库：ZIPFoundation 等功能单一但会引入外部依赖与版本漂移，
// xlsx 只需要「取几个 xml 文件」和「塞几个 xml 文件」，200 行足够。
// =============================================================================

enum ZipError: LocalizedError {
    case badArchive(String)
    case entryNotFound(String)
    case inflateFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .badArchive(let m):       return "ZIP 结构异常：\(m)"
        case .entryNotFound(let n):    return "ZIP 内未找到条目：\(n)"
        case .inflateFailed(let code): return "ZIP 解压失败（zlib \(code)）"
        }
    }
}

struct ZipEntry {
    let name: String
    let method: UInt16
    let compressedSize: Int
    let uncompressedSize: Int
    let localHeaderOffset: Int
}

final class ZipReader {
    private let bytes: [UInt8]

    init(url: URL) throws {
        let data = try Data(contentsOf: url)
        bytes = [UInt8](data)
    }

    init(data: Data) {
        bytes = [UInt8](data)
    }

    private func u16(_ at: Int) -> Int {
        Int(bytes[at]) | (Int(bytes[at + 1]) << 8)
    }

    private func u32(_ at: Int) -> Int {
        Int(bytes[at]) | (Int(bytes[at + 1]) << 8) | (Int(bytes[at + 2]) << 16) | (Int(bytes[at + 3]) << 24)
    }

    /// 解析中央目录
    lazy var entries: [ZipEntry] = {
        var eocd = -1
        // EOCD 固定 22 字节（无注释），向前最多搜 64KB（注释最长 65535）
        guard bytes.count > 22 else { return [] }
        var i = bytes.count - 22
        let lower = max(0, bytes.count - 22 - 65535)
        while i >= lower {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return [] }

        let count = u16(eocd + 10)
        var offset = u32(eocd + 16)
        var result: [ZipEntry] = []
        result.reserveCapacity(count)

        for _ in 0..<count {
            guard offset + 46 <= bytes.count, u32(offset) == 0x02014b50 else { break }
            let method = UInt16(u16(offset + 10))
            let compSize = u32(offset + 20)
            let uncompSize = u32(offset + 24)
            let nameLen = u16(offset + 28)
            let extraLen = u16(offset + 30)
            let commentLen = u16(offset + 32)
            let localOffset = u32(offset + 42)
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLen)], as: UTF8.self)
            result.append(ZipEntry(name: name, method: method, compressedSize: compSize,
                                   uncompressedSize: uncompSize, localHeaderOffset: localOffset))
            offset += 46 + nameLen + extraLen + commentLen
        }
        return result
    }()

    func contains(_ name: String) -> Bool { entries.contains { $0.name == name } }

    /// 取出某个条目的原始数据
    func data(for name: String) throws -> Data {
        guard let entry = entries.first(where: { $0.name == name }) else {
            throw ZipError.entryNotFound(name)
        }
        let lo = entry.localHeaderOffset
        guard lo + 30 <= bytes.count, u32(lo) == 0x04034b50 else {
            throw ZipError.badArchive("本地文件头损坏：\(name)")
        }
        let nameLen = u16(lo + 26)
        let extraLen = u16(lo + 28)
        let start = lo + 30 + nameLen + extraLen
        guard start + entry.compressedSize <= bytes.count else {
            throw ZipError.badArchive("数据区越界：\(name)")
        }
        let payload = Array(bytes[start..<(start + entry.compressedSize)])

        if entry.method == 0 {
            return Data(payload)
        }
        guard entry.method == 8 else {
            throw ZipError.badArchive("不支持的压缩方式 \(entry.method)：\(name)")
        }
        return try inflateRaw(payload, expectedSize: entry.uncompressedSize)
    }

    /// raw deflate 解压（windowBits = -15，无 zlib 头）
    private func inflateRaw(_ src: [UInt8], expectedSize: Int) throws -> Data {
        guard !src.isEmpty else { return Data() }
        var out = [UInt8](repeating: 0, count: max(expectedSize, 1))
        var stream = z_stream()
        let rc = inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else { throw ZipError.inflateFailed(rc) }
        defer { inflateEnd(&stream) }

        var status: Int32 = Z_OK
        src.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                stream.next_in = UnsafeMutablePointer(mutating: inBuf.baseAddress)
                stream.avail_in = uInt(inBuf.count)
                stream.next_out = outBuf.baseAddress
                stream.avail_out = uInt(outBuf.count)
                status = inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || status == Z_OK else { throw ZipError.inflateFailed(status) }
        let produced = out.count - Int(stream.avail_out)
        return Data(out[0..<produced])
    }
}

// MARK: - 写

enum ZipWriter {
    struct Entry {
        let name: String
        let data: Data
    }

    /// 打包为 zip（store 方式，无压缩）
    static func archive(entries: [Entry]) -> Data {
        var out = [UInt8]()
        var central = [UInt8]()
        var offsets: [Int] = []

        for entry in entries {
            offsets.append(out.count)
            let payload = [UInt8](entry.data)
            let nameBytes = [UInt8](entry.name.utf8)
            let crc = CRC32.compute(payload)

            // 本地文件头
            appendU32(&out, 0x04034b50)
            appendU16(&out, 20)          // version needed
            appendU16(&out, 0)           // flags
            appendU16(&out, 0)           // method = store
            appendU16(&out, 0)           // mod time
            appendU16(&out, 0x21)        // mod date（1980-01-01，固定值即可）
            appendU32(&out, crc)
            appendU32(&out, UInt32(payload.count))
            appendU32(&out, UInt32(payload.count))
            appendU16(&out, UInt16(nameBytes.count))
            appendU16(&out, 0)           // extra len
            out.append(contentsOf: nameBytes)
            out.append(contentsOf: payload)
        }

        for (idx, entry) in entries.enumerated() {
            let nameBytes = [UInt8](entry.name.utf8)
            let payload = [UInt8](entry.data)
            appendU32(&central, 0x02014b50)
            appendU16(&central, 20)      // version made by
            appendU16(&central, 20)      // version needed
            appendU16(&central, 0)       // flags
            appendU16(&central, 0)       // method
            appendU16(&central, 0)       // time
            appendU16(&central, 0x21)    // date
            appendU32(&central, CRC32.compute(payload))
            appendU32(&central, UInt32(payload.count))
            appendU32(&central, UInt32(payload.count))
            appendU16(&central, UInt16(nameBytes.count))
            appendU16(&central, 0)       // extra
            appendU16(&central, 0)       // comment
            appendU16(&central, 0)       // disk start
            appendU16(&central, 0)       // internal attr
            appendU32(&central, 0)       // external attr
            appendU32(&central, UInt32(offsets[idx]))
            central.append(contentsOf: nameBytes)
        }

        let cdOffset = out.count
        out.append(contentsOf: central)
        appendU32(&out, 0x06054b50)
        appendU16(&out, 0)               // disk
        appendU16(&out, 0)               // cd disk
        appendU16(&out, UInt16(entries.count))
        appendU16(&out, UInt16(entries.count))
        appendU32(&out, UInt32(central.count))
        appendU32(&out, UInt32(cdOffset))
        appendU16(&out, 0)               // comment len
        return Data(out)
    }

    private static func appendU16(_ buf: inout [UInt8], _ v: UInt16) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
    }

    private static func appendU32(_ buf: inout [UInt8], _ v: UInt32) {
        buf.append(UInt8(v & 0xFF))
        buf.append(UInt8((v >> 8) & 0xFF))
        buf.append(UInt8((v >> 16) & 0xFF))
        buf.append(UInt8((v >> 24) & 0xFF))
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    static func compute(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
