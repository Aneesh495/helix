#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "helix_crc32c.h"

int main(void) {
    const char *test_str = "123456789";
    uint32_t expected = 0xE3069283;
    uint32_t computed = helix_crc32c((const uint8_t *)test_str, strlen(test_str));

    printf("[Helix C Native] Verifying CRC-32C: computed=0x%08X, expected=0x%08X\n", computed, expected);
    assert(computed == expected);

    printf("[Helix C Native] All native assertions passed successfully.\n");
    return 0;
}
