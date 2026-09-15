#include "helix_crc32c.h"

#define POLYNOMIAL 0x82F63B78

static uint32_t crc_table[256];
static int table_initialized = 0;

static void init_table(void) {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t crc = i;
        for (int j = 0; j < 8; j++) {
            if (crc & 1) {
                crc = (crc >> 1) ^ POLYNOMIAL;
            } else {
                crc >>= 1;
            }
        }
        crc_table[i] = crc;
    }
    table_initialized = 1;
}

uint32_t helix_crc32c(const uint8_t *data, size_t length) {
    if (!table_initialized) {
        init_table();
    }

    uint32_t crc = 0xFFFFFFFF;
    for (size_t i = 0; i < length; i++) {
        uint8_t index = (uint8_t)((crc ^ data[i]) & 0xFF);
        crc = (crc >> 8) ^ crc_table[index];
    }

    return crc ^ 0xFFFFFFFF;
}
