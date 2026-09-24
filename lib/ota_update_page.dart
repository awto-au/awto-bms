/// Firmware update UI (#41): pick file -> pre-flight checklist -> typed
/// serial confirmation (which carries the risk line; there is no separate
/// warning step, #118) -> progress (no back navigation, Abort only before
/// the first chunk) -> result.
///
/// Every gate and every refusal is data from ota_update.dart; this file only
/// renders it and drives [BatteryConnection.runFirmwareUpdate]. No frame is
/// built here.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'battery_connection.dart';
import 'diagnostics.dart';
import 'health_palette.dart';
import 'ota_update.dart';
import 'write_actions.dart' show BusyWrites, serialOf, showToast;

const _red = HealthPalette.faultRed;
const _green = HealthPalette.healthy;

/// The busy key held in the detail page's [BusyWrites] for the whole flash.
const String otaBusyKey = 'firmware update';

enum _Step { pick, preflight, confirm, running, result }

class FirmwareUpdatePage extends StatefulWidget {
  final BatteryConnection conn;

  /// The detail page's in-flight flags: held for the whole update so every
  /// other write button on that battery is disabled.
  final BusyWrites busy;

  /// Android: is the foreground service (wake lock) running? Other
  /// platforms pass a constant.
  final bool Function() keepAwake;
  final String Function() keepAwakeDetail;

  /// Tests only: replaces the platform file picker (null = cancelled).
  @visibleForTesting
  final Future<OtaImage?> Function()? pickImage;
  const FirmwareUpdatePage({
    super.key,
    required this.conn,
    required this.busy,
    required this.keepAwake,
    required this.keepAwakeDetail,
    this.pickImage,
  });

  @override
  State<FirmwareUpdatePage> createState() => _FirmwareUpdatePageState();
}

class _FirmwareUpdatePageState extends State<FirmwareUpdatePage> {
  _Step _step = _Step.pick;
  OtaImage? _image;
  String? _pickError;
  bool _picking = false;
  List<OtaGate> _gates = const [];
  Timer? _refresh;
  final _typed = TextEditingController();
  OtaSession? _session;
  StreamSubscription<OtaProgress>? _progressSub;
  OtaResult? _result;
  String? _startError;

  BatteryConnection get conn => widget.conn;
  String get _serial => serialOf(conn);

