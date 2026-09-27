# ADR 0002: Dart everywhere

- Status: **Proposed**. Direction set by the user; the runtime-port estimate is pending. Issue #78.
- Date: 2026-09-27
- Scope: AWTO's RV/van platform (BMS, and later switches, tanks, DC-DC, solar),
  not only `awto-bms`.

## Context

AWTO wants one system that brings RV devices together: batteries, switches,
chargers and displays. It should be lightweight and RV-focused, not a
general-purpose home-automation install. The requirement that drives this
decision is **one codebase** for:

- phones (iPhone, Android), where any phone can act as the hub;
- desktop and embedded Linux (Windows, Linux, Raspberry Pi panels);
- embedded controllers and displays on Zephyr.

What exists today:

- The protocol code is already pure Dart with no Flutter import:
  `lib/battery_protocol.dart` (JoySuny), `lib/bms_codecs.dart` (JBD, JK, ANT,
  Daly, Redodo, SmartBat) and `lib/bms_families.dart`. Captured-frame tests pin
  every decoder.
- `BleTransport` already hides the Bluetooth plugin behind an interface.
- `awtoau/vygl` is LVGL with the runtime XML UI loader restored (XML screens,
  named subjects, `bind_text` / `bind_value`, charts).

Alternatives considered:

- **Home Assistant or Venus OS as the base.** Useful for interoperability, but
  heavier and not a single codebase. They are kept as integration targets only
  (see "Interop").
- **Toit on ESP32.** Its VM is the maintained successor of Dartino's design, is
  proven on ESP32, and has good concepts (isolated processes, app updates over
  Wi-Fi). Rejected as the platform because it is a second language and runs on
  ESP-IDF, not Zephyr. It stays a design reference.
- **Dart to WebAssembly on a Wasm runtime.** `dart2wasm` output still expects a
  JavaScript host; its standalone mode is under development. Not ready.

## Decision

**Dart is the single language on every target.**

| Target | Runtime | UI |
|---|---|---|
| iPhone, Android | Standard Dart ahead-of-time | Flutter |
| Windows, Linux, Raspberry Pi | Standard Dart ahead-of-time (headless hub possible) | Flutter; flutter-pi for Pi panels |
| Zephyr on ESP32 RISC-V (P4 class) | Standard Dart ahead-of-time runtime, **ported to Zephyr**, using the SDK's 32-bit RISC-V backend | Flutter-style rendering on vygl |

- **Embedded scope:** only the latest ESP32 RISC-V chips, P4 class, with PSRAM,
  on current Zephyr, running the standard runtime.
- **The Zephyr port:** Zephyr gets its own versions of the runtime's
  OS-specific files (threads, virtual memory, time, entropy, files, sockets),
  using Zephyr's POSIX layer where it fits. Memory protection is dropped: the
  "reserve", "commit" and "protect" calls work on a flat PSRAM heap, and
  protection changes do nothing. The language and core-library API stay
  unchanged.
- **Shared code:** protocol codecs, protocol files, the device model and hub
  logic are pure Dart and run unchanged everywhere. The existing captured-frame
  tests become the conformance suite for every target.
- **Bluetooth:** one `BleTransport` per platform: Android/iOS plugin, BlueZ on
  Linux, Zephyr's Bluetooth stack on ESP32.
- **Hub:** exactly one hub holds each battery's Bluetooth connection (these
  packs accept one connection at a time). Other screens read from the hub over
  the local network.
- **Interop:** the hub publishes MQTT with Home Assistant Discovery, so Home
  Assistant, Victron (Venus OS) and ESPHome devices can share data without
  being dependencies.

## Consequences

- **Cheapest part:** the Dart code itself. Most of it already exists and is
  tested.
- **Largest new work:**
  - the Zephyr platform layer for the Dart runtime, including loading the
    precompiled program from flash or PSRAM;
  - a Flutter-style renderer on vygl for ESP32 displays.
- **Maintenance:** AWTO will maintain a Dart runtime fork (the Zephyr platform
  files) and vygl.
- **Hardware:** the embedded bill of materials is P4-class.

## Runtime survey (issue #78, 2026-09-27)

Source read: dart-lang/sdk at `d4be401`. Nothing was built or run.

**Floating point: the one real blocker.**
- Dart's RISC-V backend requires double-precision hardware float (the D
  extension). `runtime/vm/constants_riscv.h` has `kFpuRegisterSize = 8`, and
  the baseline ISA is RVA20 = RV_GC, which includes D.
