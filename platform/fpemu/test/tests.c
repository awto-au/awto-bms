/*
 * Differential tests for fpemu. The same binary runs on a CPU with a real
 * F/D FPU and on one with none (every F/D instruction trapped into fpemu).
 * Each (instruction, rounding mode) prints an FNV-1a hash over every
 * result's raw bits and the fflags it raised; the two runs must match.
 * Build with -DVERBOSE to print each case instead of hashes.
 */
#include <stdint.h>

#include "harness.h"

/* ---- operand sets -------------------------------------------------- */

static const uint64_t D[] = {
	0x0000000000000000ull, 0x8000000000000000ull, /* +0, -0 */
	0x3FF0000000000000ull, 0xBFF0000000000000ull, /* 1, -1 */
	0x3FF8000000000000ull, 0x4004000000000000ull, /* 1.5, 2.5 */
	0xC004000000000000ull, 0x3FB999999999999Aull, /* -2.5, 0.1 */
	0x7FEFFFFFFFFFFFFFull, 0xFFEFFFFFFFFFFFFFull, /* +-max */
	0x0010000000000000ull, 0x0000000000000001ull, /* min normal, min subnormal */
	0x000FFFFFFFFFFFFFull, 0x7FF0000000000000ull, /* max subnormal, +inf */
	0xFFF0000000000000ull, 0x7FF8000000000000ull, /* -inf, qNaN */
	0x7FF0000000000001ull, 0xFFF8000000000123ull, /* sNaN, -qNaN payload */
	0x41E0000000000000ull, 0xC1E0000000000000ull, /* 2^31, -2^31 */
	0x41F0000000000000ull, 0x41EFFFFFFFF00000ull, /* 2^32, 2^32-1 (4294967295) */
	0x3FD5555555555555ull, 0x4008000000000000ull, /* 1/3, 3 */
	0x01A56E1FC2F8F359ull, 0x41DFFFFFFFE00000ull, /* 1e-300, 2^31-1-0.5ish */
};
#define ND (int)(sizeof(D) / sizeof(D[0]))

#define B(v) (0xFFFFFFFF00000000ull | (uint32_t)(v))
static const uint64_t S[] = {
	B(0x00000000), B(0x80000000), B(0x3F800000), B(0xBF800000),
	B(0x3FC00000), B(0x40200000), B(0xC0200000), B(0x3DCCCCCD),
	B(0x7F7FFFFF), B(0xFF7FFFFF), B(0x00800000), B(0x00000001),
	B(0x007FFFFF), B(0x7F800000), B(0xFF800000), B(0x7FC00000),
	B(0x7F800001), B(0xFFC00123), B(0x4F000000), B(0xCF000000),
	B(0x4F800000), B(0x3EAAAAAB), B(0x40400000), B(0x0DA24260),
	0x000000003F800000ull, /* not NaN-boxed: must read as canonical NaN */
	0x123456783F800000ull, /* not NaN-boxed either */
};
#define NS (int)(sizeof(S) / sizeof(S[0]))

static const uint32_t I[] = {
	0, 1, 0xFFFFFFFFu, 0x7FFFFFFFu, 0x80000000u, 12345678u, 16777217u,
	0x7FFFFFC0u, 3u, 0xFFFFFFFDu,
};
#define NI (int)(sizeof(I) / sizeof(I[0]))

/* FMA uses a smaller set: the cube is large. */
static const int FMA_D[] = {0, 1, 2, 3, 5, 7, 8, 11, 13, 15, 16, 21};
static const int FMA_S[] = {0, 1, 2, 3, 5, 7, 8, 11, 13, 15, 16, 24};
#define NF 12

/* ---- hashing / output ---------------------------------------------- */

static uint32_t h;
static uint32_t cases;

static void mix(uint64_t v)
{
	for (int i = 0; i < 8; i++) {
		h ^= (uint8_t)(v >> (i * 8));
		h *= 16777619u;
	}
}

static void rec(uint64_t res, uint32_t fl)
{
	mix(res);
	mix(fl);
	cases++;
#ifdef VERBOSE
	puthex(res, 16);
	putch(' ');
	puthex(fl, 2);
	putch('\n');
#endif
}

static void begin_group(void)
{
	h = 2166136261u;
	cases = 0;
}

static void end_group(const char *name, int rm)
{
	puts_(name);
	puts_(" rm=");
	putdec((uint32_t)rm);
	puts_(" n=");
	putdec(cases);
	puts_(" h=");
	puthex(h, 8);
	putch('\n');
}

