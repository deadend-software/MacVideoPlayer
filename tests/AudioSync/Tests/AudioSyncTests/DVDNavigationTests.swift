import Testing
import CSync

private func navSector(vob: UInt16, cell: UInt8) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 2048)
    bytes[2] = 1; bytes[3] = 0xba
    bytes[1026] = 1; bytes[1027] = 0xbf
    bytes[1028] = 3; bytes[1029] = 250; bytes[1030] = 1
    bytes[1055] = UInt8(vob >> 8); bytes[1056] = UInt8(vob & 255)
    bytes[1058] = cell
    return bytes
}

@Test func interleavedAnglesDoNotReachTheSameDecoder() {
    var selected = false
    var first = navSector(vob: 1, cell: 1)
    let original = first
    VPDVDFilterSector(&first, 1, 1, &selected)
    #expect(selected && first == original)
    var payload = [UInt8](repeating: 42, count: 2048)
    VPDVDFilterSector(&payload, 1, 1, &selected)
    #expect(payload.allSatisfy { $0 == 42 })
    var alternate = navSector(vob: 2, cell: 1)
    VPDVDFilterSector(&alternate, 1, 1, &selected)
    #expect(!selected && alternate.allSatisfy { $0 == 0 })
    VPDVDFilterSector(&payload, 1, 1, &selected)
    #expect(payload.allSatisfy { $0 == 0 })
    first = original
    VPDVDFilterSector(&first, 1, 1, &selected)
    #expect(selected && first == original)
}

@Test func seekWaitsForNavigationAndRequiresBothCellIdentifiers() {
    var selected = false
    var partial = [UInt8](repeating: 42, count: 2048)
    VPDVDFilterSector(&partial, 1, 1, &selected)
    #expect(partial.allSatisfy { $0 == 0 })
    var wrongCell = navSector(vob: 1, cell: 2)
    VPDVDFilterSector(&wrongCell, 1, 1, &selected)
    #expect(!selected && wrongCell.allSatisfy { $0 == 0 })
}
