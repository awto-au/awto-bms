/*
 * fpemu on Zephyr: the bare-metal differential suite (test/tests.c) plus a
 * multi-thread check that every thread keeps its own F/D state (registers
 * and frm/fflags) across context switches. Built twice: prj.conf (FPU off,
 * emulated) and prj_hw.conf (real FPU); the outputs must be identical
 * apart from the "emulated=" line.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/reboot.h>

#include "harness.h"

void putch(char c)
{
	printk("%c", c);
}

void puts_(const char *s)
{
	printk("%s", s);
}

void puthex(uint64_t v, int digits)
{
	for (int i = digits - 1; i >= 0; i--) {
		putch("0123456789abcdef"[(v >> (i * 4)) & 15]);
	}
}

void putdec(uint32_t v)
{
	printk("%u", v);
}

#ifdef CONFIG_FPEMU_STATS
uint32_t fpemu_emulated_count(void);
uint32_t emulated_count(void)
{
	return fpemu_emulated_count();
}
#else
uint32_t emulated_count(void)
{
	return 0;
}
#endif

void qemu_exit(int code)
{
	ARG_UNUSED(code);
}

#define main fpemu_tests_main
#include "tests.c"
#undef main

/* ---- threads: per-thread rounding mode and register contents ------- */

#define ITER 2000
static uint32_t th_hash[2];

static void worker(void *p1, void *p2, void *p3)
{
	int id = (int)(uintptr_t)p1;
	int rm = id == 0 ? 1 /* RTZ */ : 3 /* RUP */;
	uint32_t hh = 2166136261u;
	volatile double one = 1.0, three = 3.0;

	__asm__ volatile("fsrm %0" : : "r"(rm));
	for (int i = 0; i < ITER; i++) {
		double q = one / (three + (double)(i + id * 7));
		uint32_t frm;
		union {
			double d;
			uint64_t u;
		} v = {.d = q};

		k_yield(); /* switch threads between the divide and the checks */
		__asm__ volatile("frrm %0" : "=r"(frm));
		v.d = v.d * three; /* the other thread's frm must not leak in */
		for (int b = 0; b < 8; b++) {
			hh ^= (uint8_t)(v.u >> (b * 8));
			hh *= 16777619u;
		}
		hh ^= frm;
		hh *= 16777619u;
	}
	th_hash[id] = hh;
}

K_THREAD_STACK_ARRAY_DEFINE(stacks, 2, 4096);
static struct k_thread threads[2];

int main(void)
{
	fpemu_tests_main();

	for (int i = 0; i < 2; i++) {
		k_thread_create(&threads[i], stacks[i], K_THREAD_STACK_SIZEOF(stacks[i]), worker,
				(void *)(uintptr_t)i, NULL, NULL, K_PRIO_PREEMPT(5), 0, K_NO_WAIT);
	}
	for (int i = 0; i < 2; i++) {
		k_thread_join(&threads[i], K_FOREVER);
	}
	printk("threads h0=%08x h1=%08x\n", th_hash[0], th_hash[1]);
	printk("ZEPHYR DONE\n");
	sys_reboot(SYS_REBOOT_COLD);
	return 0;
}
