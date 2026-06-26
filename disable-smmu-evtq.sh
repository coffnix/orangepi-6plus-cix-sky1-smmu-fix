#!/bin/sh

# ARM SMMU v3 Event Queue Fix for CIX Sky1.
#
# This script builds a small devmem32 helper if it is not already present,
# locates the first ARM SMMU v3 instance reported by the kernel, and clears
# the EVTQEN bit in the SMMU CR0 register.
#
# CR0 offset: 0x20
# EVTQEN bit : 2

set -eu

DEVMEM="/usr/local/sbin/devmem32"

if [ ! -x "$DEVMEM" ]; then
    if command -v devmem32 >/dev/null 2>&1; then
        DEVMEM="$(command -v devmem32)"
    else
        echo "devmem32 not found, building it..."

        mkdir -p /usr/local/sbin

        if ! command -v gcc >/dev/null 2>&1; then
            echo "Error: gcc was not found."
            exit 1
        fi

        cat > /tmp/devmem.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "usage: %s addr [value]\n", argv[0]);
        return 1;
    }

    off_t addr = strtoull(argv[1], NULL, 0);
    off_t page = addr & ~(off_t)(getpagesize() - 1);
    off_t off = addr - page;

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    void *map = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE, MAP_SHARED, fd, page);
    if (map == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    volatile uint32_t *reg = (volatile uint32_t *)((char *)map + off);

    if (argc == 2) {
        printf("0x%08x\n", *reg);
    } else {
        uint32_t val = strtoul(argv[2], NULL, 0);
        *reg = val;
        printf("0x%08x\n", *reg);
    }

    munmap(map, getpagesize());
    close(fd);
    return 0;
}
EOF

        gcc -O2 -Wall -o /usr/local/sbin/devmem32 /tmp/devmem.c
        chmod +x /usr/local/sbin/devmem32
    fi
fi

if [ ! -x "$DEVMEM" ]; then
    echo "Error: devmem32 was not found or could not be built."
    exit 1
fi

BASE=$(dmesg | sed -n 's/.*arm-smmu-v3 \([0-9a-fA-F]\+\)\.\(iommu\|auto\).*/\1/p' | head -n1)

if [ -z "$BASE" ]; then
    echo "Error: no ARM SMMU v3 instance found in kernel log."
    exit 1
fi

CR0=$(printf "0x%08x" $((0x$BASE + 0x20)))

CURRENT=$("$DEVMEM" "$CR0")

if [ $((CURRENT & 4)) -eq 0 ]; then
    echo "ARM SMMU v3 at $BASE: EVTQEN is already disabled ($CURRENT)"
    exit 0
fi

NEW=$(printf "0x%08x" $((CURRENT & ~4)))

"$DEVMEM" "$CR0" "$NEW" >/dev/null

UPDATED=$("$DEVMEM" "$CR0")

echo "ARM SMMU v3 : $BASE"
echo "CR0 address : $CR0"
echo "CR0 before  : $CURRENT"
echo "CR0 after   : $UPDATED"
echo "Status      : EVTQEN successfully disabled"
