# Sphere Battery 1.0.24 — App / UI logic reverse-engineering

Scope: application & UI logic, constants, passwords, gestures, settings/OTA flows, and the
UI-action → BLE-command map. Byte-level frame parsing is another agent's job; where a UI
action triggers a command I name the command and its BatteryManager (BM) method, not the bytes.

Tree: `artifacts/sphere-battery-1.0.24/jadx/sources/com/joysuny/batteryutil/`
Package abbreviations used below: `MVM` = `actvm/MainViewModel.java`, `MM` = `actmodel/MainModel.java`,
`BVM` = `actvm/BatteryViewModel.java`, `SVM` = `fragmentvm/SetViewModel.java`,
`SModel` = `fragmentmodel/SetModel.java`, `DVM` = `fragmentvm/DialViewModel.java`,
`DModel` = `fragmentmodel/DialModel.java`, `BM` = `blemanager/BatteryManager.java`.

Nothing here has been run against a live battery. All findings are static (jadx decompile).

---

## 0. Corrections to the baseline PROTOCOL.md

The baseline's "Hidden service mode" section (PROTOCOL.md L256–284) is mostly right but has
concrete errors in the Parameter-tab control list and the connect-password note. Corrections:

1. **The Parameter (Settings) tab has NO "low-temp protect" control and NO "history read/clear"
   control.** These were listed in PROTOCOL.md L272 and L306–309. In this build:
   - `setLowTemProtect()` (BM L227) is sent **once, automatically, during the handshake** — it is
     not wired to any view. There is no low-temp UI.
   - `getHistory()` (BM L200), `setHistoryStatus()` (BM L204), `cleanAllHistory()` (BM L222) and
     the `CMD_GET_HISTORY` / `CMD_CLEAR_HISTORY` / `CMD_SET_HISTORY_STATUS` commands are **defined
     but never called from any UI class** (grep of the whole package: only definitions in BM /
     BatteryCMD, zero call sites). History is dead code in the app — there is no history screen.
2. **The per-device connect password is NOT user-changeable in this build.** PROTOCOL.md implied
   it might be stored/changeable. It is read from pref `connect_password`
   (`SpManager.SP_CONNECT_BT_PASSWORD`) with default `JS2023` at MVM L532, but **no code ever
   writes that pref** (grep: `SP_CONNECT_BT_PASSWORD` appears only at its definition and the one
   read). So it is effectively a hard constant `JS2023`. The only user-changeable password is the
   Settings-tab one (see §2).
3. **The firmware-update flow has TWO entry points with different gating** (baseline described only
   the main-screen one). The Parameter-tab "BMS Firmware Update" path is **not** filename-locked and
   is **not** behind the `332211` prompt — see §4.
4. Baseline's Parameter-tab row list (from the emulator run) is otherwise accurate. The confirmed
   control set is in §3.
5. Minor: the "info icon" long-press view is `iv_info`; there is **also** a separate, non-hidden
   info button (`getInfo`) that opens `GuideActivity` — a different screen that also writes to the
   BMS with no password (see §7). Don't conflate the two.

---

## 1. Hidden service-mode unlock (exact gesture)

Source: `MVM.initPwdViewListener()` L113–167, and `listener/MultiClickListener.java`.

`MultiClickListener` (default ctor L15–20): `count = 4`, `duration = 2000 ms`, `hits = long[4]`.
`onClick` (L29–41) shifts the timestamp ring buffer and fires `onClickValid` only when the oldest
of the last 4 taps is within `now − 2000 ms`, i.e. **4 taps within 2 s**; it then zeroes the buffer.

Two boolean flags gate the sequence: `mIsLogoClicked`, `mIsCurClicked` (both reset to `false` in
`initPwdViewListener` L114–115).

Exact sequence to reach service mode:

| Step | View (binding id) | Action | Effect | Code |
|---|---|---|---|---|
| 1 | `iv_logo` | 4 taps within 2 s | `mIsLogoClicked = true` | MVM L130–135 |
| 2 | `iv_cur` (current readout) | 4 taps within 2 s | if `mIsLogoClicked`, `mIsCurClicked = true` | MVM L136–143 |
| 3 | `iv_info` | **long-press** | if both flags true → password dialog | MVM L144–166 |
| 4 | password dialog | enter `339933` | opens `BatteryActivity` (service mode) | MVM L150–156 |