  @override
  void initState() {
    super.initState();
    // The checklist reflects the live pack: SOC, streaming, current change.
    _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_step == _Step.preflight || _step == _Step.confirm) {
        setState(_recheck);
      }
    });
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _progressSub?.cancel();
    _typed.dispose();
    super.dispose();
  }

  // --- gates ---------------------------------------------------------------

  OtaPreflightInput _input() {
    final s = conn.state;
    final silence = conn.silenceMs;
    return OtaPreflightInput(
      connected: conn.connState == ConnState.connected,
      streaming: conn.connState == ConnState.connected &&
          conn.lastTelemetryMs != null &&
          !conn.notStreaming,
      streamingDetail: conn.connState != ConnState.connected
          ? 'Not connected'
          : conn.lastTelemetryMs == null
              ? 'No telemetry received on this connection yet'
              : 'No telemetry for ${((silence ?? 0) / 1000).round()} s',
      soc: s.socPercent,
      activeFault: conn.hasGenuineFault,
      faultDetail: conn.hasGenuineFault
          ? [
              ...s.currentWarnings,
              ...s.voltageWarnings,
              ...s.temperatureWarnings,
            ].join(', ')
          : '',
      chargeState: s.chargeState,
      currentA: s.packCurrent,
      keepAwake: widget.keepAwake(),
      keepAwakeDetail: widget.keepAwakeDetail(),
      image: _image,
      firmwareVersion: s.firmwareVersion,
      otherWriteInFlight: OtaLock.inProgress ||
          widget.busy.any && !widget.busy.contains(otaBusyKey),
    );
  }

  void _recheck() => _gates = otaPreflight(_input());

  bool get _allPass => otaPreflightPasses(_gates);

  // --- pick ----------------------------------------------------------------

  Future<void> _pick() async {
    if (_picking) return;
    setState(() {
      _picking = true;
      _pickError = null;
    });
    try {
      final image = await (widget.pickImage ?? _pickFromDisk)();
      if (image == null) return; // cancelled
      AppLog.instance.record('OTA $_serial',
          'file chosen: ${image.name}, ${image.size} B, sha256 ${image.sha256Hex}');
      if (!mounted) return;
      setState(() => _image = image);
    } catch (e) {
      AppLog.instance.record('OTA $_serial', 'file pick failed: $e');
      if (mounted) setState(() => _pickError = '$e');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<OtaImage?> _pickFromDisk() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: 'Choose the BMS firmware image (.bin)',
      type: FileType.custom,
      allowedExtensions: const ['bin'],
    );
    if (files.isEmpty) return null;
    final f = files.first;
    return OtaImage(name: f.name, bytes: await f.readAsBytes());
  }

  // --- start ---------------------------------------------------------------

  Future<void> _start() async {
    final image = _image;
    if (image == null) return;
    // The typed confirmation is re-checked here (never trusted from the
    // button's enabled state alone), and the gates are re-run at the moment
    // of starting — a pack that started charging since the checklist page
    // is refused.
    if (!otaConfirmationMatches(_typed.text, conn.state.serial)) {
      setState(() => _startError =
          'The serial you typed does not match $_serial — not started.');
      AppLog.instance
          .record('OTA $_serial', 'refused: typed confirmation mismatch');
      return;
    }
    _recheck();
    if (!_allPass) {
      final why = otaPreflightRefusal(_gates);
      setState(() {
        _step = _Step.preflight;
        _startError = 'Pre-flight failed at the last moment: $why';
      });
      AppLog.instance.record('OTA $_serial', 'refused at start: $why');
      return;
    }
    setState(() {
      _startError = null;
      _step = _Step.running;
      _result = null;
    });
    await widget.busy.run(otaBusyKey, () {
      if (mounted) setState(() {});
    }, () async {
      try {
        final result = await _run(image);
        if (mounted) {
          setState(() {
            _result = result;
            _step = _Step.result;
          });
        }
      } catch (e) {
        AppLog.instance.record('OTA $_serial', 'not started: $e');
        if (mounted) {
          setState(() {
            _startError = 'Not started: $e';
            _step = _Step.confirm;
          });
        }
      }
    });
  }

  Future<OtaResult> _run(OtaImage image) async {
    final future = conn.runFirmwareUpdate(image);
    // The session is attached synchronously inside runFirmwareUpdate.
    final session = conn.otaSession;
    if (session != null) {
      _session = session;
      _progressSub = session.progressStream.listen((_) {
        if (mounted) setState(() {});
      });
    }
    return future;
  }

  Future<void> _abort() async {
    final s = _session;
    if (s == null) return;
    final ok = await s.abort();
    if (!ok && mounted) {
      showToast(context, 'Too late to abort — firmware data has been sent');
    }
  }

  /// Leaving after a failure sends CMD_UPDATE_END, as the vendor's Back /
  /// onStop does (UVM:45-58).
  Future<void> _leave() async {
    final s = _session;
    if (s != null && !s.endSent && !s.inProgress) {
      await s.sendEnd();
    }
    if (mounted) Navigator.of(context).pop();
  }

  // --- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final running = _step == _Step.running;
    return PopScope(
      // No back navigation while the flash runs (hardware back / gesture).
      canPop: !running,
      child: Scaffold(
        appBar: AppBar(
          title: Text('Firmware update — $_serial',
              overflow: TextOverflow.ellipsis),
          automaticallyImplyLeading: !running,
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _stepper(),
                  const SizedBox(height: 12),
                  switch (_step) {
                    _Step.pick => _pickCard(),
                    _Step.preflight => _preflightCard(),
                    _Step.confirm => _confirmCard(),
                    _Step.running => _runningCard(),
                    _Step.result => _resultCard(),
                  },
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _stepper() {
    const names = ['File', 'Checks', 'Confirm', 'Flash', 'Result'];
    final idx = _Step.values.indexOf(_step);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (var i = 0; i < names.length; i++)
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text(names[i], style: const TextStyle(fontSize: 12)),
            backgroundColor: i == idx
                ? Theme.of(context).colorScheme.primaryContainer
                : i < idx
                    ? _green.withValues(alpha: 0.25)
                    : null,
          ),
      ],
    );
  }

  Widget _card(String title, List<Widget> children) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const Divider(),
              ...children,
            ],
          ),
        ),
      );

  Widget _kv(String k, String v, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
                width: 130,
                child: Text(k,
                    style: const TextStyle(color: Colors.white70, fontSize: 13))),
            Expanded(
                child: SelectableText(v,
                    style: TextStyle(fontSize: 13, color: color))),
          ],
        ),
      );

  Widget _pickCard() {
    final img = _image;
    final version = conn.state.firmwareVersion;
    final warn = img == null ? null : otaFilenameWarning(img.name, version);
    return _card('1. Firmware file', [
      _kv('Battery', _serial),
      _kv('Current firmware', version ?? 'unknown (not reported yet)'),
      _kv('Connection',
          conn.connState == ConnState.connected ? 'connected' : conn.connState.name),
      const SizedBox(height: 8),
      const Text(
        'The app carries no firmware. Choose the .bin image supplied by the '
        'battery vendor / dealer for THIS BMS family. It is streamed to the '
        'BMS exactly as the vendor app does; nothing is checked inside it.',
        style: TextStyle(fontSize: 13, color: Colors.white70),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _picking ? null : _pick,
        icon: const Icon(Icons.folder_open),
        label: Text(img == null ? 'Choose .bin file' : 'Choose a different file'),
      ),
      if (_pickError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Could not read the file: $_pickError',
              style: const TextStyle(color: _red, fontSize: 13)),
        ),
      if (img != null) ...[
        const Divider(height: 24),
        _kv('File', img.name),
        _kv('Size', '${img.size} bytes'),
        _kv('SHA-256', img.sha256Hex),
        if (img.size == 0)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('This file is empty and cannot be flashed.',
                style: TextStyle(color: _red, fontSize: 13)),
          ),
        if (warn != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber, color: Colors.amber, size: 18),
                const SizedBox(width: 8),
                Expanded(
                    child: Text(warn,
                        style: const TextStyle(
                            color: Colors.amber, fontSize: 13))),
              ],
            ),
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: img.size == 0
              ? null
              : () => setState(() {
                    _recheck();
                    _step = _Step.preflight;
                  }),
          child: const Text('Continue to pre-flight checks'),
        ),
      ],
    ]);
  }

  Widget _preflightCard() {
    if (_gates.isEmpty) _recheck();
    return _card('2. Pre-flight checks (all must pass)', [
      for (final g in _gates)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(g.ok ? Icons.check_circle : Icons.cancel,
                  color: g.ok ? _green : _red, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.name,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(g.detail,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white70)),
                  ],
                ),
              ),
            ],
          ),
        ),
      if (_startError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_startError!,
              style: const TextStyle(color: _red, fontSize: 13)),
        ),
      const SizedBox(height: 12),
      Row(
        children: [
          OutlinedButton(
            onPressed: () => setState(() => _step = _Step.pick),
            child: const Text('Back'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => setState(_recheck),
            child: const Text('Re-check'),
          ),
          const Spacer(),
          FilledButton(
            onPressed: _allPass
                ? () => setState(() {
                      _startError = null;
                      _step = _Step.confirm;
                    })
                : null,
            child: const Text('Continue'),
          ),
        ],
      ),
      if (!_allPass)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
              'Refused: every check must pass before the update can start.',
              style: TextStyle(color: _red, fontSize: 12)),
        ),
    ]);
  }

  String _estimate() {
    final img = _image;
    if (img == null) return '?';
    final mtu = OtaProtocol.effectiveMtu(conn.linkMtu);
    final n = img.chunkCount(mtu);
    // ~1 ack round-trip per chunk; BLE connection intervals put this in the
    // 50–150 ms range. A rough upper bound is fine for the hint.
    final secs = (n * 0.15).ceil();
    return secs < 90 ? '$secs s ($n chunks of ${OtaProtocol.payloadCap(mtu)} B)'
        : '${(secs / 60).ceil()} min ($n chunks of ${OtaProtocol.payloadCap(mtu)} B)';
  }

  Widget _confirmCard() {
    final matches = otaConfirmationMatches(_typed.text, conn.state.serial);
    return _card('3. Type the battery serial to confirm', [
      // #118: the one risk line (formerly its own warning step).
      const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.dangerous, color: _red, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text(otaSternWarning,
                style: TextStyle(color: _red, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      const SizedBox(height: 8),
      _kv('Battery', _serial),
      _kv('File', _image?.name ?? '?'),
      _kv('SHA-256', _image?.sha256Hex ?? '?'),
      _kv('Takes about', _estimate()),
      const SizedBox(height: 8),
      TextField(
        controller: _typed,
        autocorrect: false,
        enableSuggestions: false,
        textCapitalization: TextCapitalization.characters,
        decoration: InputDecoration(
          labelText: 'Type $_serial exactly',
          border: const OutlineInputBorder(),
          errorText: _typed.text.isNotEmpty && !matches
              ? 'Does not match $_serial'
              : null,
        ),
        onChanged: (_) => setState(() => _startError = null),
      ),
      if (_startError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_startError!,
              style: const TextStyle(color: _red, fontSize: 13)),
        ),
      if (!_allPass)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
              'A pre-flight check no longer passes — go back to the checks.',
              style: TextStyle(color: _red, fontSize: 12)),
        ),
      const SizedBox(height: 12),
      Row(
        children: [
          OutlinedButton(
            onPressed: () => setState(() => _step = _Step.preflight),
            child: const Text('Back'),
          ),
          const Spacer(),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _red),
            onPressed: matches && _allPass ? _start : null,
            child: const Text('Start firmware update'),
          ),
        ],
      ),
    ]);
  }

  Widget _runningCard() {
    final s = _session;
    final p = s?.progress;
    final pct = p?.percent ?? 0;
    return _card('4. Updating — do not leave this screen', [
      Text(p?.stage.text ?? 'Starting…',
          style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      // Linear progress only (no rings).
      LinearProgressIndicator(value: pct / 100, minHeight: 10),
      const SizedBox(height: 8),
      if (p != null) ...[
        _kv('Progress', '$pct %'),
        _kv('Chunks',
            '${p.ackedChunks} of ${p.chunkCount} acknowledged'
            '${p.stage == OtaStage.sending ? ' (sending ${p.chunkIndex + 1})' : ''}'),
        _kv('Bytes', '${p.ackedBytes} of ${p.totalBytes}'),
        if (p.attempt > 0)
          _kv('Resend', '${p.attempt} of ${OtaProtocol.maxResends}',
              color: Colors.amber),
        if (p.detail.isNotEmpty) _kv('Status', p.detail),
      ],
      const SizedBox(height: 12),
      if (s != null && s.canAbort)
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(foregroundColor: _red),
          onPressed: _abort,
          icon: const Icon(Icons.stop_circle_outlined),
          label: const Text('Abort (no firmware data sent yet)'),
        )
      else
        const Text(
          'Firmware data is being written. The update cannot be stopped now — '
          'interrupting it could disable the BMS.',
          style: TextStyle(color: Colors.amber, fontSize: 13),
        ),
    ]);
  }

  Widget _resultCard() {
    final r = _result;
    final s = _session;
    if (r == null) return _card('5. Result', const [Text('—')]);
    final ok = r.ok;
    final color = ok
        ? _green
        : r.stage == OtaStage.aborted
            ? Colors.amber
            : _red;
    return _card('5. Result', [
      Row(
        children: [
          Icon(
              ok
                  ? Icons.check_circle
                  : r.stage == OtaStage.aborted
                      ? Icons.stop_circle_outlined
                      : Icons.error,
              color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(r.stage.text,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.w700, fontSize: 16)),
          ),
        ],
      ),
      const SizedBox(height: 8),
      if (r.reason != null) _kv('Reason', r.reason!, color: _red),
      _kv('Failed at stage', r.stageAtEnd.text),
      _kv('Last acked chunk',
          r.lastAckedChunk == null ? 'none' : '${r.lastAckedChunk! + 1} of ${r.chunkCount}'),
      _kv('Frames sent', '${r.framesSent}'),
      _kv('END sent', r.endSent ? 'yes' : 'no'),
      if (ok)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'The BMS reported success. It may restart and drop the connection; '
            'the app reconnects on its own. Check the firmware version once it '
            'is streaming again.',
            style: TextStyle(fontSize: 13, color: Colors.white70),
          ),
        )
      else if (r.stage == OtaStage.failed)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'Do not power-cycle the battery yet. Leaving this screen sends the '
            'END command (as the vendor app does). The full frame-by-frame '
            'record is in Diagnostics and the raw log — share it before '
            'retrying.',
            style: TextStyle(fontSize: 13, color: Colors.amber),
          ),
        ),
      const SizedBox(height: 12),
      FilledButton(
        onPressed: _leave,
        child: Text(s != null && !s.endSent && !ok
            ? 'Send END and leave'
            : 'Done'),
      ),
    ]);
  }
}

/// Platform note for the "device will stay awake" gate.
String otaKeepAwakeDetail(bool serviceRunning) {
  if (!kIsWeb && Platform.isAndroid) {
    return serviceRunning
        ? 'Monitoring foreground service is running (wake lock held)'
        : 'The monitoring foreground service is not running — turn '
            'Background monitoring on (Settings) and resume monitoring so '
            'the service holds a wake lock during the flash';
  }
  return 'Desktop: make sure the PC will not sleep during the update';
}

/// Whether the gate passes on this platform.
bool otaKeepAwakeOk(bool serviceRunning) =>
    !kIsWeb && Platform.isAndroid ? serviceRunning : true;
