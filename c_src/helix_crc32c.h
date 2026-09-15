#ifndef HELIX_CRC32C_H
#define HELIX_CRC32C_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Computes 32-bit Castagnoli CRC-32C using hardware instructions or table fallback */
uint32_t helix_crc32c(const uint8_t *data, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* HELIX_CRC32C_H */