Details / edge cases:
- Step 2's `onClickValid` only sets `mIsCurClicked` **if `mIsLogoClicked` is already true** (L139),
  so order (logo → cur) is enforced. There is **no** overall timeout linking step 1 → step 2 → step 3;
  each 4-tap burst has its own 2 s window, but the flags persist until reset.
- The long-press handler returns `true` (consumes) in both branches; if either flag is false it does
  nothing (L147–148).
- **Reset conditions:** a click on the root background `cl_background` (L116–122) or on the dial
  container `cl_dial` (L123–129) sets both flags back to `false`. Pressing Cancel/close on the
  password dialog also resets both (`onCancel`, MVM L158–162). A wrong password shows a toast and
  calls `onCancel` (dialog dismiss) → flags reset. Individual taps on logo/cur do **not** clear the
  other flag.
- Password value: `Global.DEFAULT_BACK_PWD = "339933"` (Global L8), passed to
  `PasswordDialog.setPassword(...)` at MVM L150. Default (6-char) dialog variant → must be exactly 6
  chars (see §2 dialog rules). This is a plain constant; not user-changeable, not stored.
- On confirm (MVM L152–156): `new BatteryActivity().setBT(mGatt, mBluzConnector)` stashes the GATT +
  connector in static fields, stops the main listener, and `startActivity(BatteryActivity)`. Works
  even with nothing connected (`mGatt` may be null; `BatteryViewModel.initManager` L56–60 just skips
  building a BatteryManager) — matches the baseline's emulator note.

`BatteryActivity` hosts two fragments in a ViewPager2 (`BVM.initPager` L62–77): index 0 =
`DialFragment` (service dial), index 1 = `SetFragment` (Parameter tab). Bottom nav switches them.

---

## 2. Every password / gate value and where each is used

All password checks are **local** (`PasswordDialog.mPassword.equalsIgnoreCase(mPwd)`, dialog L114).
Nothing is transmitted to the BMS (confirmed: no send() carries any password string).

### PasswordDialog length rules (`dialog/PasswordDialog.java`)
- Two constructors: `PasswordDialog(ctx)` → `mIs8To16 = false`; `PasswordDialog(ctx, true)` →
  `mIs8To16 = true` (L45–56).
- Confirm button enabled only when typed length > 5 (`onTextChanged` L192–196).
- Validation (L113): accepts if `length == 6` **OR** (`mIs8To16` && length 8..16). So the non-8To16
  dialog requires **exactly 6 chars**; the 8To16 dialog requires **8–16 chars**.
- Compare is case-insensitive (`equalsIgnoreCase`, L114).
- `iv_reset` button in the dialog has an **empty onClick** (L139–143) — dead stub.

### Password matrix

| Gate | Value | Const | Dialog variant | Used at | Stored / changeable? |
|---|---|---|---|---|---|
| Per-device connect prompt | `JS2023` | `DEFAULT_CONNECT_PASSWORD` (Global L10) | 6-char | MVM `clickOk` L531–532 | Read from pref `connect_password` default `JS2023`; **never written → constant** |
| Hidden service-mode | `339933` | `DEFAULT_BACK_PWD` (Global L8) | 6-char | MVM L150 | Constant; not stored |
| Settings/Parameter tab | `JS20230801` | `DEFAULT_PASSWORD` (Global L11) | **8To16** | BVM L106 | **User-changeable**, pref `fragment_password` (`SP_SETFRAGMENT_PASSWORD`), default `JS20230801` |
| Firmware update (main-screen path) | `332211` | `DEFAULT_UPDATE_PWD` (Global L12) | 6-char | MVM `update`→`AnonymousClass15` L616 | Constant; not stored |

Notes:
- The connect prompt gates adding freshly-scanned devices to the saved list (`clickOk` L531–554),
  **not** the actual BLE connect — tapping an already-saved device connects with no prompt
  (`AnonymousClass6.onItemChildClick` L216 onward).
