CC ?= clang
CFLAGS ?= -O3 -Wall -Wextra -pedantic

all: helix_crc_test

helix_crc_test: main.c helix_crc32c.c helix_crc32c.h
	$(CC) $(CFLAGS) -o helix_crc_test main.c helix_crc32c.c

clean:
	rm -f helix_crc_test
