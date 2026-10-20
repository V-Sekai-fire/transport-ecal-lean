// SPDX-FileCopyrightText: 2026 K. S. Ernest (iFire) Lee
// SPDX-License-Identifier: MIT
// Pipe throughput for 3840x2160 RGBA frames: `w N | r N` (writer, reader), plus a
// single-process memcpy of the same frames for scale. The reader checks a per-frame stamp so a
// short or reordered read cannot pass as a fast one.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define FRAME (3840u * 2160u * 4u)

static double now(void) {
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

int main(int argc, char **argv) {
	if (argc < 3) return 2;
	int n = atoi(argv[2]);
	uint8_t *buf = malloc(FRAME);
	for (uint32_t i = 0; i < FRAME; i++) buf[i] = (uint8_t)(i * 31u);
	if (argv[1][0] == 'w') {
		for (int f = 0; f < n; f++) {
			memcpy(buf, &f, sizeof f); // the stamp
			size_t off = 0;
			while (off < FRAME) {
				ssize_t k = write(1, buf + off, FRAME - off);
				if (k <= 0) return 1;
				off += (size_t)k;
			}
		}
		return 0;
	}
	if (argv[1][0] == 'r') {
		double t0 = now();
		for (int f = 0; f < n; f++) {
			size_t off = 0;
			while (off < FRAME) {
				ssize_t k = read(0, buf + off, FRAME - off);
				if (k <= 0) { fprintf(stderr, "short at frame %d\n", f); return 1; }
				off += (size_t)k;
			}
			int got;
			memcpy(&got, buf, sizeof got);
			if (got != f) { fprintf(stderr, "frame %d stamped %d\n", f, got); return 1; }
		}
		double dt = now() - t0;
		printf("pipe   %d frames  %.1f fps  %.2f GB/s  %.2f ms/frame\n", n, n / dt, n * (double)FRAME / dt / 1e9, dt / n * 1e3);
		return 0;
	}
	if (argv[1][0] == 'm') {
		uint8_t *dst = malloc(FRAME);
		double t0 = now();
		for (int f = 0; f < n; f++) { buf[0] = (uint8_t)f; memcpy(dst, buf, FRAME); }
		double dt = now() - t0;
		printf("memcpy %d frames  %.1f fps  %.2f GB/s  %.2f ms/frame (check %u)\n", n, n / dt, n * (double)FRAME / dt / 1e9, dt / n * 1e3, dst[0]);
		return 0;
	}
	return 2;
}
