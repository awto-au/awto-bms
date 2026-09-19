/// Settings > Diagnostics (review pass C1): the recent [AppLog] entries — every
/// best-effort failure the app used to swallow silently — plus the health of
/// the two logs (interval store degraded? raw log size / rotation) and the
/// last scan error. The user can copy the entries to the clipboard to send
/// them along with the raw log.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'battery_log.dart';
import 'diagnostics.dart';
import 'raw_log.dart';

/// One-line summary for the Settings tile's subtitle: the DB-degraded warning
/// when logging is failing, else how many entries were recorded. Pure.
String diagnosticsSummary({
  required bool dbDegraded,
  String? lastDbError,
  required int entryCount,
  required int totalRecorded,
}) {
  if (dbDegraded) return 'Logging is failing: ${lastDbError ?? 'unknown error'}';
  if (totalRecorded == 0) return 'No problems recorded';
  final dropped = totalRecorded - entryCount;
  return '$entryCount recent ${entryCount == 1 ? 'entry' : 'entries'}'
      '${dropped > 0 ? ' ($dropped older dropped)' : ''}';
}

class DiagnosticsPage extends StatefulWidget {
  /// The manager's last scan error text (M13), if any.
  final String? scanError;
  const DiagnosticsPage({super.key, this.scanError});

  @override
  State<DiagnosticsPage> createState() => _DiagnosticsPageState();
}

class _DiagnosticsPageState extends State<DiagnosticsPage> {
  Future<void> _copy() async {
    final log = BatteryLogger.instance;
    final raw = RawLogger.instance;
    final header = [
      'Battery Reader diagnostics ${AppLogEntry.fmtStamp(DateTime.now())}',
      'interval store: ${log.enabled ? 'open' : 'closed'}'
          '${log.dbDegraded ? ' DEGRADED' : ''}'
          '${log.lastDbError != null ? ' last error: ${log.lastDbError}' : ''}',
      'raw log: ${raw.path ?? '(none)'} ${RawLogger.fmtSize(raw.sizeBytes)}'
          ' (${raw.enabled ? 'on' : 'off'}, rotations ${raw.rotations})',
      if (widget.scanError != null) 'scan: ${widget.scanError}',
      '',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: header + AppLog.instance.dump()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Diagnostics copied to clipboard')));
  }

  @override
  Widget build(BuildContext context) {
    final log = BatteryLogger.instance;
    final raw = RawLogger.instance;
    final entries = AppLog.instance.recent();
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy),
            onPressed: _copy,
          ),
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(AppLog.instance.clear),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                ListTile(
                  leading: Icon(
                    log.dbDegraded ? Icons.error_outline : Icons.storage,
                    color: log.dbDegraded ? scheme.error : null,
                  ),
                  title: const Text('Interval store (SQLite)'),
                  subtitle: Text(log.dbDegraded
                      ? 'Logging is failing: ${log.lastDbError ?? 'unknown'}'
                          ' — retrying automatically'
                      : log.enabled
                          ? 'Open and writing'
                          : 'Closed'
                              '${log.lastDbError != null ? ' — ${log.lastDbError}' : ''}'),
                ),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Raw log'),
                  subtitle: Text(
                      '${raw.enabled ? 'On' : 'Off'} · ${RawLogger.fmtSize(raw.sizeBytes)}'
                      ' of ${RawLogger.fmtSize(raw.maxBytes)} before rotation'
                      ' · rotated ${raw.rotations}x this session'),
                ),
                if (widget.scanError != null)
                  ListTile(
                    leading: Icon(Icons.bluetooth_disabled, color: scheme.error),
                    title: const Text('Bluetooth scan'),
                    subtitle: Text(widget.scanError!),
                  ),
                const Divider(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    'Recent events (${entries.length}, newest first)',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: scheme.primary, fontWeight: FontWeight.w700),
                  ),
                ),
                if (entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Nothing recorded — no best-effort operation '
                        'has failed since the app started.'),
                  ),
                for (final e in entries)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                    child: SelectableText.rich(
                      TextSpan(
                        style: const TextStyle(
                            fontSize: 11, fontFamily: 'monospace'),
                        children: [
                          TextSpan(
                            text: '${AppLogEntry.fmtStamp(e.time)}  ',
                            style: const TextStyle(color: Colors.white54),
                          ),
                          TextSpan(
                            text: '${e.source}  ',
                            style: TextStyle(
                                color: scheme.primary,
                                fontWeight: FontWeight.w600),
                          ),
                          TextSpan(text: e.message),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