- The settings-tab prompt gates swiping to the Parameter fragment (BVM L105–122): password read
  from `SP_SETFRAGMENT_PASSWORD` (default `DEFAULT_PASSWORD`); on cancel it snaps back to the dial.
- **Changing the settings password** — `dialog/ResetDialog.java`, launched by `SVM.passwordNext`
  (Parameter tab "Reset User Password", SVM L235–246):
  - old field must equal current stored `SP_SETFRAGMENT_PASSWORD` (ResetDialog L49, L66);
  - new field must be length 8–16 (L85) **and not all-digits** (`isonlyNumber` L164–174 → must
    contain at least one non-digit) (L90);
  - confirm must equal new and also not all-digits (L112–116);
  - on success writes the new value to `SP_SETFRAGMENT_PASSWORD` (L132). No BMS involvement.
- The firmware-update password `332211` gates only the **main-screen** update button (§4).

---

## 3. Parameter (Settings) tab — controls and command map

Fragment `SetFragment` / `SVM`. Controls wired in `SVM.initView` L140–188 (toggles) and via
`fragment_set.xml` onClick bindings (confirmed in `FragmentSetBindingImpl`):
`restartNext`, `passwordNext`, `setBattery`, `factoryNext`, `update`.

Confirmed full control set (top-to-bottom matches baseline emulator run):

| # | Control (view) | Handler | Model call | BLE command (BM method) | Pref written |
|---|---|---|---|---|---|
| 1 | MOS Switch `sw_mos` (toggle) | SVM L142–148 | `SModel.setMos` L121 | `CMD_GATE_CONTROL`, `BM.setMos(z)` L164 (charge MOS = discharge MOS = z) | writes `setting_mos` before send (SVM L145) |
| 2 | Low Power Sleep Mode `sw_sleep` | SVM L150–156 | `SModel.setSleep` L128 | `CMD_OPEN_SLEEP_CONTROL` / `CMD_CLOSE_SLEEP_CONTROL`, `BM.setSleepMode(z)` L131 | writes `setting_sleep_mode` (SVM L153) |
| 3 | Heat Up `sw_heat` | SVM L157–163 | `SModel.setHeat` L135 | `CMD_GATE_CONTROL`, `BM.setHeat(z)` L158 | `heat_gate` written inside BM.setHeat L160 |
| 4 | Passive Equalization `sw_passive` | SVM L164–171 | `SModel.setPassiva` L142 | `CMD_GATE_CONTROL`, `BM.setPassiva(z)` L153 | writes `setting_passiva` (SVM L168) |
| 5 | Restart BMS System | `SVM.restartNext` L199–210 → `RestartDialog` confirm | `SModel.setRestart` L149 | `CMD_GATE_CONTROL` w/ restart byte=1, `BM.setRestart()` L139 | none |
| 6 | Restore To Factory Default | `SVM.factoryNext` L212–223 → `RestartDialog`(factory text) confirm | `SModel.setFactory` L163 | `CMD_GATE_CONTROL` w/ factory byte=1, `BM.setFactory()` L148 | none |
| 7 | Battery Capacity (default 100 AH) | `SVM.setBattery` L225–233 → `SetBatteryDialog` | `SModel.setBattery(str)` L156 | `CMD_BATTERY`, `BM.setBattery(str)` L168 (Ah×1000, 24-bit) | `sp_setting_battery_capacity` (on STATUS ack via `batteryRes`, SModel L113) |
| 8 | Reset User Password | `SVM.passwordNext` L235–246 → `ResetDialog` | (local only) | none | `fragment_password` (ResetDialog L132) |
| 9 | Temp Unit Conversion `ts_temp` | SVM L178–187 | `SModel.saveTempStatus` L109 | none (display-only, app-side °C/°F) | `setting_temp_type` |
| 10 | BMS Firmware Update | `SVM.update` L248–257 | — | opens `UpdateActivity` (see §4, unlocked path) | — |
| 11 | BMS Version (display) | `tv_version` | `SModel.getVersion`→`BM.getVersion()` (fires `CMD_GET_VERSION` `AT+V`) | read-only text | — |

Confirmation toasts for every gate result come back via `SetViewModel.mSetListener.gateRes(...)`
(SVM L68–109) — 8 booleans: charge/discharge/temp/smoke/warm(heat)/restart/bal/factory.

