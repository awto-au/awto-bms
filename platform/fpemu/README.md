# fpemu: RISC-V F/D emulation for Zephyr (ESP32-P4)

Part of ADR 0002 (`docs/adr/0002-dart-everywhere.md`, issue #78). Dart's
RISC-V code generator assumes the D extension (double-precision float). The
ESP32-P4 is `rv32imafc`: single precision only. fpemu lets code built for
`rv32imafdc` / `ilp32d` run on such a core:

- The FPU is left **off** (`mstatus.FS = 0`).
- Every F and D instruction, and every `fcsr`/`frm`/`fflags` access, raises an
  illegal-instruction exception.
- The trap handler performs the instruction on a 64-bit shadow register file
  and resumes after it.

Arithmetic is Berkeley SoftFloat 3e (vendored subset, BSD-3-Clause) with the
RISC-V specialisation:

- canonical NaN and NaN-boxing of singles;
- RISC-V conversion saturation;
- all five rounding modes, static and dynamic;
- fflags accrued exactly as hardware does.

## Layout

| Path | What |
|---|---|
| `include/fpemu.h`, `src/fpemu.c` | OS-independent core: decode and execute one instruction. Covers all RV32 F and D instructions, the FMA group, the fcsr/frm/fflags CSRs, and the compressed FP loads/stores. |
| `softfloat/`, `softfloat-sources.txt` | SoftFloat 3e, only the 61 files used (`softfloat/VENDORED.md`). |
| `zephyr/`, `src/zephyr/` | Zephyr module. Provides `z_riscv_fpemu_trap()`. F/D state lives in thread-local storage. |
| `zephyr-patches/0001-*.patch` | Zephyr patch (base `1ee3b93`) adding `CONFIG_RISCV_FP_EMULATION`. |
| `test/`, `Makefile` | Bare-metal differential test on QEMU. |
| `samples/zephyr_diff/` | The same suite plus a two-thread test, on Zephyr. |

## The Zephyr patch

`CONFIG_RISCV_FP_EMULATION` (needs `!FPU`, `THREAD_LOCAL_STORAGE`, RV32, no
USERSPACE) changes three things:

1. **Compiler flags:** `-march=...fd`, `-mabi=ilp32d`. The FPU is never
   enabled.
2. **Compressed instructions:** C is expressed as **Zca + Zcf, without Zcd**.
   P4 rev 3 silicon implements Zcmp/Zcmt, which reuse the compressed
   double-store encoding space (`c.fsdsp`), so compressed double loads and
   stores must never be emitted. Otherwise they would execute as `cm.*`
   instructions instead of trapping. Confidence: medium; confirm against the
   Espressif TRM.
3. **Exception entry** (`arch/riscv/core/isr.S`): on mcause 2 it calls
   `z_riscv_fpemu_trap(esf)`. If that returns non-zero the exception returns
   straight away, through the same restore path as the lazy-FPU trap.

`src/zephyr/fpemu_trap.S` captures s1–s11, gp and tp (the esf only holds the
caller-saved registers and s0). It then reloads them afterwards, in case the
emulated instruction wrote one.

## Testing

Both tests run the **same binary twice**: once on a QEMU CPU with a real F/D
FPU, and once on a CPU with no FPU, so every F/D instruction goes through
fpemu. The outputs must be identical.

**What the suite covers** (`test/tests.c`):
- every F/D instruction over edge values: ±0, subnormals, ±inf, quiet and
  signalling NaNs, integer-conversion limits, and singles that are not
  NaN-boxed;
- all five rounding modes via `frm`, plus the static rounding-mode encodings;
- CSR reads and writes;
- compressed loads and stores;
- a double-heavy C workload using `ilp32d` calls.

The fused multiply-add tests use a 12-value cube.

| Test | Result (2026-09-28) |
|---|---|
| Bare metal: `make test` | PASS, 248 groups identical, 1,001,741 instructions emulated |
| Zephyr `qemu_riscv32`: `prj.conf` (emulated) vs `prj_hw.conf` (real FPU with `FPU_SHARING`) | PASS, 248 groups plus the two-thread test identical, 1,002,157 emulated |
| Mutation check: dynamic rounding mode ignored; fclass sNaN/qNaN confused | Both detected (test FAILs) |
| Emulator objects contain no F/D instruction (`make check-no-fp`) | PASS |

Size: fpemu plus SoftFloat is about 14.5 KB of code (`-O2`). Per-thread
state is 260 bytes of TLS.

**Running the Zephyr pair** (with the patch applied to Zephyr):

```sh
cmake -S samples/zephyr_diff -B build-emu -GNinja -DBOARD=qemu_riscv32 -DZEPHYR_MODULES=$PWD
ninja -C build-emu
qemu-system-riscv32 -machine virt -bios none -m 256 -nographic -no-reboot \
  -cpu rv32,f=false,d=false,zfa=false,zfh=false,zfhmin=false -kernel build-emu/zephyr/zephyr.elf
```

Build `-DCONF_FILE=prj_hw.conf` and run with `-cpu rv32` for the reference.

## Limits and open points

- **Interrupt handlers must not use floating point.** State is per thread,
  and an ISR would use the interrupted thread's registers.
- **Performance is not measured on hardware.** Each F/D instruction costs a
  trap plus a SoftFloat call, likely hundreds of cycles. BMS decoding is
  integer work; double-heavy Dart code will be slow.
- **Kernel mode only** (no USERSPACE). The trapped `sp` is taken as the esf
  address plus its size.
- **SMP:** the state is per thread (TLS), so two harts trapping at once do
  not collide. Tested single-core only.
- **Not yet run on an ESP32-P4.** QEMU cannot model the P4 itself; the no-FPU
  CPU stands in for "FPU off".
