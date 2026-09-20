#!/usr/bin/env python3
"""bms_control.py - send commands to one JoySuny (Sphere / RV) BMS over BLE and
decode the replies with the SAME parser as read_batteries.py.

    python bms_control.py probe      2C14AA   # connect, handshake, classify (streaming / dormant)
    python bms_control.py wake       2C14AA   # standby-off + BEGIN + vendor turn-on gate frame
    python bms_control.py sleep-off  2C14AA   # Bluetooth-standby mode OFF (persistent BMS setting)
    python bms_control.py sleep-on   2C14AA --yes
    python bms_control.py output-on  2C14AA   # charge + discharge MOS on (safe write)
    python bms_control.py output-off 2C14AA --yes   # sends standby-off first; needs a fresh status
    python bms_control.py restart    2C14AA --yes
    python bms_control.py raw 2C14AA c31e0101010000000000d43b --yes   # expert: any frame

Serial = the hex after "JS-" / "RV-" in the advertised name (or a full MAC).

Safety model (same as the app): anything that can turn a switch OFF is refused
unless a BAL_STATUS was decoded on THIS connection within 15 s; ON / restart use
a safe base (both MOS = 1, low-temp protection = 1) when no fresh base exists.
Output-off sends Bluetooth-standby OFF first, because a pack with its output off
cannot pass current and, if it enters standby, cannot be woken over BLE.

read_batteries.py is untouched; this tool only imports it. Every TX/RX line is
appended to control-<serial>.log in the reader's log format.
"""
import argparse
import asyncio
import sys
import time

from bleak import BleakClient, BleakScanner

import read_batteries as rb

CMD_SLEEP_ON = bytes.fromhex("AACC0001DDEE")
CMD_SLEEP_OFF = bytes.fromhex("AACC0101DDEE")
GATE_BEGIN = bytes.fromhex("C31E")
GATE_END = bytes.fromhex("D43B")
FRESH_S = 15.0
GATE_KEYS = ("chg_mos", "dis_mos", "passive_bal", "temp_gate", "smoke_gate", "heat_gate")


class Link:
    def __init__(self, serial, echo=True):
        self.serial = serial
        self.log = open(f"control-{serial}.log", "a", encoding="utf-8")
        self.parser = rb.Parser(serial, self.log, echo=echo)
        self.client = None
        self.frames = 0
        self.stray = 0
        self.last_bal = None  # monotonic time of the last decoded BAL_STATUS

    def _on_notify(self, _sender, data):
        data = bytes(data)
        self.frames += 1
        if data == b"0":
            self.stray += 1
        self.parser.add(data)
        if b"\xa8\xac" in data:
            self.last_bal = time.monotonic()

    async def tx(self, tag, cmd):
        try:
            await self.client.write_gatt_char(rb.WRITE_CHAR, cmd, response=True)
        except Exception:
            await self.client.write_gatt_char(rb.WRITE_CHAR, cmd, response=False)
        self.parser.log_tx(tag, cmd)
        print(f"TX {tag}: {rb.hexs(cmd)}")

    async def handshake(self):
        for tag, cmd in (("TX_WAKE", rb.CMD_BEGIN),
                         ("TX_REQUEST_ESTIMATE", rb.CMD_GET_EST),
                         ("TX_REQUEST_VERSION", rb.CMD_GET_VERSION)):
            await self.tx(tag, cmd)
            await asyncio.sleep(0.3)

    def fresh_base(self):
        s = self.parser.state
        if self.last_bal is None or time.monotonic() - self.last_bal > FRESH_S:
            return None
        if any(s.get(k) is None for k in GATE_KEYS):
            return None
        return [int(s["chg_mos"]), int(s["dis_mos"]), int(s["temp_gate"]),
                int(s["smoke_gate"]), int(s["heat_gate"]), 0, int(s["passive_bal"]), 0]

    @staticmethod
    def safe_base():
        # both MOS on, low-temp protection on, nothing else - cannot switch anything off
        return [1, 1, 1, 0, 0, 0, 0, 0]

    @staticmethod
    def gate_frame(base):
        return GATE_BEGIN + bytes(base) + GATE_END

    async def wait_frames(self, secs):
        n0 = self.frames
        await asyncio.sleep(secs)
        return self.frames - n0

    def status_line(self):
        s = self.parser.state
        if self.last_bal is not None:
            return (f"STREAMING chgMos={s.get('chg_mos')} disMos={s.get('dis_mos')} "
                    f"passive={s.get('passive_bal')} tempGate={s.get('temp_gate')} "
                    f"smoke={s.get('smoke_gate')} heat={s.get('heat_gate')} "
                    f"soc={s.get('soc')}% V={s.get('sum')} I={s.get('current')} "
                    f"standbyMode={s.get('sleep')}")
        if self.frames and self.frames == self.stray:
            return ("DORMANT: the BLE bridge answers (status byte 0x30) but the BMS sends "
                    "no telemetry - BMS MCU not running; needs current through the pack "
                    "(isolate it and charge it alone) or its reset button")
        if self.frames == 0:
            return "SILENT: connected, no bytes at all"
        return f"PARTIAL: {self.frames} notifications, no BAL_STATUS yet"


