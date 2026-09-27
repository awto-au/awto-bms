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
- **A slim, Dartino-style runtime.** Not needed: the targets are high-end ESP32s
  that can hold the standard runtime.

## Decision

**Dart is the single language on every target.**

| Target | Runtime | UI |
|---|---|---|
| iPhone, Android | Standard Dart ahead-of-time | Flutter |
| Windows, Linux, Raspberry Pi | Standard Dart ahead-of-time (headless hub possible) | Flutter; flutter-pi for Pi panels |
| Zephyr on ESP32 RISC-V (P4 class) | Standard Dart ahead-of-time runtime, **ported to Zephyr**, using the SDK's 32-bit RISC-V backend | Flutter-style rendering on vygl |

- **Embedded scope:** only the latest ESP32 RISC-V chips, P4 class, with PSRAM,
  on current Zephyr. No minimal or slim runtime, and no support for small chips
  (C3/C6/H2 class) or the Xtensa chips (original ESP32, S2, S3).
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
- **Hardware:** the embedded bill of materials is P4-class. Cheap headless
  readers on small ESP32s are out of scope by choice.

## Risks

- **32-bit RISC-V in the Dart SDK is experimental.** Its maturity, ABI and
  floating-point assumptions must be checked against the P4 (rv32imafc:
  single-precision FPU only). If the runtime assumes double-precision hardware
  float, that is a major blocker. This is the first thing to verify.
- **Runtime assumptions:** the runtime assumes virtual-memory behaviour (address
  reservation, write-XOR-execute code pages, guard pages). A flat heap must
  satisfy the allocator's alignment and reservation contracts.
- **Size:** runtime + program + heap must fit the P4's flash and PSRAM with
  room for the Bluetooth and Wi-Fi stacks.
- **Flutter rendering on vygl** is a separate, large piece of work.

## Next steps

1. Survey the runtime's OS-specific code (issue #78; in progress). Produce a
   function-by-function list of what Zephyr's POSIX layer covers, what needs
   new code and what can be stubbed, with a size estimate.
2. First milestone: an ahead-of-time "hello world" from the standard runtime on
   Zephyr `qemu_riscv32` (or the closest 32-bit RISC-V target), before any
   ESP32-P4 hardware.
3. Second milestone: `battery_protocol.dart` and `bms_codecs.dart` running on
   that target and passing the captured-frame tests.
