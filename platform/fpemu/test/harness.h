#ifndef HARNESS_H
#define HARNESS_H
#include <stdint.h>

void putch(char c);
void puts_(const char *s);
void puthex(uint64_t v, int digits);
void putdec(uint32_t v);
void qemu_exit(int code);
uint32_t emulated_count(void);

#endif