static void set_frm(int rm)
{
	__asm__ volatile("fsrm %0" : : "r"(rm));
}

/* ---- per-instruction probes (dynamic rounding unless stated) ------- */

#define F2F(NAME, INS)                                                        \
	static uint32_t NAME(const uint64_t *a, const uint64_t *b, uint64_t *r) \
	{                                                                     \
		uint32_t fl;                                                  \
		__asm__ volatile("fsflags x0\n\tfld ft0,0(%1)\n\tfld ft1,0(%2)\n\t" INS \
				 " ft2,ft0,ft1\n\tfsd ft2,0(%3)\n\tfrflags %0"  \
				 : "=&r"(fl)                                  \
				 : "r"(a), "r"(b), "r"(r)                     \
				 : "ft0", "ft1", "ft2", "memory");            \
		return fl;                                                    \
	}
#define F1F(NAME, INS)                                                        \
	static uint32_t NAME(const uint64_t *a, const uint64_t *b, uint64_t *r) \
	{                                                                     \
		uint32_t fl;                                                  \
		(void)b;                                                      \
		__asm__ volatile("fsflags x0\n\tfld ft0,0(%1)\n\t" INS        \
				 " ft2,ft0\n\tfsd ft2,0(%2)\n\tfrflags %0"      \
				 : "=&r"(fl)                                  \
				 : "r"(a), "r"(r)                             \
				 : "ft0", "ft2", "memory");                   \
		return fl;                                                    \
	}
#define F2X(NAME, INS)                                                        \
	static uint32_t NAME(const uint64_t *a, const uint64_t *b, uint64_t *r) \
	{                                                                     \
		uint32_t fl, x;                                               \
		__asm__ volatile("fsflags x0\n\tfld ft0,0(%2)\n\tfld ft1,0(%3)\n\t" INS \
				 " %1,ft0,ft1\n\tfrflags %0"                    \
				 : "=&r"(fl), "=&r"(x)                        \
				 : "r"(a), "r"(b)                             \
				 : "ft0", "ft1", "memory");                   \
		*r = x;                                                       \
		return fl;                                                    \
	}
#define F1X(NAME, INS)                                                        \
	static uint32_t NAME(const uint64_t *a, const uint64_t *b, uint64_t *r) \
	{                                                                     \
		uint32_t fl, x;                                               \
		(void)b;                                                      \
		__asm__ volatile("fsflags x0\n\tfld ft0,0(%2)\n\t" INS " %1,ft0\n\tfrflags %0" \
				 : "=&r"(fl), "=&r"(x)                        \
				 : "r"(a)                                     \
				 : "ft0", "memory");                          \
		*r = x;                                                       \
		return fl;                                                    \
	}
#define X1F(NAME, INS)                                                        \
	static uint32_t NAME(uint32_t a, uint64_t *r)                         \
	{                                                                     \
		uint32_t fl;                                                  \
		__asm__ volatile("fsflags x0\n\t" INS " ft2,%1\n\tfsd ft2,0(%2)\n\tfrflags %0" \
				 : "=&r"(fl)                                  \
				 : "r"(a), "r"(r)                             \
				 : "ft2", "memory");                          \
		return fl;                                                    \
	}
#define F3F(NAME, INS)                                                        \
	static uint32_t NAME(const uint64_t *a, const uint64_t *b,             \
			     const uint64_t *c, uint64_t *r)                   \
	{                                                                     \
		uint32_t fl;                                                  \
		__asm__ volatile("fsflags x0\n\tfld ft0,0(%1)\n\tfld ft1,0(%2)\n\t" \
				 "fld ft3,0(%3)\n\t" INS                        \
				 " ft2,ft0,ft1,ft3\n\tfsd ft2,0(%4)\n\tfrflags %0" \
				 : "=&r"(fl)                                  \
				 : "r"(a), "r"(b), "r"(c), "r"(r)             \
				 : "ft0", "ft1", "ft2", "ft3", "memory");     \
		return fl;                                                    \
	}

