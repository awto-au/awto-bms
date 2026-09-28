/*
 * Zephyr glue for fpemu: map the exception frame to a register image,
 * emulate, write the frame back. The F/D register file and fcsr live in
 * thread-local storage, so every thread has its own, and no context-switch
 * support is needed (the FPU stays off).
 */
#include <zephyr/kernel.h>
#include <zephyr/arch/riscv/exception.h>

#include "fpemu.h"

static __thread struct fpemu_state fp_state;

#ifdef CONFIG_FPEMU_STATS
static atomic_t emulated;

uint32_t fpemu_emulated_count(void)
{
	return (uint32_t)atomic_get(&emulated);
}
#endif

int fpemu_zephyr_handle(struct arch_esf *esf, uint32_t *x)
{
	uint32_t insn = fpemu_fetch((const void *)esf->mepc);

	x[0] = 0;
	x[1] = esf->ra;
	/* Kernel-mode only (no USERSPACE): the frame sits right below sp. */
	x[2] = (uint32_t)(uintptr_t)esf + sizeof(*esf);
	x[5] = esf->t0;
	x[6] = esf->t1;
	x[7] = esf->t2;
	x[8] = esf->s0;
	x[10] = esf->a0;
	x[11] = esf->a1;
	x[12] = esf->a2;
	x[13] = esf->a3;
	x[14] = esf->a4;
	x[15] = esf->a5;
	x[16] = esf->a6;
	x[17] = esf->a7;
	x[28] = esf->t3;
	x[29] = esf->t4;
	x[30] = esf->t5;
	x[31] = esf->t6;

	int len = fpemu_execute(&fp_state, x, insn);

	if (len == 0) {
		return 0; /* a genuine illegal instruction: normal fault path */
	}
	esf->ra = x[1];
	esf->t0 = x[5];
	esf->t1 = x[6];
	esf->t2 = x[7];
	esf->s0 = x[8];
	esf->a0 = x[10];
	esf->a1 = x[11];
	esf->a2 = x[12];
	esf->a3 = x[13];
	esf->a4 = x[14];
	esf->a5 = x[15];
	esf->a6 = x[16];
	esf->a7 = x[17];
	esf->t3 = x[28];
	esf->t4 = x[29];
	esf->t5 = x[30];
	esf->t6 = x[31];
	esf->mepc += (unsigned long)len;
#ifdef CONFIG_FPEMU_STATS
	atomic_inc(&emulated);
#endif
	return 1;
}
