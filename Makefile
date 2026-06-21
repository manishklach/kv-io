CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -std=c11

.PHONY: all clean

all: bench/kvio_bench

bench/kvio_bench: bench/kvio_bench.c
	$(CC) $(CFLAGS) -o $@ $<

clean:
	rm -f bench/kvio_bench