F2F(fadd_d, "fadd.d") F2F(fsub_d, "fsub.d") F2F(fmul_d, "fmul.d") F2F(fdiv_d, "fdiv.d")
F2F(fadd_s, "fadd.s") F2F(fsub_s, "fsub.s") F2F(fmul_s, "fmul.s") F2F(fdiv_s, "fdiv.s")
F2F(fsgnj_d, "fsgnj.d") F2F(fsgnjn_d, "fsgnjn.d") F2F(fsgnjx_d, "fsgnjx.d")
F2F(fsgnj_s, "fsgnj.s") F2F(fsgnjn_s, "fsgnjn.s") F2F(fsgnjx_s, "fsgnjx.s")
F2F(fmin_d, "fmin.d") F2F(fmax_d, "fmax.d") F2F(fmin_s, "fmin.s") F2F(fmax_s, "fmax.s")
F1F(fsqrt_d, "fsqrt.d") F1F(fsqrt_s, "fsqrt.s")
F1F(fcvt_s_d, "fcvt.s.d") F1F(fcvt_d_s, "fcvt.d.s")
F2X(feq_d, "feq.d") F2X(flt_d, "flt.d") F2X(fle_d, "fle.d")
F2X(feq_s, "feq.s") F2X(flt_s, "flt.s") F2X(fle_s, "fle.s")
F1X(fcvt_w_d, "fcvt.w.d") F1X(fcvt_wu_d, "fcvt.wu.d")
F1X(fcvt_w_s, "fcvt.w.s") F1X(fcvt_wu_s, "fcvt.wu.s")
F1X(fclass_d, "fclass.d") F1X(fclass_s, "fclass.s") F1X(fmv_x_w, "fmv.x.w")
X1F(fcvt_d_w, "fcvt.d.w") X1F(fcvt_d_wu, "fcvt.d.wu")
X1F(fcvt_s_w, "fcvt.s.w") X1F(fcvt_s_wu, "fcvt.s.wu") X1F(fmv_w_x, "fmv.w.x")
F3F(fmadd_d, "fmadd.d") F3F(fmsub_d, "fmsub.d") F3F(fnmsub_d, "fnmsub.d") F3F(fnmadd_d, "fnmadd.d")
F3F(fmadd_s, "fmadd.s") F3F(fmsub_s, "fmsub.s") F3F(fnmsub_s, "fnmsub.s") F3F(fnmadd_s, "fnmadd.s")


typedef uint32_t (*op2)(const uint64_t *, const uint64_t *, uint64_t *);
typedef uint32_t (*opx)(uint32_t, uint64_t *);
typedef uint32_t (*op3)(const uint64_t *, const uint64_t *, const uint64_t *, uint64_t *);

struct t2 {
	const char *name;
	op2 fn;
	int dbl;
	int unary;
};

static const struct t2 T2[] = {
	{"fadd.d", fadd_d, 1, 0},   {"fsub.d", fsub_d, 1, 0},   {"fmul.d", fmul_d, 1, 0},
	{"fdiv.d", fdiv_d, 1, 0},   {"fadd.s", fadd_s, 0, 0},   {"fsub.s", fsub_s, 0, 0},
	{"fmul.s", fmul_s, 0, 0},   {"fdiv.s", fdiv_s, 0, 0},   {"fsgnj.d", fsgnj_d, 1, 0},
	{"fsgnjn.d", fsgnjn_d, 1, 0}, {"fsgnjx.d", fsgnjx_d, 1, 0}, {"fsgnj.s", fsgnj_s, 0, 0},
	{"fsgnjn.s", fsgnjn_s, 0, 0}, {"fsgnjx.s", fsgnjx_s, 0, 0}, {"fmin.d", fmin_d, 1, 0},
	{"fmax.d", fmax_d, 1, 0},   {"fmin.s", fmin_s, 0, 0},   {"fmax.s", fmax_s, 0, 0},
	{"feq.d", feq_d, 1, 0},     {"flt.d", flt_d, 1, 0},     {"fle.d", fle_d, 1, 0},
	{"feq.s", feq_s, 0, 0},     {"flt.s", flt_s, 0, 0},     {"fle.s", fle_s, 0, 0},
	{"fsqrt.d", fsqrt_d, 1, 1}, {"fsqrt.s", fsqrt_s, 0, 1}, {"fcvt.s.d", fcvt_s_d, 1, 1},
	{"fcvt.d.s", fcvt_d_s, 0, 1}, {"fcvt.w.d", fcvt_w_d, 1, 1}, {"fcvt.wu.d", fcvt_wu_d, 1, 1},
	{"fcvt.w.s", fcvt_w_s, 0, 1}, {"fcvt.wu.s", fcvt_wu_s, 0, 1}, {"fclass.d", fclass_d, 1, 1},
	{"fclass.s", fclass_s, 0, 1}, {"fmv.x.w", fmv_x_w, 0, 1},
};