- `double` code emits D instructions directly: `fld`/`fsd`/`faddd` and more,
  in `il_riscv.cc`, `assembler_riscv.cc` and `flow_graph_compiler_riscv.cc`.
- The riscv32 FFI assumes the ilp32d calling convention.
- The ESP32-P4 is rv32imafc: single-precision FPU only.

Two ways through, keeping the chip:

1. **Emulate F and D in a trap handler.** Zephyr runs with the FPU off and
   emulates every F/D instruction against a 64-bit shadow register file in its
   illegal-instruction handler. The generated code stays unchanged. About
   1.5–2.5k lines of C. Doubles become slow, roughly hundreds of cycles per
   operation. **Fastest route to a running system.**
2. **A soft-double mode in the Dart RISC-V backend.** Doubles live in integer
   register pairs or go through runtime helpers. About 3–6k lines in the
   compiler, and unlikely to be accepted upstream. Fast doubles, at the cost of
   maintaining a compiler fork.

Recommended: start with option 1. Move to option 2 only if profiling shows
double-heavy code matters. BMS decoding is almost entirely integer work.

**Other findings.**
- **Pointers:** compressed pointers are 64-bit only, so no 4 GB address
  reservation is needed on rv32.
- **Registers:** Dart already reserves TP and GP, so it is compatible with
  Zephyr's thread-local storage and GP-relative addressing.
- **Heap pages** are 512 KB and must be 512 KB-aligned, which gives at most
  64 pages in 32 MB of PSRAM. A flat, aligned page allocator satisfies this,
  but memory is tight.
- **Thread stacks** default to 512 KB per thread. Stacks must be tuned smaller
  and the thread count kept low.
- **64-bit atomics** on rv32 need `__atomic_*_8` (libatomic or a spinlock
  shim).
- **Program loading:** link the precompiled program into the firmware as
  assembly (`app-aot-assembly`) and run it in place. This avoids the ELF
  loader and writable+executable pages. Execute-in-place from flash or PSRAM
  on Zephyr for the P4 is still to be verified.

**Size of the Zephyr platform layer.**
- **Model:** the Fuchsia port is 31 files, about 6.9k lines, plus 91
  conditionals elsewhere.
- **OS layer:** a Zephyr port needs about 12–18 new `*_zephyr.cc` files
  (about 2.5–4k lines), reusing the shared `*_posix.cc` files. About 225 files
  need a `DART_HOST_OS_ZEPHYR` branch added or reviewed.
- **Classification:**
  - *Covered by Zephyr POSIX:* threads, mutexes and condvars, clocks, sleep,
    stdio.
  - *New Zephyr code:* virtual memory on a flat PSRAM heap (commit and protect
    become no-ops), stack bounds, thread-local storage, entropy
    (`sys_csrand_get`), time zones or UTC only, and the dart:io event handler
    (a `poll()` loop).
  - *Stubbed for a first port:* signals and the profiler, spawning processes,
    native symbol lookup, file watching, and sockets until later.
- **Build:** a Zephyr module or GN toolchain for the runtime sources, about
  1–2k lines. Tedious rather than hard.
- **Embedder:** about 500 lines. Initialise with the linked-in program, run
  one isolate, run a message loop.

## Risks

- **Floating point:** see above. The trap-emulation route is well understood
  but makes doubles slow.
- **32-bit RISC-V maturity in the Dart SDK:** 12 `UNIMPLEMENTED()` remain in
  `il_riscv.cc`, some on 32-bit paths. The cross-compiler for riscv32 must be
  built on a 32-bit host. CI coverage is unverified.
- **Memory:** 512 KB heap pages, thread stacks, and the Bluetooth and Wi-Fi
  stacks all share PSRAM.
- **Zephyr support for the ESP32-P4** (core, PSRAM, cache, running code from
  PSRAM) is not yet verified.
- **Flutter rendering on vygl** is a separate, large piece of work.

## Next steps

1. **M0:** build the riscv32 cross-compiler and the Linux riscv32 runtime, and
   run an ahead-of-time "hello world" under `qemu-riscv32` user mode. This
   proves the toolchain and program format with no Zephyr involved.
2. **M1:** the same "hello world" on Zephyr `qemu_riscv32`: program linked as
   assembly, virtual memory on a static aligned arena, dart:io stubbed, D still
   enabled.
3. **M2:** the same on an rv32imafc configuration with the F/D trap emulator.
4. **M3:** ESP32-P4 hardware with PSRAM, then `battery_protocol.dart` and
   `bms_codecs.dart` passing the captured-frame tests on it.
