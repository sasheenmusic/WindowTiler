import Darwin
import MachO

/// Looks up one local symbol in an already-loaded system image. Tahoe's
/// asynchronous window operation is local and cannot be found with dlsym.
/// This only reads our process's loaded image; it never patches code, reads
/// another process, or changes system security. Follows yabai's lookup:
/// https://github.com/asmvik/yabai/blob/master/src/misc/macho_dlsym.h
enum PresetPrivateSymbol {
    static func find(_ name: String, in imagePath: String) -> UnsafeMutableRawPointer? {
        for index in 0..<_dyld_image_count() {
            guard let imageName = _dyld_get_image_name(index), String(cString: imageName) == imagePath,
                  let rawHeader = _dyld_get_image_header(index) else { continue }
            let headerPointer = UnsafeRawPointer(rawHeader)
            let header = headerPointer.load(as: mach_header_64.self)
            guard header.magic == MH_MAGIC_64 else { return nil }
            let commandStart = MemoryLayout<mach_header_64>.size
            let commandEnd = commandStart + Int(header.sizeofcmds)
            var offset = commandStart
            var linkedit: segment_command_64?
            var symbols: symtab_command?
            var executableRanges: [Range<UInt64>] = []
            for _ in 0..<header.ncmds {
                guard offset + MemoryLayout<load_command>.size <= commandEnd else { return nil }
                let command = headerPointer.advanced(by: offset).load(as: load_command.self)
                guard command.cmdsize >= MemoryLayout<load_command>.size,
                      offset + Int(command.cmdsize) <= commandEnd else { return nil }
                if command.cmd == LC_SEGMENT_64, command.cmdsize >= MemoryLayout<segment_command_64>.size {
                    var segment = headerPointer.advanced(by: offset).load(as: segment_command_64.self)
                    let segmentName = withUnsafeBytes(of: &segment.segname) { bytes in
                        String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                    }
                    if segmentName == "__LINKEDIT" { linkedit = segment }
                    let (segmentEnd, overflow) = segment.vmaddr.addingReportingOverflow(segment.vmsize)
                    if segment.initprot & VM_PROT_EXECUTE != 0, !overflow {
                        executableRanges.append(segment.vmaddr..<segmentEnd)
                    }
                } else if command.cmd == LC_SYMTAB, command.cmdsize >= MemoryLayout<symtab_command>.size {
                    symbols = headerPointer.advanced(by: offset).load(as: symtab_command.self)
                }
                offset += Int(command.cmdsize)
            }
            guard let linkedit, let symbols, linkedit.vmaddr >= linkedit.fileoff,
                  symbols.nsyms < 10_000_000 else { return nil }
            let (fileEnd, fileOverflow) = linkedit.fileoff.addingReportingOverflow(linkedit.filesize)
            let tableSize = UInt64(symbols.nsyms) * UInt64(MemoryLayout<nlist_64>.size)
            let (tableEnd, tableOverflow) = UInt64(symbols.symoff).addingReportingOverflow(tableSize)
            let (stringsEnd, stringsOverflow) = UInt64(symbols.stroff).addingReportingOverflow(UInt64(symbols.strsize))
            guard !fileOverflow, !tableOverflow, !stringsOverflow,
                  UInt64(symbols.symoff) >= linkedit.fileoff,
                  UInt64(symbols.stroff) >= linkedit.fileoff,
                  tableEnd <= fileEnd, stringsEnd <= fileEnd,
                  let unslidBase = Int(exactly: linkedit.vmaddr - linkedit.fileoff) else { return nil }
            let slide = _dyld_get_image_vmaddr_slide(index)
            let (base, baseOverflow) = unslidBase.addingReportingOverflow(slide)
            let (stringAddress, stringOverflow) = base.addingReportingOverflow(Int(symbols.stroff))
            let (tableAddress, tableAddressOverflow) = base.addingReportingOverflow(Int(symbols.symoff))
            guard !baseOverflow, !stringOverflow, !tableAddressOverflow,
                  let strings = UnsafeRawPointer(bitPattern: stringAddress),
                  let table = UnsafeRawPointer(bitPattern: tableAddress) else { return nil }
            for symbolIndex in 0..<Int(symbols.nsyms) {
                let symbol = table.advanced(by: symbolIndex * MemoryLayout<nlist_64>.size).load(as: nlist_64.self)
                let stringIndex = Int(symbol.n_un.n_strx)
                guard stringIndex < symbols.strsize, symbol.n_value != 0,
                      symbol.n_type & UInt8(N_STAB) == 0,
                      symbol.n_type & UInt8(N_TYPE) == UInt8(N_SECT), symbol.n_sect != 0,
                      executableRanges.contains(where: { $0.contains(symbol.n_value) }) else { continue }
                let string = strings.advanced(by: stringIndex).assumingMemoryBound(to: CChar.self)
                guard memchr(string, 0, Int(symbols.strsize) - stringIndex) != nil else { continue }
                if String(cString: string) == name {
                    guard let value = Int(exactly: symbol.n_value) else { return nil }
                    let (address, overflow) = value.addingReportingOverflow(slide)
                    return overflow ? nil : UnsafeMutableRawPointer(bitPattern: address)
                }
            }
            return nil
        }
        return nil
    }
}