**Danger notes (UI):**
- **Restart** and **Factory reset** use `RestartDialog` (a generic yes/no) — factory adds a warning
  string (`dialog_factory_title/tips`, SVM L222) but there is **no password** beyond the tab entry.
- **MOS off / Passive / Heat** toggles fire immediately on switch change with **no confirmation**.
- Every gate setter re-sends the whole 8-byte gate payload, backfilling untouched fields from the
  SP cache — see §5.

The service **Dial** fragment (`DVM`) is display-only: `sbtn_mos` and `sbtn_bla` status indicators
(DVM L105–106), per-cell voltage grid, temps, warn counts. Its `cl_more` view is forced
`setVisibility(4)` (DVM L113) and `more(View)` is an **empty stub** (DVM L65–66). There is a second
`judgeMoreDisplay()` (DVM L236) that would show `cl_more` when a warn list is non-empty, but `more()`
does nothing, so the button is inert either way — dead UI.

---

## 4. Firmware update (OTA) — UI side

The app ships no `.bin` and downloads none; the user picks a local file
(`UpdateViewModel.selectFile` L60–72, `ACTION_OPEN_DOCUMENT`, octet-stream/any).

### Two entry points

**A. Main-screen update button** (`MVM.update` L637 → `MM.getVersion` → listener `AnonymousClass15`):
1. `MM.getVersion()` (L411) sends `CMD_GET_VERSION`; the version string comes back via
   `IReadIOListener.getVersion` (MM L390–397) and maps to a boolean `mIsNewest`:
   - `JS5.1` / `JS5.2` → `getVersion(true)` (Global.JS5_1 L19, JS5_2 L21)
   - `JS3.1`(="JS1.0", Global.JS3_1 L16) / `JS3.2` (L18) → `getVersion(false)`
   - **Any other version string → nothing happens** (no else branch, MM L392–396) — update button
     silently no-ops for unrecognised firmware.
2. Password prompt `332211` (`DEFAULT_UPDATE_PWD`, MVM L616).
3. On confirm, requires a live link (`mGatt`+`mBluzConnector` non-null, else toast, MVM L623–625).
4. `new UpdateActivity().setBT(true, gatt, connector, isNewest)` — `mIsMainAct = true`,
   `mIsNewest = isNewest` (UpdateActivity L44–49), then `startActivity(UpdateActivity)`.
5. **Filename lock** in `UpdateActivity.onActivityResult` (L111–147), only when `mIsMainAct`:
   - accepts `PB51250506.bin` (`Global.JS3_1_FILE` L17) **iff** `!mIsNewest`
   - accepts `8803250506.bin` (`Global.JS5_1_FILE` L20) **iff** `mIsNewest`
   - anything else is silently ignored. Supports multi-select (`ALLOW_MULTIPLE`, loop L115–131).

**B. Parameter-tab "BMS Firmware Update"** (`SVM.update` L248–257):
- Requires only a live link; calls `new UpdateActivity().setBT(gatt, connector)` → the 2-arg
  overload sets `mIsMainAct = false, mIsNewest = false` (UpdateActivity L40–42).
