/*
 * z_riscv_fpemu_trap(struct arch_esf *esf): called from the RISC-V
 * exception entry (isr.S, CONFIG_RISCV_FP_EMULATION) on an illegal
 * instruction. The esf holds the caller-saved registers and s0; s1..s11,
 * gp and tp still hold the trapped context's values here. Build a full
 * x0..x31 image, emulate, then reload s1..s11 (an F/D instruction may have
 * written one of them). Returns non-zero if the instruction was emulated.
 */
#include <zephyr/toolchain.h>

#define X(n) ((n) * 4)
#define FRAME 144 /* x[32] + ra, 16-byte aligned */

GTEXT(z_riscv_fpemu_trap)
SECTION_FUNC(TEXT, z_riscv_fpemu_trap)
	addi	sp, sp, -FRAME
	sw	ra, 128(sp)
	sw	gp, X(3)(sp)
	sw	tp, X(4)(sp)
	sw	s1, X(9)(sp)
	sw	s2, X(18)(sp)
	sw	s3, X(19)(sp)
	sw	s4, X(20)(sp)
	sw	s5, X(21)(sp)
	sw	s6, X(22)(sp)
	sw	s7, X(23)(sp)
	sw	s8, X(24)(sp)
	sw	s9, X(25)(sp)
	sw	s10, X(26)(sp)
	sw	s11, X(27)(sp)
	mv	a1, sp
	call	fpemu_zephyr_handle
	lw	s1, X(9)(sp)
	lw	s2, X(18)(sp)
	lw	s3, X(19)(sp)
	lw	s4, X(20)(sp)
	lw	s5, X(21)(sp)
	lw	s6, X(22)(sp)
	lw	s7, X(23)(sp)
	lw	s8, X(24)(sp)
	lw	s9, X(25)(sp)
	lw	s10, X(26)(sp)
	lw	s11, X(27)(sp)
	lw	ra, 128(sp)
	addi	sp, sp, FRAME
	ret
