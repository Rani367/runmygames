import Foundation

/// Minimal PE reader: which DLLs does an executable import (normal + delay-load)?
/// Enough to tell a DX12 game from a DX11/DX9 one without running it.
public enum PEScanner {
    public struct Info: Equatable {
        public var is64Bit: Bool
        public var imports: Set<String> // lowercased dll names
    }

    public static func scan(_ url: URL) -> Info? {
        // Memory-mapped: only the pages we touch are read, even for 200 MB Unreal binaries
        // whose import tables sit far past the start of the file.
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return scan(data)
    }

    public static func scan(_ d: Data) -> Info? {
        d.withUnsafeBytes { raw in scan(raw.bindMemory(to: UInt8.self)) }
    }

    static func scan(_ b: UnsafeBufferPointer<UInt8>) -> Info? {
        func u16(_ o: Int) -> Int? { o >= 0 && o + 2 <= b.count ? Int(b[o]) | Int(b[o + 1]) << 8 : nil }
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= b.count else { return nil }
            return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        guard b.count > 0x40, b[0] == 0x4D, b[1] == 0x5A, let pe = u32(0x3C),
              u32(pe) == 0x0000_4550, let nsec = u16(pe + 6), let optSize = u16(pe + 20),
              let magic = u16(pe + 24) else { return nil }
        let is64 = magic == 0x20B
        let opt = pe + 24
        let dirBase = opt + (is64 ? 112 : 96)
        let secBase = opt + optSize

        struct Section { let va, vsize, raw, rawSize: Int }
        var sections: [Section] = []
        for s in 0..<nsec {
            let o = secBase + s * 40
            guard let va = u32(o + 12), let vs = u32(o + 8), let raw = u32(o + 20), let rs = u32(o + 16) else { break }
            sections.append(Section(va: va, vsize: max(vs, rs), raw: raw, rawSize: rs))
        }
        func off(_ rva: Int) -> Int? {
            for s in sections where rva >= s.va && rva < s.va + s.vsize {
                let o = rva - s.va
                return o < s.rawSize ? s.raw + o : nil
            }
            return nil
        }
        func cstr(_ rva: Int) -> String? {
            guard var o = off(rva) else { return nil }
            var bytes: [UInt8] = []
            while o < b.count, b[o] != 0, bytes.count < 256 { bytes.append(b[o]); o += 1 }
            return String(bytes: bytes, encoding: .ascii)?.lowercased()
        }

        var imports = Set<String>()
        // Directory 1 = imports (20-byte descriptors, name at +12),
        // directory 13 = delay imports (32-byte descriptors, name at +4).
        for (dir, stride, nameAt) in [(1, 20, 12), (13, 32, 4)] {
            guard let rva = u32(dirBase + dir * 8), rva != 0, var o = off(rva) else { continue }
            for _ in 0..<4096 {
                guard let nameRVA = u32(o + nameAt), nameRVA != 0 else { break }
                if let n = cstr(nameRVA) { imports.insert(n) }
                o += stride
            }
        }
        return Info(is64Bit: is64, imports: imports)
    }
}
