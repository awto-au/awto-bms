import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

import 'battery_charts.dart';
import 'battery_connection.dart';
import 'battery_log.dart';
import 'battery_manager.dart';
import 'battery_protocol.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // sqflite ships no desktop implementation, so on Windows/Linux/macOS swap in
  // the FFI factory (WinRT-safe, uses the bundled SQLite) before the interval
  // store opens. Mobile keeps the default sqflite factory untouched. The DB
  // filename and schema are identical either way (see battery_log.dart).
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  // Open the on-device time-series store up front (idempotent; disables itself
  // silently if SQLite is unavailable).
  await BatteryLogger.instance.init();
  runApp(const BatteryReaderApp());
}

// Shared palette (green charging / red discharging / neutral idle).
const kGreen = Color(0xFF2FBF71);
const kRed = Color(0xFFE5484D);
const kIdle = Color(0xFF8895A7);
const kTrack = Color(0xFF222A35);

/// Resolve an effective charge state, filling `unknown` from the flags.
ChargeState effState(BatteryState s) {
  final cs = s.chargeState;
  if (cs != ChargeState.unknown) return cs;
  if (s.chargerConnected == true) return ChargeState.charging;
  if ((s.packCurrent ?? 0) > 0 && s.loadConnected == true) {
    return ChargeState.discharging;
  }
  return ChargeState.idle;
}

(Color, String, String) stateStyle(ChargeState cs) => switch (cs) {
      ChargeState.charging => (kGreen, 'Charging', 'in'),
      ChargeState.discharging => (kRed, 'Discharging', 'out'),
      _ => (kIdle, 'Idle · no load', ''),
    };

// Formatting helpers.
String fPct(int? v) => v == null ? '—' : '$v%';
String fV(double? v) => v == null ? '—' : '${v.toStringAsFixed(2)} V';
String fA(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)} A';
String fAh(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)} Ah';
String fW(double? v) => v == null ? '—' : '${v.toStringAsFixed(0)} W';
String fDeg(int? v) => v == null ? '—' : '$v °C';
String fBool(bool? v) => v == null ? '—' : (v ? 'On' : 'Off');
String fTime(int? s) => s == null ? '—' : secondsToHms(s);
String fState(ChargeState c) => switch (c) {
      ChargeState.idle => 'Idle',
      ChargeState.charging => 'Charging',
      ChargeState.discharging => 'Discharging',
      ChargeState.unknown => '—',
    };
String fRssi(int? v) => v == null ? '—' : '$v dBm';

// Signal-strength icon graded by RSSI (dBm). Higher (closer to 0) is stronger.
IconData rssiIcon(int? v) {
  if (v == null) return Icons.signal_cellular_off;
  if (v >= -60) return Icons.network_cell;
  if (v >= -75) return Icons.signal_cellular_alt;
  if (v >= -88) return Icons.signal_cellular_alt_2_bar;
  return Icons.signal_cellular_alt_1_bar;
}

Color rssiColor(int? v) {
  if (v == null) return Colors.white38;
  if (v >= -65) return kGreen;
  if (v >= -80) return Colors.amber;
  return kRed;
}

/// Small signal-strength chip: an icon graded by RSSI plus the dBm value.
class SignalChip extends StatelessWidget {
  final int? rssi;
  const SignalChip(this.rssi, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = rssiColor(rssi);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(rssiIcon(rssi), size: 16, color: c),
        const SizedBox(width: 3),
        Text(fRssi(rssi), style: TextStyle(fontSize: 12, color: c)),
      ],
    );
  }
}

class BatteryReaderApp extends StatelessWidget {
  const BatteryReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Battery Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.teal,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const BatteryListPage(),
    );
  }
}

// ===========================================================================
// List screen: top half = per-battery bars, bottom half = fleet total.
// ===========================================================================

class BatteryListPage extends StatefulWidget {
  const BatteryListPage({super.key});
  @override
  State<BatteryListPage> createState() => _BatteryListPageState();
}