async def find(serial, timeout=15):
    target = serial.upper()
    found = {}

    def cb(d, a):
        name = (a.local_name or d.name or "").upper()
        if d.address.upper() == target or name.endswith(target):
            found["dev"] = d

    scanner = BleakScanner(detection_callback=cb)
    await scanner.start()
    t0 = time.monotonic()
    while "dev" not in found and time.monotonic() - t0 < timeout:
        await asyncio.sleep(0.2)
    await scanner.stop()
    return found.get("dev")


async def connect(link, attempts=4):
    for n in range(1, attempts + 1):
        dev = await find(link.serial)
        if dev is None:
            print(f"{link.serial}: not advertising (held by another app, or off)")
            return False
        try:
            link.client = BleakClient(dev, timeout=25)
            await link.client.connect()
            await link.client.start_notify(rb.NOTIFY_CHAR, link._on_notify)
            return True
        except Exception as e:  # WinRT flakes right after connect are common
            print(f"connect attempt {n}: {type(e).__name__}: {e}")
            try:
                await link.client.disconnect()
            except Exception:
                pass
            await asyncio.sleep(3)
    return False


async def run(args):
    link = Link(args.serial)
    if not await connect(link):
        return 2
    try:
        await link.handshake()
        await link.wait_frames(4)
        print("status:", link.status_line())
        cmd = args.command
        if cmd == "probe":
            return 0 if link.last_bal else 1
        if cmd == "wake":
            await link.tx("TX_SLEEP_OFF", CMD_SLEEP_OFF)
            await asyncio.sleep(1)
            await link.tx("TX_WAKE", rb.CMD_BEGIN)
            await asyncio.sleep(0.3)
            await link.tx("TX_REQUEST_ESTIMATE", rb.CMD_GET_EST)
            await asyncio.sleep(2.5)
            await link.tx("TX_GATE_TURN_ON", link.gate_frame(link.fresh_base() or link.safe_base()))
            await link.wait_frames(6)
            print("status:", link.status_line())
            return 0 if link.last_bal else 1
        if cmd == "sleep-off":
            await link.tx("TX_SLEEP_OFF", CMD_SLEEP_OFF)
        elif cmd == "sleep-on":
            await link.tx("TX_SLEEP_ON", CMD_SLEEP_ON)
        elif cmd == "output-on":
            base = link.fresh_base() or link.safe_base()
            base[0] = base[1] = 1
            await link.tx("TX_GATE_OUTPUT_ON", link.gate_frame(base))
        elif cmd == "output-off":
            base = link.fresh_base()
            if base is None:
                print("REFUSED: output-off needs a BAL_STATUS within 15 s on this "
                      "connection (a stale base could flip other gates)")
                return 3
            if link.parser.state.get("sleep") is not False:
                print("standby on/unknown -> sending standby-OFF first so the pack "
                      "cannot go dormant with its output off")
                await link.tx("TX_SLEEP_OFF", CMD_SLEEP_OFF)
                await asyncio.sleep(2)
            base[0] = base[1] = 0
            await link.tx("TX_GATE_OUTPUT_OFF", link.gate_frame(base))
        elif cmd == "restart":
            base = link.fresh_base() or link.safe_base()
            base[5] = 1
            await link.tx("TX_GATE_RESTART", link.gate_frame(base))
        elif cmd == "raw":
            await link.tx("TX_RAW", bytes.fromhex(args.hex))
        await link.wait_frames(5)
        print("status:", link.status_line())
        return 0
    finally:
        try:
            await link.client.stop_notify(rb.NOTIFY_CHAR)
            await link.client.disconnect()
        except Exception:
            pass
        link.log.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("command", choices=["probe", "wake", "sleep-off", "sleep-on",
                                        "output-on", "output-off", "restart", "raw"])
    ap.add_argument("serial", help="hex serial after JS-/RV- (e.g. 2C14AA) or a MAC")
    ap.add_argument("hex", nargs="?", help="frame bytes for 'raw'")
    ap.add_argument("--yes", action="store_true",
                    help="confirm a state-changing command (sleep-on, output-off, restart, raw)")
    args = ap.parse_args()
    if args.command in ("sleep-on", "output-off", "restart", "raw") and not args.yes:
        print(f"{args.command} changes BMS state - re-run with --yes")
        sys.exit(4)
    if args.command == "raw" and not args.hex:
        print("raw needs the frame hex")
        sys.exit(4)
    sys.exit(asyncio.run(run(args)))


if __name__ == "__main__":
    main()
