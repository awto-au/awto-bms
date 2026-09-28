/*
 * fpemu: trap-and-emulate for the RISC-V F and D extensions on RV32.
 *
 * For cores without a double-precision FPU (e.g. an rv32imafc part) running
 * code built for rv32imafdc/ilp32d. The FPU is left OFF (mstatus.FS = 0), so
 * every F/D instruction and every fcsr/frm/fflags access raises an
 * illegal-instruction exception; the trap handler calls fpemu_execute(),
 * which performs the instruction on a 64-bit shadow register file and
 * returns the instruction length so the handler can skip it.
 *
 * Arithmetic is Berkeley SoftFloat 3e with the RISC-V specialisation
 * (canonical NaN, RISC-V conversion saturation), honouring the static and
 * dynamic rounding modes and accruing fflags exactly as hardware would.
 *
 * OS-independent: no allocation, no globals except SoftFloat's own state.
 * Not reentrant: callers serialise (one hart at a time, or a lock).
 */
#ifndef FPEMU_H
#define FPEMU_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Per-thread floating-point state (the architectural F/D state). Single
 * values are NaN-boxed in the low 32 bits, exactly as on a D-capable core. */
struct fpemu_state {
	uint64_t f[32];
	uint32_t fcsr; /* [4:0] fflags, [7:5] frm */
};

/*
 * Fetch the instruction at pc: 16 bits if compressed, else 32. Reads in
 * halfwords, so a 32-bit instruction straddling a word boundary is fine.
 */
uint32_t fpemu_fetch(const void *pc);

/* Length in bytes of the instruction [insn] (2 or 4). */
static inline int fpemu_insn_len(uint32_t insn)
{
	return (insn & 3u) == 3u ? 4 : 2;
}

/*
 * Execute one F/D instruction (or fcsr/frm/fflags CSR access).
 *
 * x:  the trapped context's integer registers x0..x31 (x[0] is read as 0
 *     and writes to it are dropped). x[2] is sp for the *SP compressed forms.
 * Returns the instruction length (2 or 4) when it was emulated, or 0 when
 * [insn] is not an instruction fpemu handles (a genuine illegal
 * instruction: the caller should treat it as a fault). An F/D instruction
 * with a reserved rounding mode also returns 0, as hardware would trap.
 */
int fpemu_execute(struct fpemu_state *st, uint32_t *x, uint32_t insn);

#ifdef __cplusplus
}
#endif

#endif /* FPEMU_H */