class _BatteryListPageState extends State<BatteryListPage>
    with WidgetsBindingObserver {
  final _manager = BatteryManager();
  Timer? _ticker;

  /// Live vs. demo. Defaults to live so a real device reads real batteries;
  /// flip the app-bar switch to Demo for the synthetic fleet with no hardware.
  bool _live = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startLive();
    _ticker = Timer.periodic(
        const Duration(milliseconds: 300), (_) => setState(() {}));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Flush open intervals' end_ms to SQLite when the app leaves the foreground.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      BatteryLogger.instance.flushAll();
    }
  }

  void _startLive() {
    _live = true;
    // Fire-and-forget: scanning/connecting is async; the ticker repaints as
    // batteries appear.
    _manager.startLive();
  }

  void _setMode(bool live) {
    if (live == _live) return;
    setState(() {
      if (live) {
        _startLive();
      } else {
        _live = false;
        _manager.startDemoFleet();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    BatteryLogger.instance.flushAll();
    _ticker?.cancel();
    _manager.stopLive();
    _manager.disposeAll();
    super.dispose();
  }

  void _openDetail(BatteryConnection conn) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => BatteryDetailPage(conn: conn)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final batteries = _manager.batteries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Batteries'),
        actions: [
          // Live / Demo toggle. Live scans BLE; Demo seeds the synthetic fleet.
          Row(
            children: [
              Text(_live ? 'Live' : 'Demo',
                  style: const TextStyle(fontSize: 13)),
              Switch(
                value: _live,
                onChanged: _setMode,
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
              // Top half: the list of batteries.
              Expanded(
                child: batteries.isEmpty
                    ? Center(
                        child: Text(_live
                            ? 'Scanning for batteries…'
                            : 'No batteries'))
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                        children: [
                          for (final b in batteries)
                            _SummaryCard(
                              conn: b,
                              onTap: () => _openDetail(b),
                              onToggleFav: () =>
                                  setState(() => b.favourite = !b.favourite),
                            ),
                        ],
                      ),
              ),
              const Divider(height: 1),
              // Bottom half: combined total across favourited batteries.
              Expanded(child: _FleetTotal(manager: _manager)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One row in the list: serial, a compact SOC bar with figures, a favourite
/// star, tappable to open the detail page.
class _SummaryCard extends StatelessWidget {
  final BatteryConnection conn;
  final VoidCallback onTap;
  final VoidCallback onToggleFav;
  const _SummaryCard({
    required this.conn,
    required this.onTap,
    required this.onToggleFav,
  });

  @override
  Widget build(BuildContext context) {
    final s = conn.state;
    final (color, _, dir) = stateStyle(effState(s));
    final soc = s.socPercent;
    final frac = ((soc ?? 0) / 100).clamp(0.0, 1.0);
    final figures = '${fV(s.packVoltage)}   '
        '${s.packCurrent == null ? '—' : '${s.packCurrent!.toStringAsFixed(1)} A'
            '${dir.isEmpty ? '' : ' $dir'}'}';
    const shadow = [Shadow(color: Colors.black54, blurRadius: 3)];

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${conn.profile.name}   •   ${s.serial ?? '—'}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  SignalChip(s.rssi),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: conn.favourite
                        ? 'In fleet total'
                        : 'Add to fleet total',
                    icon: Icon(
                      conn.favourite ? Icons.star : Icons.star_border,
                      color: conn.favourite ? Colors.amber : Colors.white38,
                    ),
                    onPressed: onToggleFav,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  height: 44,
                  color: kTrack,
                  child: Stack(
                    children: [
                      FractionallySizedBox(
                        widthFactor: frac,
                        alignment: Alignment.centerLeft,
                        child: Container(color: color),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Text(
                              fPct(soc),
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                                shadows: shadow,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              figures,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                                shadows: shadow,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bottom panel: one combined gauge + totals across favourited batteries.
class _FleetTotal extends StatelessWidget {
  final BatteryManager manager;
  const _FleetTotal({required this.manager});

  @override
  Widget build(BuildContext context) {
    final favs = manager.favourites;
    final soc = manager.combinedSocPercent;
    final frac = ((soc ?? 0) / 100).clamp(0.0, 1.0);
    final (color, label, _) = stateStyle(manager.fleetState);
    final net = manager.netPowerW;
    final netText = net == 0
        ? '0 W'
        : '${net.abs().toStringAsFixed(0)} W ${net > 0 ? 'in' : 'out'}';
    const shadow = [Shadow(color: Colors.black54, blurRadius: 3)];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.dashboard_customize_outlined, size: 18),
              const SizedBox(width: 8),
              Text('Fleet total · ${favs.length} batteries',
                  style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              height: 84,
              color: kTrack,
              child: Stack(
                children: [
                  FractionallySizedBox(
                    widthFactor: frac,
                    alignment: Alignment.centerLeft,
                    child: Container(color: color),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: Row(
                      children: [
                        Text(
                          soc == null ? '—' : '$soc%',
                          style: const TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            shadows: shadow,
                          ),
                        ),
                        const Spacer(),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(netText,
                                style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                    shadows: shadow)),
                            Text('${manager.netCurrentA.abs().toStringAsFixed(1)} A',
                                style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.white,
                                    shadows: shadow)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _kv('Status', label),
          _kv('Total capacity', fAh(manager.totalCapacityAh)),
          _kv('Remaining', fAh(manager.totalRemainingAh)),
          _kv('Net current', '${manager.netCurrentA.toStringAsFixed(1)} A'),
          _fleetSignalRow(favs),
        ],
      ),
    );
  }
}

// ===========================================================================
// Detail screen: the full single-battery view.
// ===========================================================================

class BatteryDetailPage extends StatefulWidget {
  final BatteryConnection conn;
  const BatteryDetailPage({super.key, required this.conn});
  @override
  State<BatteryDetailPage> createState() => _BatteryDetailPageState();
}

class _BatteryDetailPageState extends State<BatteryDetailPage> {
  StreamSubscription<BatteryEvent>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.conn.events.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel(); // note: does not dispose the connection (owned by manager)
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.conn.state;
    return Scaffold(
      appBar: AppBar(
        title: Text(s.serial ?? 'Battery'),
        actions: [
          if (s.serial != null)
            IconButton(
              tooltip: 'Charts / history',
              icon: const Icon(Icons.show_chart),
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => BatteryChartsPage(serial: s.serial!),
                ),
              ),
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _BatteryGauge(state: s, profile: widget.conn.profile),
              const SizedBox(height: 12),
              _Section('Pack', [
                _kv('State of charge', fPct(s.socPercent)),
                _kv('Pack voltage', fV(s.packVoltage)),
                _kv('Pack current', fA(s.packCurrent)),
                _kv('Power', fW(s.power)),
                _kv('Charge state', fState(s.chargeState)),
                _kv('Load connected', fBool(s.loadConnected)),
                _kv('Charger connected', fBool(s.chargerConnected)),
                _kv('Cycles', s.cycleCount?.toString() ?? '—'),
              ]),
              _Section('Capacity', [
                _kv('Remaining', fAh(s.remainingAh)),
                _kv('Full / rated', fAh(s.fullAh)),
                _kv('Time to full', fTime(s.timeToFullSec)),
                _kv('Time to empty', fTime(s.timeToEmptySec)),
              ]),
              _Section('Cells', [
                if (s.cellsMv.isEmpty)
                  const Text('—', style: TextStyle(color: Colors.white70))
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        for (final mv in s.cellsMv)
                          Text('${(mv / 1000).toStringAsFixed(3)} V',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                const Divider(height: 20),
                _kv('Sum of cells', fV(s.cellSum)),
                _kv('Average', fV(s.cellAvg)),
                _kv('Max', fV(s.cellMax)),
                _kv('Min', fV(s.cellMin)),
                _kv('Delta', fV(s.cellDiff)),
              ]),
              _Section('Temperature', [
                _kv('Sensor 1', fDeg(s.temp1)),
                _kv('Sensor 2', fDeg(s.temp2)),
                _kv('Chip', fDeg(s.chipTemperature)),
              ]),
              _Section('Gates & status', [
                _kv('MOS', fBool(s.mosOn)),
                _kv('Charge MOS', fBool(s.chargeMos)),
                _kv('Discharge MOS', fBool(s.dischargeMos)),
                _kv('Passive balancing', fBool(s.passiveBalancing)),
                _kv('Temp-control gate', s.tempControlGate?.toString() ?? '—'),
                _kv('Smoke gate', s.smokeGate?.toString() ?? '—'),
                _kv('Heater gate', s.heatGate?.toString() ?? '—'),
                _kv('Firmware', s.firmwareVersion ?? '—'),
                _kv('Signal (RSSI)', fRssi(s.rssi)),
              ]),
              _Warnings('Current alarms', s.currentWarnings),
              _Warnings('Voltage alarms', s.voltageWarnings),
              _Warnings('Temperature alarms', s.temperatureWarnings),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fleet signal row: shows the weakest link (limiting) signal across favourites.
Widget _fleetSignalRow(List<BatteryConnection> favs) {
  final rssis = favs
      .map((b) => b.state.rssi)
      .whereType<int>()
      .toList()
    ..sort();
  final weakest = rssis.isEmpty ? null : rssis.first;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text('Signal (weakest)',
            style: TextStyle(color: Colors.white70)),
        SignalChip(weakest),
      ],
    ),
  );
}

/// Key/value row used across sections and the fleet panel.
Widget _kv(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(k, style: const TextStyle(color: Colors.white70)),
          Text(v, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );

/// Header (model / serial / capacity) plus a horizontal SOC bar with the live
/// figures overlaid. Fill colour signals power flow.
class _BatteryGauge extends StatelessWidget {
  final BatteryState state;
  final DeviceProfile profile;
  const _BatteryGauge({required this.state, required this.profile});

  @override
  Widget build(BuildContext context) {
    final (color, label, dir) = stateStyle(effState(state));
    final soc = state.socPercent;
    final frac = ((soc ?? 0) / 100).clamp(0.0, 1.0);
    final cap = state.fullAh;
    final curText = state.packCurrent == null
        ? '—'
        : '${state.packCurrent!.toStringAsFixed(1)} A${dir.isEmpty ? '' : ' $dir'}';
    final pwrText = state.power == null
        ? '—'
        : '${state.power!.toStringAsFixed(0)} W${dir.isEmpty ? '' : ' $dir'}';
    const shadow = [Shadow(color: Colors.black54, blurRadius: 3)];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${profile.name}   •   ${state.serial ?? '—'}',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, letterSpacing: 0.2),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(cap == null ? '— Ah' : '${cap.toStringAsFixed(0)} Ah',
                    style: const TextStyle(color: Colors.white70)),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Container(
                height: 92,
                color: kTrack,
                child: Stack(
                  children: [
                    FractionallySizedBox(
                      widthFactor: frac,
                      alignment: Alignment.centerLeft,
                      child: Container(color: color),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                      child: Row(
                        children: [
                          Text(
                            soc == null ? '—' : '$soc%',
                            style: const TextStyle(
                              fontSize: 40,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              shadows: shadow,
                            ),
                          ),
                          const Spacer(),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(fV(state.packVoltage),
                                  style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                      shadows: shadow)),
                              const SizedBox(height: 2),
                              Text(curText,
                                  style: const TextStyle(
                                      fontSize: 15,
                                      color: Colors.white,
                                      shadows: shadow)),
                              Text(pwrText,
                                  style: const TextStyle(
                                      fontSize: 15,
                                      color: Colors.white,
                                      shadows: shadow)),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration:
                      BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(label,
                    style:
                        TextStyle(color: color, fontWeight: FontWeight.w600)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> rows;
  const _Section(this.title, this.rows);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            ...rows,
          ],
        ),
      ),
    );
  }
}

class _Warnings extends StatelessWidget {
  final String title;
  final List<String> items;
  const _Warnings(this.title, this.items);

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Card(
      color: Colors.red.shade900,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const Divider(),
            for (final w in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  const Icon(Icons.warning_amber, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: Text(w)),
                ]),
              ),
          ],
        ),
      ),
    );
  }
}
