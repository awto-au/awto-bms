/*
 * fpemu: RV32 F and D instruction emulation. See include/fpemu.h.
 *
 * Encodings follow the RISC-V Unprivileged ISA (F, D, C chapters).
 * Built without any FP instructions itself (checked by the build).
 */
#include "fpemu.h"

#include <stdbool.h>

#include "softfloat.h"

#define CANON_NAN32 0x7FC00000u
#define CANON_NAN64 0x7FF8000000000000ull
#define BOX_HI 0xFFFFFFFF00000000ull
#define SIGN32 0x80000000u
#define SIGN64 0x8000000000000000ull

enum { FMT_S = 0, FMT_D = 1 };

/* ---- register helpers ---------------------------------------------- */

static inline uint32_t rx(const uint32_t *x, unsigned r)
{
	return r ? x[r] : 0;
}

static inline void wx(uint32_t *x, unsigned r, uint32_t v)
{
	if (r) {
		x[r] = v;
	}
}

/* A single operand: the low word if properly NaN-boxed, else canonical NaN. */
static inline float32_t rs32(const struct fpemu_state *st, unsigned r)
{
	float32_t v;
	uint64_t raw = st->f[r];

	v.v = (raw & BOX_HI) == BOX_HI ? (uint32_t)raw : CANON_NAN32;
	return v;
}

static inline float64_t rs64(const struct fpemu_state *st, unsigned r)
{
	float64_t v;

	v.v = st->f[r];
	return v;
}

static inline void wf32(struct fpemu_state *st, unsigned r, float32_t v)
{
	st->f[r] = BOX_HI | v.v;
}

static inline void wf64(struct fpemu_state *st, unsigned r, float64_t v)
{
	st->f[r] = v.v;
}

/* ---- memory (tolerates misalignment) ------------------------------- */

static uint32_t ld32(uintptr_t a)
{
	if ((a & 3u) == 0) {
		return *(volatile const uint32_t *)a;
	}
	const volatile uint8_t *p = (const volatile uint8_t *)a;

	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) |
	       ((uint32_t)p[3] << 24);
}