static const struct {
	const char *name;
	opx fn;
} TX[] = {
	{"fcvt.d.w", fcvt_d_w}, {"fcvt.d.wu", fcvt_d_wu}, {"fcvt.s.w", fcvt_s_w},
	{"fcvt.s.wu", fcvt_s_wu}, {"fmv.w.x", fmv_w_x},
};

static const struct {
	const char *name;
	op3 fn;
	int dbl;
} T3[] = {
	{"fmadd.d", fmadd_d, 1},  {"fmsub.d", fmsub_d, 1},  {"fnmsub.d", fnmsub_d, 1},
	{"fnmadd.d", fnmadd_d, 1}, {"fmadd.s", fmadd_s, 0},  {"fmsub.s", fmsub_s, 0},
	{"fnmsub.s", fnmsub_s, 0}, {"fnmadd.s", fnmadd_s, 0},
};

#define N(a) (int)(sizeof(a) / sizeof((a)[0]))

static void run_instruction_tests(void)
{
	uint64_t r;

	for (int t = 0; t < N(T2); t++) {
		const uint64_t *v = T2[t].dbl ? D : S;
		int n = T2[t].dbl ? ND : NS;

		for (int rm = 0; rm < 5; rm++) {
			set_frm(rm);
			begin_group();
			for (int i = 0; i < n; i++) {
				for (int j = 0; j < (T2[t].unary ? 1 : n); j++) {
					r = 0;
					uint32_t fl = T2[t].fn(&v[i], &v[j], &r);

					rec(r, fl);
				}
			}
			end_group(T2[t].name, rm);
		}
	}
	for (int t = 0; t < N(TX); t++) {
		for (int rm = 0; rm < 5; rm++) {
			set_frm(rm);
			begin_group();
			for (int i = 0; i < NI; i++) {
				r = 0;
				uint32_t fl = TX[t].fn(I[i], &r);

				rec(r, fl);
			}
			end_group(TX[t].name, rm);
		}
	}
	for (int t = 0; t < N(T3); t++) {
		const uint64_t *v = T3[t].dbl ? D : S;
		const int *idx = T3[t].dbl ? FMA_D : FMA_S;

		for (int rm = 0; rm < 5; rm++) {
			set_frm(rm);
			begin_group();
			for (int i = 0; i < NF; i++) {
				for (int j = 0; j < NF; j++) {
					for (int k = 0; k < NF; k++) {
						r = 0;
						uint32_t fl = T3[t].fn(&v[idx[i]], &v[idx[j]],
								       &v[idx[k]], &r);

						rec(r, fl);
					}
				}
			}
			end_group(T3[t].name, rm);
		}
	}
}

