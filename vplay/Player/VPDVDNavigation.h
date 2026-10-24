#ifndef VPDVDNavigation_h
#define VPDVDNavigation_h

#include <stdint.h>
#include <stdbool.h>
#include <string.h>

typedef struct {
    int64_t physicalStart, logicalStart, length;
    uint16_t vob;
    uint8_t cell;
} VPDVDCellRange;

// DVD NAV packs carry the DSI packet at byte 1024 and its payload at 1031.
// IDs identify the cell of the *following VOBU*, not an entire VOB file.
static inline bool VPDVDReadCellID(const uint8_t *sector, uint16_t *vob, uint8_t *cell) {
    if (memcmp(sector, "\x00\x00\x01\xBA", 4) ||
        memcmp(sector + 1024, "\x00\x00\x01\xBF", 4) ||
        sector[1028] != 3 || sector[1029] != 250 || sector[1030] != 1) return false;
    *vob = ((uint16_t)sector[1055] << 8) | sector[1056];
    *cell = sector[1058];
    return true;
}

static inline void VPDVDFilterSector(uint8_t *sector, uint16_t wantedVOB,
                                     uint8_t wantedCell, bool *selected) {
    uint16_t vob;
    uint8_t cell;
    if (VPDVDReadCellID(sector, &vob, &cell)) {
        *selected = vob == wantedVOB && cell == wantedCell;
    }
    // Preserve byte positions for MPEG seeking while excluding other angles.
    // MPEG's sync scanner skips these bytes; no encoded media is re-encoded.
    if (!*selected) memset(sector, 0, 2048);
}

#endif