static void st32(uintptr_t a, uint32_t v)
{
	if ((a & 3u) == 0) {
		*(volatile uint32_t *)a = v;
		return;
	}
	volatile uint8_t *p = (volatile uint8_t *)a;

	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

static uint64_t ld64(uintptr_t a)
{
	return (uint64_t)ld32(a) | ((uint64_t)ld32(a + 4) << 32);
}

static void st64(uintptr_t a, uint64_t v)
{
	st32(a, (uint32_t)v);
	st32(a + 4, (uint32_t)(v >> 32));
}

uint32_t fpemu_fetch(const void *pc)
{
	const volatile uint16_t *h = (const volatile uint16_t *)pc;
	uint32_t lo = h[0];

	return (lo & 3u) == 3u ? lo | ((uint32_t)h[1] << 16) : lo;
}

/* ---- rounding mode and flags --------------------------------------- */

/* The effective rounding mode for [rm], or -1 if reserved (5, 6, or a
 * dynamic mode whose frm is reserved). RISC-V and SoftFloat number the
 * five modes identically (RNE, RTZ, RDN, RUP, RMM). */
static int eff_rm(const struct fpemu_state *st, unsigned rm)
{
	if (rm == 7) {
		rm = (st->fcsr >> 5) & 7u;
	}
	return rm <= 4 ? (int)rm : -1;
}

static inline void begin(int rm)
{
	softfloat_roundingMode = (uint_fast8_t)rm;
	softfloat_exceptionFlags = 0;
}

/* SoftFloat's flag bits equal RISC-V fflags (NX 1, UF 2, OF 4, DZ 8, NV 16). */
static inline void end(struct fpemu_state *st)
{
	st->fcsr |= softfloat_exceptionFlags & 0x1Fu;
}

/* ---- sign injection, min/max, classify ----------------------------- */

static inline bool nan32(uint32_t v)
{
	return (v & 0x7F800000u) == 0x7F800000u && (v & 0x007FFFFFu);
}

static inline bool snan32(uint32_t v)
{
	return nan32(v) && !(v & 0x00400000u);
}

static inline bool nan64(uint64_t v)
{
	return (v & 0x7FF0000000000000ull) == 0x7FF0000000000000ull &&
	       (v & 0x000FFFFFFFFFFFFFull);
}

static inline bool snan64(uint64_t v)
{
	return nan64(v) && !(v & 0x0008000000000000ull);
}

/* IEEE 754-2019 minimumNumber / maximumNumber, as FMIN/FMAX specify. */
static uint32_t minmax32(struct fpemu_state *st, float32_t a, float32_t b, bool max)
{
	if (snan32(a.v) || snan32(b.v)) {
		st->fcsr |= softfloat_flag_invalid;
	}
	if (nan32(a.v) && nan32(b.v)) {
		return CANON_NAN32;
	}
	if (nan32(a.v)) {
		return b.v;
	}
	if (nan32(b.v)) {
		return a.v;
	}
	bool lt = f32_lt_quiet(a, b) || (f32_eq(a, b) && (a.v & SIGN32));

	return max ? (lt ? b.v : a.v) : (lt ? a.v : b.v);
}

static uint64_t minmax64(struct fpemu_state *st, float64_t a, float64_t b, bool max)
{
	if (snan64(a.v) || snan64(b.v)) {
		st->fcsr |= softfloat_flag_invalid;
	}
	if (nan64(a.v) && nan64(b.v)) {
		return CANON_NAN64;
	}
	if (nan64(a.v)) {
		return b.v;
	}
	if (nan64(b.v)) {
		return a.v;
	}
	bool lt = f64_lt_quiet(a, b) || (f64_eq(a, b) && (a.v & SIGN64));

	return max ? (lt ? b.v : a.v) : (lt ? a.v : b.v);
}

static uint32_t classify(bool sign, bool inf, bool nan, bool snan, bool zero, bool sub)
{
	if (nan) {
		return snan ? 1u << 8 : 1u << 9;
	}
	if (inf) {
		return sign ? 1u << 0 : 1u << 7;
	}
	if (zero) {
		return sign ? 1u << 3 : 1u << 4;
	}
	if (sub) {
		return sign ? 1u << 2 : 1u << 5;
	}
	return sign ? 1u << 1 : 1u << 6;
}

static uint32_t fclass32(uint32_t v)
{
	uint32_t e = (v >> 23) & 0xFFu, m = v & 0x7FFFFFu;

	return classify(v & SIGN32, e == 0xFF && !m, nan32(v), snan32(v), !e && !m, !e && m);
}

static uint32_t fclass64(uint64_t v)
{
	uint32_t e = (uint32_t)(v >> 52) & 0x7FFu;
	uint64_t m = v & 0x000FFFFFFFFFFFFFull;

	return classify(v & SIGN64, e == 0x7FF && !m, nan64(v), snan64(v), !e && !m, !e && m);
}

/* ---- instruction groups -------------------------------------------- */

static int op_load_store(struct fpemu_state *st, uint32_t *x, uint32_t insn)
{
	unsigned opcode = insn & 0x7Fu, f3 = (insn >> 12) & 7u, rs1 = (insn >> 15) & 31u;
	int32_t imm;

	if (opcode == 0x07) { /* LOAD-FP */
		imm = (int32_t)insn >> 20;
		uintptr_t a = rx(x, rs1) + (uint32_t)imm;
		unsigned rd = (insn >> 7) & 31u;

		if (f3 == 2) {
			st->f[rd] = BOX_HI | ld32(a);
		} else if (f3 == 3) {
			st->f[rd] = ld64(a);
		} else {
			return 0;
		}
		return 4;
	}
	/* STORE-FP */
	imm = ((int32_t)(insn & 0xFE000000u) >> 20) | (int32_t)((insn >> 7) & 31u);
	uintptr_t a = rx(x, rs1) + (uint32_t)imm;
	unsigned rs2 = (insn >> 20) & 31u;

	if (f3 == 2) {
		st32(a, (uint32_t)st->f[rs2]);
	} else if (f3 == 3) {
		st64(a, st->f[rs2]);
	} else {
		return 0;
	}
	return 4;
}

static int op_fma(struct fpemu_state *st, uint32_t insn)
{
	unsigned opcode = insn & 0x7Fu, rd = (insn >> 7) & 31u, rs1 = (insn >> 15) & 31u,
		 rs2 = (insn >> 20) & 31u, rs3 = insn >> 27, fmt = (insn >> 25) & 3u;
	int rm = eff_rm(st, (insn >> 12) & 7u);
	/* FMADD 43: a*b+c, FMSUB 47: a*b-c, FNMSUB 4B: -(a*b)+c, FNMADD 4F: -(a*b)-c */
	bool neg_prod = opcode == 0x4B || opcode == 0x4F;
	bool neg_add = opcode == 0x47 || opcode == 0x4F;

	if (rm < 0 || fmt > FMT_D) {
		return 0;
	}
	begin(rm);
	if (fmt == FMT_S) {
		float32_t a = rs32(st, rs1), b = rs32(st, rs2), c = rs32(st, rs3);

		a.v ^= neg_prod ? SIGN32 : 0;
		c.v ^= neg_add ? SIGN32 : 0;
		wf32(st, rd, f32_mulAdd(a, b, c));
	} else {
		float64_t a = rs64(st, rs1), b = rs64(st, rs2), c = rs64(st, rs3);

		a.v ^= neg_prod ? SIGN64 : 0;
		c.v ^= neg_add ? SIGN64 : 0;
		wf64(st, rd, f64_mulAdd(a, b, c));
	}
	end(st);
	return 4;
}

static int op_fp(struct fpemu_state *st, uint32_t *x, uint32_t insn)
{
	unsigned rd = (insn >> 7) & 31u, f3 = (insn >> 12) & 7u, rs1 = (insn >> 15) & 31u,
		 rs2 = (insn >> 20) & 31u, f7 = insn >> 25, fmt = f7 & 3u, op = f7 >> 2;
	int rm = eff_rm(st, f3);

	if (fmt > FMT_D) {
		return 0;
	}
	bool d = fmt == FMT_D;

	switch (op) {
	case 0x00: /* FADD */
	case 0x01: /* FSUB */
	case 0x02: /* FMUL */
	case 0x03: /* FDIV */
	case 0x0B: /* FSQRT (rs2 must be 0) */
		if (rm < 0 || (op == 0x0B && rs2 != 0)) {
			return 0;
		}
		begin(rm);
		if (d) {
			float64_t a = rs64(st, rs1), b = rs64(st, rs2), r;

			r = op == 0x00 ? f64_add(a, b) : op == 0x01 ? f64_sub(a, b)
			    : op == 0x02 ? f64_mul(a, b) : op == 0x03 ? f64_div(a, b) : f64_sqrt(a);
			wf64(st, rd, r);
		} else {
			float32_t a = rs32(st, rs1), b = rs32(st, rs2), r;

			r = op == 0x00 ? f32_add(a, b) : op == 0x01 ? f32_sub(a, b)
			    : op == 0x02 ? f32_mul(a, b) : op == 0x03 ? f32_div(a, b) : f32_sqrt(a);
			wf32(st, rd, r);
		}
		end(st);
		return 4;

	case 0x04: /* FSGNJ / FSGNJN / FSGNJX */
		if (f3 > 2) {
			return 0;
		}
		if (d) {
			uint64_t a = st->f[rs1], b = st->f[rs2];
			uint64_t s = f3 == 0 ? b : f3 == 1 ? ~b : a ^ b;

			st->f[rd] = (a & ~SIGN64) | (s & SIGN64);
		} else {
			uint32_t a = rs32(st, rs1).v, b = rs32(st, rs2).v;
			uint32_t s = f3 == 0 ? b : f3 == 1 ? ~b : a ^ b;

			st->f[rd] = BOX_HI | (a & ~SIGN32) | (s & SIGN32);
		}
		return 4;

	case 0x05: /* FMIN / FMAX */
		if (f3 > 1) {
			return 0;
		}
		if (d) {
			st->f[rd] = minmax64(st, rs64(st, rs1), rs64(st, rs2), f3 == 1);
		} else {
			st->f[rd] = BOX_HI | minmax32(st, rs32(st, rs1), rs32(st, rs2), f3 == 1);
		}
		return 4;

	case 0x08: /* FCVT.S.D (fmt S, rs2 1) / FCVT.D.S (fmt D, rs2 0) */
		if (rm < 0 || rs2 != (d ? 0u : 1u)) {
			return 0;
		}
		begin(rm);
		if (d) {
			wf64(st, rd, f32_to_f64(rs32(st, rs1)));
		} else {
			wf32(st, rd, f64_to_f32(rs64(st, rs1)));
		}
		end(st);
		return 4;

	case 0x14: /* FLE (0) / FLT (1) / FEQ (2) */
		if (f3 > 2) {
			return 0;
		}
		begin(0);
		if (d) {
			float64_t a = rs64(st, rs1), b = rs64(st, rs2);

			wx(x, rd, f3 == 0 ? f64_le(a, b) : f3 == 1 ? f64_lt(a, b) : f64_eq(a, b));
		} else {
			float32_t a = rs32(st, rs1), b = rs32(st, rs2);

			wx(x, rd, f3 == 0 ? f32_le(a, b) : f3 == 1 ? f32_lt(a, b) : f32_eq(a, b));
		}
		end(st);
		return 4;

	case 0x18: /* FCVT.W[U].fmt: rs2 0 signed, 1 unsigned */
		if (rm < 0 || rs2 > 1) {
			return 0;
		}
		begin(rm);
		if (d) {
			float64_t a = rs64(st, rs1);

			wx(x, rd, rs2 ? (uint32_t)f64_to_ui32(a, (uint_fast8_t)rm, true)
				      : (uint32_t)f64_to_i32(a, (uint_fast8_t)rm, true));
		} else {
			float32_t a = rs32(st, rs1);

			wx(x, rd, rs2 ? (uint32_t)f32_to_ui32(a, (uint_fast8_t)rm, true)
				      : (uint32_t)f32_to_i32(a, (uint_fast8_t)rm, true));
		}
		end(st);
		return 4;

	case 0x1A: /* FCVT.fmt.W[U] */
		if (rm < 0 || rs2 > 1) {
			return 0;
		}
		begin(rm);
		if (d) {
			wf64(st, rd, rs2 ? ui32_to_f64(rx(x, rs1)) : i32_to_f64((int32_t)rx(x, rs1)));
		} else {
			wf32(st, rd, rs2 ? ui32_to_f32(rx(x, rs1)) : i32_to_f32((int32_t)rx(x, rs1)));
		}
		end(st);
		return 4;

	case 0x1C: /* FMV.X.W (f3 0, S only on RV32) / FCLASS (f3 1) */
		if (rs2 != 0) {
			return 0;
		}
		if (f3 == 0 && !d) {
			wx(x, rd, (uint32_t)st->f[rs1]); /* raw low word, no unboxing */
			return 4;
		}
		if (f3 == 1) {
			wx(x, rd, d ? fclass64(st->f[rs1]) : fclass32(rs32(st, rs1).v));
			return 4;
		}
		return 0;

	case 0x1E: /* FMV.W.X (S only on RV32) */
		if (d || f3 != 0 || rs2 != 0) {
			return 0;
		}
		st->f[rd] = BOX_HI | rx(x, rs1);
		return 4;
	}
	return 0;
}

/* fflags (0x001), frm (0x002), fcsr (0x003) via CSRRW/S/C[I]. */
static int op_csr(struct fpemu_state *st, uint32_t *x, uint32_t insn)
{
	unsigned f3 = (insn >> 12) & 7u, rd = (insn >> 7) & 31u, src = (insn >> 15) & 31u,
		 csr = insn >> 20;
	uint32_t old, val, mask, shift;

	if (f3 == 0 || f3 == 4 || csr < 1 || csr > 3) {
		return 0;
	}
	switch (csr) {
	case 1:
		shift = 0;
		mask = 0x1Fu;
		break;
	case 2:
		shift = 5;
		mask = 0x7u;
		break;
	default:
		shift = 0;
		mask = 0xFFu;
		break;
	}
	old = (st->fcsr >> shift) & mask;
	val = f3 >= 5 ? src : rx(x, src);
	bool write = (f3 & 3u) == 1 || src != 0; /* CSRRS/C with x0 or uimm 0 only read */
	uint32_t nv = (f3 & 3u) == 1 ? val : (f3 & 3u) == 2 ? old | val : old & ~val;

	if (write) {
		st->fcsr = (st->fcsr & ~(mask << shift)) | ((nv & mask) << shift);
		st->fcsr &= 0xFFu;
	}
	wx(x, rd, old);
	return 4;
}

/* Compressed FP loads/stores: C.FLD, C.FLW, C.FSD, C.FSW and the SP forms. */
static int op_compressed(struct fpemu_state *st, uint32_t *x, uint32_t insn)
{
	unsigned q = insn & 3u, f3 = (insn >> 13) & 7u;
	uint32_t off;
	uintptr_t a;

	if (q == 0) {
		unsigned r1 = ((insn >> 7) & 7u) + 8, r2 = ((insn >> 2) & 7u) + 8;

		if (f3 == 1 || f3 == 5) { /* C.FLD / C.FSD: [12:10]->5:3, [6:5]->7:6 */
			off = (((insn >> 10) & 7u) << 3) | (((insn >> 5) & 3u) << 6);
		} else if (f3 == 3 || f3 == 7) { /* C.FLW / C.FSW: [12:10]->5:3, [6]->2, [5]->6 */
			off = (((insn >> 10) & 7u) << 3) | (((insn >> 6) & 1u) << 2) |
			      (((insn >> 5) & 1u) << 6);
		} else {
			return 0;
		}
		a = rx(x, r1) + off;
		switch (f3) {
		case 1:
			st->f[r2] = ld64(a);
			break;
		case 3:
			st->f[r2] = BOX_HI | ld32(a);
			break;
		case 5:
			st64(a, st->f[r2]);
			break;
		default:
			st32(a, (uint32_t)st->f[r2]);
			break;
		}
		return 2;
	}
	if (q == 2) {
		unsigned rd = (insn >> 7) & 31u, rs2 = (insn >> 2) & 31u;

		switch (f3) {
		case 1: /* C.FLDSP: [12]->5, [6:5]->4:3, [4:2]->8:6 */
			off = (((insn >> 12) & 1u) << 5) | (((insn >> 5) & 3u) << 3) |
			      (((insn >> 2) & 7u) << 6);
			st->f[rd] = ld64(rx(x, 2) + off);
			return 2;
		case 3: /* C.FLWSP: [12]->5, [6:4]->4:2, [3:2]->7:6 */
			off = (((insn >> 12) & 1u) << 5) | (((insn >> 4) & 7u) << 2) |
			      (((insn >> 2) & 3u) << 6);
			st->f[rd] = BOX_HI | ld32(rx(x, 2) + off);
			return 2;
		case 5: /* C.FSDSP: [12:10]->5:3, [9:7]->8:6 */
			off = (((insn >> 10) & 7u) << 3) | (((insn >> 7) & 7u) << 6);
			st64(rx(x, 2) + off, st->f[rs2]);
			return 2;
		case 7: /* C.FSWSP: [12:9]->5:2, [8:7]->7:6 */
			off = (((insn >> 9) & 15u) << 2) | (((insn >> 7) & 3u) << 6);
			st32(rx(x, 2) + off, (uint32_t)st->f[rs2]);
			return 2;
		}
	}
	return 0;
}

int fpemu_execute(struct fpemu_state *st, uint32_t *x, uint32_t insn)
{
	if ((insn & 3u) != 3u) {
		return op_compressed(st, x, insn & 0xFFFFu);
	}
	switch (insn & 0x7Fu) {
	case 0x07: /* LOAD-FP */
	case 0x27: /* STORE-FP */
		return op_load_store(st, x, insn);
	case 0x43:
	case 0x47:
	case 0x4B:
	case 0x4F:
		return op_fma(st, insn);
	case 0x53:
		return op_fp(st, x, insn);
	case 0x73:
		return op_csr(st, x, insn);
	}
	return 0;
}