/* Static rounding modes (rm field in the instruction, frm set to RNE). */
#define SRM(RM)                                                               \
	static void static_##RM(void)                                         \
	{                                                                     \
		set_frm(0);                                                   \
		begin_group();                                                \
		for (int i = 0; i < ND; i++) {                                \
			for (int j = 0; j < ND; j++) {                        \
				uint64_t r = 0;                               \
				uint32_t fl;                                  \
				__asm__ volatile("fsflags x0\n\tfld ft0,0(%1)\n\tfld ft1,0(%2)\n\t" \
						 "fadd.d ft2,ft0,ft1," #RM "\n\tfsd ft2,0(%3)\n\tfrflags %0" \
						 : "=&r"(fl)                  \
						 : "r"(&D[i]), "r"(&D[j]), "r"(&r) \
						 : "ft0", "ft1", "ft2", "memory"); \
				rec(r, fl);                                   \
			}                                                     \
			uint64_t r = 0;                                       \
			uint32_t fl, x;                                       \
			__asm__ volatile("fsflags x0\n\tfld ft0,0(%2)\n\tfcvt.w.d %1,ft0," #RM "\n\t" \
					 "fcvt.s.d ft2,ft0," #RM "\n\tfsd ft2,0(%3)\n\tfrflags %0" \
					 : "=&r"(fl), "=&r"(x)                \
					 : "r"(&D[i]), "r"(&r)                \
					 : "ft0", "ft2", "memory");           \
			rec(r, fl);                                           \
			rec(x, 0);                                            \
		}                                                             \
		end_group("static " #RM, 0);                                  \
	}
SRM(rne) SRM(rtz) SRM(rdn) SRM(rup) SRM(rmm)

static void csr_tests(void)
{
	uint32_t a, b, c, d, e;

	begin_group();
	__asm__ volatile("fscsr %0, %1" : "=r"(a) : "r"(0xFFu));         /* write all */
	__asm__ volatile("frcsr %0" : "=r"(b));                           /* 0xFF */
	__asm__ volatile("fsrmi %0, 2" : "=r"(c));                        /* old frm 7 */
	__asm__ volatile("fsflagsi %0, 5" : "=r"(d));                     /* old flags 0x1F */
	__asm__ volatile("frcsr %0" : "=r"(e));                           /* 0x45 */
	rec(a, b);
	rec(c, d);
	rec(e, 0);
	__asm__ volatile("csrrs %0, fflags, %1" : "=r"(a) : "r"(0x10u));  /* set NV */
	__asm__ volatile("csrrc %0, fflags, %1" : "=r"(b) : "r"(0x01u));  /* clear NX */
	__asm__ volatile("csrrsi %0, frm, 0" : "=r"(c));                  /* read only */
	__asm__ volatile("csrrci %0, fcsr, 31" : "=r"(d));                /* clear flags */
	__asm__ volatile("frcsr %0" : "=r"(e));
	rec(a, b);
	rec(c, d);
	rec(e, 0);
	__asm__ volatile("fscsr x0");
	end_group("csr", 0);
}

/* Compressed FP loads/stores (the assembler compresses these operands). */
static void compressed_tests(void)
{
	static uint64_t buf[8] = {0x1111111122222222ull, 0x3333333344444444ull,
				  0x5555555566666666ull, 0x7777777788888888ull};
	uint64_t out[4] = {0};

	begin_group();
	__asm__ volatile(
		"mv a1, %0\n\t"
		"mv a2, %1\n\t"
		"fld fa0, 8(a1)\n\t"       /* c.fld */
		"flw fa1, 16(a1)\n\t"      /* c.flw */
		"fsd fa0, 0(a2)\n\t"       /* c.fsd */
		"fsw fa1, 8(a2)\n\t"       /* c.fsw */
		"addi sp, sp, -32\n\t"
		"fsd fa0, 16(sp)\n\t"      /* c.fsdsp */
		"fsw fa1, 4(sp)\n\t"       /* c.fswsp */
		"fld fa2, 16(sp)\n\t"      /* c.fldsp */
		"flw fa3, 4(sp)\n\t"       /* c.flwsp */
		"addi sp, sp, 32\n\t"
		"fsd fa2, 16(a2)\n\t"
		"fsd fa3, 24(a2)\n\t"
		:
		: "r"(buf), "r"(out)
		: "a1", "a2", "fa0", "fa1", "fa2", "fa3", "memory");
	for (int i = 0; i < 4; i++) {
		rec(out[i], 0);
	}
	end_group("compressed", 0);
}

/* A double-heavy workload through normal compiled code (ilp32d calls). */
static double __attribute__((noinline)) poly(double x, double a, double b)
{
	return (x * a + b) / (x - 0.5) + x * x * x;
}

static double __attribute__((noinline)) newton_sqrt(double v)
{
	double g = v > 1.0 ? v * 0.5 : 1.0;

	for (int i = 0; i < 30; i++) {
		g = 0.5 * (g + v / g);
	}
	return g;
}

static float __attribute__((noinline)) fsum(const float *p, int n)
{
	float s = 0.0f;

	for (int i = 0; i < n; i++) {
		s += p[i] * 1.0001f;
	}
	return s;
}

static void workload_tests(void)
{
	union {
		double d;
		uint64_t u;
	} v;
	union {
		float f;
		uint32_t u;
	} w;
	float arr[16];

	begin_group();
	set_frm(0);
	double acc = 0.0;

	for (int i = 1; i <= 200; i++) {
		acc += poly((double)i / 7.0, 1.25, -3.0);
		acc -= newton_sqrt((double)i * 3.3);
		v.d = acc;
		rec(v.u, 0);
	}
	for (int i = 0; i < 16; i++) {
		arr[i] = (float)i / 3.0f;
	}
	w.f = fsum(arr, 16);
	rec(w.u, 0);
	int32_t k = (int32_t)(acc * 1000.0);
	rec((uint32_t)k, 0);
	end_group("workload", 0);
}

int main(void)
{
	puts_("fpemu differential test\n");
	run_instruction_tests();
	static_rne();
	static_rtz();
	static_rdn();
	static_rup();
	static_rmm();
	csr_tests();
	compressed_tests();
	workload_tests();
	puts_("emulated=");
	putdec(emulated_count());
	puts_("\nDONE\n");
	return 0;
}
