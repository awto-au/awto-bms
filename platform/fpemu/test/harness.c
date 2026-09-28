/* Bare-metal support for the fpemu tests on QEMU virt: UART, exit, trap. */
#include <stddef.h>
#include <stdint.h>

#include "fpemu.h"
#include "harness.h"

#define UART0 ((volatile uint8_t *)0x10000000u)
#define SIFIVE_TEST ((volatile uint32_t *)0x00100000u)

static struct fpemu_state g_fp;
static uint32_t g_emulated; /* instructions emulated so far */

uint32_t emulated_count(void)
{
	return g_emulated;
}

void putch(char c)
{
	while (!(UART0[5] & 0x20)) {
	}
	UART0[0] = (uint8_t)c;
}

void puts_(const char *s)
{
	while (*s) {
		putch(*s++);
	}
}

void puthex(uint64_t v, int digits)
{
	for (int i = digits - 1; i >= 0; i--) {
		putch("0123456789abcdef"[(v >> (i * 4)) & 15]);
	}
}

void putdec(uint32_t v)
{
	char b[12];
	int n = 0;

	do {
		/* repeated subtraction: no divide needed */
		uint32_t q = 0, r = v;

		while (r >= 10) {
			r -= 10;
			q++;
		}
		b[n++] = (char)('0' + r);
		v = q;
	} while (v);
	while (n) {
		putch(b[--n]);
	}
}

void qemu_exit(int code)
{
	*SIFIVE_TEST = code == 0 ? 0x5555u : (((uint32_t)code << 16) | 0x3333u);
	for (;;) {
	}
}

static inline uint32_t csr_mcause(void)
{
	uint32_t v;

	__asm__ volatile("csrr %0, mcause" : "=r"(v));
	return v;
}

static inline uint32_t csr_mepc(void)
{
	uint32_t v;

	__asm__ volatile("csrr %0, mepc" : "=r"(v));
	return v;
}

static inline uint32_t csr_mtval(void)
{
	uint32_t v;

	__asm__ volatile("csrr %0, mtval" : "=r"(v));
	return v;
}

void trap_c(uint32_t *x)
{
	uint32_t cause = csr_mcause(), pc = csr_mepc();

	if (cause == 2) { /* illegal instruction */
		uint32_t insn = fpemu_fetch((const void *)pc);
		int len = fpemu_execute(&g_fp, x, insn);

		if (len) {
			g_emulated++;
			__asm__ volatile("csrw mepc, %0" : : "r"(pc + (uint32_t)len));
			return;
		}
		puts_("FAULT illegal insn ");
		puthex(insn, 8);
	} else {
		puts_("FAULT mcause ");
		puthex(cause, 8);
		puts_(" mtval ");
		puthex(csr_mtval(), 8);
	}
	puts_(" at ");
	puthex(pc, 8);
	putch('\n');
	qemu_exit(3);
}

/* The compiler may emit calls to these for struct copies. */
void *memcpy(void *d, const void *s, size_t n)
{
	uint8_t *dd = d;
	const uint8_t *ss = s;

	while (n--) {
		*dd++ = *ss++;
	}
	return d;
}

void *memset(void *d, int c, size_t n)
{
	uint8_t *dd = d;

	while (n--) {
		*dd++ = (uint8_t)c;
	}
	return d;
}