- **No `332211` prompt** (it's already behind the settings-tab password `JS20230801`).
- **No filename lock**: with `mIsMainAct == false`, `onActivityResult` L148–158 takes whatever single
  file the user picked and calls `setFile` directly. So from service mode you can flash **any** `.bin`,
  bypassing both the version check and the name lock. (Correction/extension to baseline.)

### Update send sequence (UI side)
- `UpdateViewModel.setBinding` calls `iBluzDevice.setMtu(512)` (L42) on entry.
- `send()` (L88–98) sets updating flag, shows progress bar, calls `BM.update(ctx, file, listener)`
  (BM L173): `startPull()`, caches file path in `update_file_path` (BM L177), then `beginUpdate()`
  → `CMD_BEGIN_UPDATE` `EB 90 00 07 BB 03 40` (BM L183) with a 20 s handshake timeout.
- Progress/success/fail via `OnUpdateListener` (UVM L101–162). Success → toast + release connector +
  `endUpdate()` (`CMD_UPDATE_END`, BM L188) + finish after 1 s. Back button / onStop also call
  `endUpdate()`. The chunk-transfer wire detail is the byte agent's scope.

---

## 5. SharedPreferences keys (`sp/SpManager.java`) — full inventory

All under group/file `SP_PATH = "battery_path"` (SpManager L19), accessed via
`com.actions.utils.spUtil.SPUtil`.

| Constant | Key string | Meaning | Written by | Read by |
|---|---|---|---|---|
| `SP_DEVICE_` | `device_` + i (0..3) | saved device names (max 4) | `MM.insertSelectDevice` L86, `SpManager.renewDeviceList` L27 | `MM.initSelectList` L73, `MM.getSearchList` L235 |
| `SP_MTU` | `sphere_mtu` | negotiated MTU (capped 200), default 20 | `MM.initDevice` getMtu L162 | `MM.initManager` L401 (sendMtu) |
| `SP_CONNECT_BT_PASSWORD` | `connect_password` | connect-prompt pwd, default `JS2023` | **never written** (dead) | `MVM.clickOk` L532 |
| `SP_SETFRAGMENT_PASSWORD` | `fragment_password` | settings-tab pwd, default `JS20230801` | `ResetDialog` L132 | `BVM` L106, `ResetDialog` L49 |
| `SP_MOS` | `setting_mos` | last charge+discharge MOS state | STATUS parse `BM` L538; `SVM.swMos` L145; `DModel.getMosStatus` L157 | gate setters (BM L140,149,154,159); `SVM.initView` L141; `DModel.getMosStatus` L25 |
| `SP_SLEEP_MODE` | `setting_sleep_mode` | last sleep toggle state | `SVM.swSleep` L153 | `SVM.initView` L149 |
| `SP_HEAT_GATE` | `heat_gate` | heater gate (int 0/1) | STATUS parse `BM` L541; `BM.setHeat` L160 | gate setters (BM L141,150,155,165); `SVM.initView` L157 |
| `SP_PASSIVA` | `setting_passiva` | passive-balance state | `SVM.swPassive` L168; `DModel.getBalancerStatus` L167 | gate setters (BM L141,150,161,165); `SVM.initView` L164; `DModel.getBalStatus` L29 |
| `SP_TEMCONTORL_GATE` | `temcontorl_gate` | temp-control gate (int) | STATUS parse `BM` L539 | gate setters (BM L141,150,155,161,165) |
| `SP_SMOKE_GATE` | `smoke_gate` | smoke gate (int) | STATUS parse `BM` L540 | gate setters (BM L141,150,155,161,165) |
| `SP_BATTERY_CAP` | `sp_setting_battery_capacity` | rated capacity Ah string, default `100` | `SModel.saveBatteryCap` L113 | `SModel.getBattery` L102; `SetBatteryDialog` L58 |
| `SP_TEMP_TYPE` | `setting_temp_type` | temp unit: true=°C, false=°F, default true | `SModel.saveTempStatus` L110 | `SModel.getTempStatus` L106; `DModel.getTemperature` L86 |
| `SP_UPDATE_FILE_PATH` | `update_file_path` | last OTA file abs path | `BM.update` L177 | `BM` L938 (OTA resend seek) |
| `SP_BLE_NAME` | `setting_bluetooth_name` | (BLE rename) | **never read or written** (dead) | — |

**Why the gate cache matters (task item 5):** every `CMD_GATE_CONTROL` setter re-sends the whole
8-byte payload and fills the fields it isn't changing from the SP cache:
`setMos` (BM L164), `setHeat` (L158), `setPassiva` (L153), `setRestart` (L139), `setFactory` (L148).
Payload layout (payload bytes p0..p7 between begin `C3 1E` and end `D4 3B`):
p0 charge-MOS, p1 discharge-MOS, p2 `temcontorl_gate`, p3 `smoke_gate`, p4 `heat_gate`, p5 restart,
p6 `setting_passiva`, p7 factory. The cache is repopulated from the STATUS frame `CMD_BAL_STATUS`
(BM L530–548: writes `setting_mos` L538, `temcontorl_gate` L539, `smoke_gate` L540, `heat_gate` L541).
So if a setter runs before a fresh STATUS frame has arrived, it can re-assert a **stale** gate value
(e.g. flip smoke/temp/heat) as a side effect of toggling MOS. `setPassiva` and `setMos` write p7=0 /
p5=0, so they never trip restart/factory; only the dedicated setters do.

---

## 6. Dead code, stubs, bugs (UI layer)

- `DialViewModel.more(View)` — empty body (DVM L65–66); `cl_more` forced invisible (L113). Dead.
- `MainViewModel.test1(View)` — empty body (MVM L71–72), bound to a view via `ActivityMainBindingImpl`
  L190 (`this.value.test1(view)`). Dead onClick.
- `PasswordDialog` `iv_reset` onClick — empty (dialog L139–143). Dead.
- History commands `getHistory` / `setHistoryStatus` / `cleanAllHistory` (BM L200–224) — no UI caller.
  Dead in this build. (`setHistoryStatus` loop bound `i3 < list.size()*2` also looks off-by-one, but
  it's unreachable.)
- `SP_BLE_NAME` and `SP_CONNECT_BT_PASSWORD` — declared but effectively unused (never written; the
  BLE-rename UI is absent in this build).
- `Global.IS_INSIDE = true` (L15) and `IS_DEBUG = false` (L14) — referenced nowhere (dead flags).
- `MM.getVersion` listener (L390–397) has **no else branch**: an unrecognised BMS version string
  makes the main-screen "update" button silently do nothing (no toast, no dialog).
- `Utils.getCurTime()` (L54–65) creates `new Time("GNT+8")` — a **typo** for "GMT+8"; Android's
  `Time` will treat the bad id as UTC. `setTime()` (BM L191) that consumes it is itself not called
  from any UI path in this build (no "set time" control).
- `PasswordDialog.onCreate` L63 logs `this.mPwd` before it's guaranteed set — benign (may log null).

---

## 7. Other unauthenticated write path — GuideActivity ("info" screen)

Not hidden and worth flagging. The main screen has a normal info button bound to `MVM.getInfo`
(MVM L456–467, `ActivityMainBindingImpl` L207) that opens `GuideActivity` (passing the live GATT +
cap). `GuideViewModel`:
- `restart(View)` (L90–95) → `BM.setRestart()` — **BMS restart with no password and no confirmation
  dialog**, straight from the info screen.
- `capacity(View)` (L97–137) → dropdown 50..300 → `BM.setBattery(str)` (`CMD_BATTERY`) — sets rated
  capacity, again **no password**.
So rated-capacity change and BMS restart are reachable without entering service mode or any password,
in addition to the Parameter-tab copies. (The `mTimeOut` runnable there, L38–47, is an empty stub.)

---

## 8. UI → BLE command quick map (consolidated)

| UI action | Screen | BM method | Command |
|---|---|---|---|
| Connect to saved device | Main list | (iBluz connect + `MM.initManager`) | handshake: `CMD_BEGIN`, `CMD_GET_EST`, `setLowTemProtect`, later `sendMtu` |
| MOS toggle | Param / (status readback) | `setMos` | `CMD_GATE_CONTROL` |
| Sleep toggle | Param | `setSleepMode` | `CMD_OPEN/CLOSE_SLEEP_CONTROL` |
| Heat toggle | Param | `setHeat` | `CMD_GATE_CONTROL` |
| Passive toggle | Param | `setPassiva` | `CMD_GATE_CONTROL` |
| Restart BMS | Param **or** Guide | `setRestart` | `CMD_GATE_CONTROL` (restart byte) |
| Factory reset | Param | `setFactory` | `CMD_GATE_CONTROL` (factory byte) |
| Set capacity | Param **or** Guide | `setBattery` | `CMD_BATTERY` |
| Temp unit switch | Param | (local pref only) | — |
| Read BMS version | Param / update precheck | `getVersion` | `CMD_GET_VERSION` (`AT+V`) |
| Firmware update | Main (locked) / Param (unlocked) | `update`→`beginUpdate`… | `CMD_BEGIN_UPDATE` … `CMD_UPDATE_END` |
| (never invoked) | — | `getHistory`/`cleanAllHistory`/`setHistoryStatus`/`setTime` | history + set-time cmds (dead) |
