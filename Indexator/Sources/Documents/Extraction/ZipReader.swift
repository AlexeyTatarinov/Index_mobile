// SPDX-License-Identifier: GPL-3.0-or-later
//
// Minimal read-only ZIP reader (enough for .docx): central directory parsing,
// "stored" (method 0) and "deflate" (method 8) entries. No ZIP64, no encryption.

import Compression
import Foundation

struct ZipReader {
    enum ZipError: Error, Equatable {
        case notAZip
        case corrupted
        case zip64Unsupported
        case encrypted
        case unsupportedMethod(UInt16)
        case entryTooLarge
        case decompressionFailed
    }

    struct Entry: Equatable {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int

        var isDirectory: Bool { name.hasSuffix("/") }
    }

    /// Refuse to inflate entries larger than this (zip bomb guard).
    static let maxEntrySize = 256 * 1024 * 1024

    private let bytes: [UInt8]
    let entries: [Entry]

    init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    init(data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        self.entries = try ZipReader.readCentralDirectory(bytes)
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// Uncompressed contents of the entry with this exact name, or nil when absent.
    func data(named name: String) throws -> Data? {
        guard let e = entry(named: name) else { return nil }
        return try data(for: e)
    }

    func data(for entry: Entry) throws -> Data {
        if entry.flags & 0x1 != 0 { throw ZipError.encrypted }
        guard entry.uncompressedSize <= ZipReader.maxEntrySize else { throw ZipError.entryTooLarge }

        // Local file header: name and extra lengths may differ from the central directory.
        let lh = entry.localHeaderOffset
        guard lh >= 0, lh + 30 <= bytes.count, ZipReader.u32(bytes, lh) == 0x0403_4b50 else {
            throw ZipError.corrupted
        }
        let nameLen = Int(ZipReader.u16(bytes, lh + 26))
        let extraLen = Int(ZipReader.u16(bytes, lh + 28))
        let start = lh + 30 + nameLen + extraLen
        let end = start + entry.compressedSize
        guard start <= end, end <= bytes.count else { throw ZipError.corrupted }

        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw ZipError.corrupted }
            return Data(bytes[start..<end])
        case 8:
            if entry.uncompressedSize == 0 { return Data() }
            guard entry.compressedSize > 0 else { throw ZipError.corrupted }
            let compressed = Array(bytes[start..<end])
            let size = entry.uncompressedSize
            var output = [UInt8](repeating: 0, count: size)
            // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP method 8 stores.
            let written = compressed.withUnsafeBufferPointer { src -> Int in
                output.withUnsafeMutableBufferPointer { dst -> Int in
                    guard let s = src.baseAddress, let d = dst.baseAddress else { return 0 }
                    return compression_decode_buffer(d, size, s, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == size else { throw ZipError.decompressionFailed }
            return Data(output)
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
    }

    // MARK: - Parsing

    private static func readCentralDirectory(_ b: [UInt8]) throws -> [Entry] {
        let eocd = try findEndOfCentralDirectory(b)
        let totalEntries = u16(b, eocd + 10)
        let cdSize = u32(b, eocd + 12)
        let cdOffset = u32(b, eocd + 16)
        if totalEntries == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            throw ZipError.zip64Unsupported
        }
        var p = Int(cdOffset)
        guard p + Int(cdSize) <= b.count else { throw ZipError.corrupted }

        var result: [Entry] = []
        result.reserveCapacity(Int(totalEntries))
        for _ in 0..<Int(totalEntries) {
            guard p + 46 <= b.count, u32(b, p) == 0x0201_4b50 else { throw ZipError.corrupted }
            let flags = u16(b, p + 8)
            let method = u16(b, p + 10)
            let crc = u32(b, p + 16)
            let compSize = u32(b, p + 20)
            let uncompSize = u32(b, p + 24)
            let nameLen = Int(u16(b, p + 28))
            let extraLen = Int(u16(b, p + 30))
            let commentLen = Int(u16(b, p + 32))
            let localOffset = u32(b, p + 42)
            if compSize == 0xFFFF_FFFF || uncompSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                throw ZipError.zip64Unsupported
            }
            let nameStart = p + 46
            guard nameStart + nameLen <= b.count else { throw ZipError.corrupted }
            // Bit 11 means UTF-8; legacy CP437 names are decoded leniently as UTF-8 too.
            let name = String(decoding: b[nameStart..<(nameStart + nameLen)], as: UTF8.self)
            result.append(Entry(
                name: name,
                method: method,
                flags: flags,
                crc32: crc,
                compressedSize: Int(compSize),
                uncompressedSize: Int(uncompSize),
                localHeaderOffset: Int(localOffset)
            ))
            p = nameStart + nameLen + extraLen + commentLen
        }
        return result
    }

    /// The EOCD record (22 bytes + comment up to 64 KB) sits at the very end of the file.
    private static func findEndOfCentralDirectory(_ b: [UInt8]) throws -> Int {
        guard b.count >= 22 else { throw ZipError.notAZip }
        let lowest = max(0, b.count - 22 - 0xFFFF)
        var i = b.count - 22
        while i >= lowest {
            if b[i] == 0x50, b[i + 1] == 0x4b, b[i + 2] == 0x05, b[i + 3] == 0x06 {
                return i
            }
            i -= 1
        }
        throw ZipError.notAZip
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | (UInt32(b[i + 1]) << 8) | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }
}
