/// Real fonts for layout / screenshot tests (#100, #12). The default test
/// font draws every glyph as a full-em box, about twice Roboto's average
/// advance, so an overflow found under it may not exist on a device and a
/// PNG shows only boxes. [loadRealFonts] loads Roboto (Material's Android
/// font), the Material icons and a 'Segoe UI' (the Windows typography's
/// family: the system font when this machine has it, else Roboto) from the
/// Flutter SDK cache. Font loading is per test isolate, i.e. per test file.
library;

import 'dart:io';

import 'package:flutter/services.dart';

/// The Flutter SDK's cache directory (…/bin/cache), from FLUTTER_ROOT or by
/// walking up from the flutter_tester executable.
Directory? _flutterCache() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final d = Directory('$root/bin/cache');
    if (d.existsSync()) return d;
  }
  var d = File(Platform.resolvedExecutable).parent;
  while (d.parent.path != d.path) {
    if (d.uri.pathSegments.where((s) => s.isNotEmpty).last == 'cache') {
      return d;
    }
    d = d.parent;
  }
  return null;
}

Future<ByteData> _bytes(File f) async =>
    ByteData.view(Uint8List.fromList(await f.readAsBytes()).buffer);

Future<void> _loadFamily(String family, List<File> files) async {
  final loader = FontLoader(family);
  for (final f in files) {
    loader.addFont(_bytes(f));
  }
  await loader.load();
}

/// Whether Segoe UI came from the system (else Roboto stands in for it).
bool gRealSegoe = false;

/// Load Roboto (Material's font on Android), the Material icons and a font
/// for 'Segoe UI' (the Windows typography's family). Without these every
/// glyph renders as a full-em box and the widths mean nothing.
Future<void> loadRealFonts() async {
  final cache = _flutterCache();
  final dir = Directory('${cache?.path}/artifacts/material_fonts');
  if (cache == null || !dir.existsSync()) {
    throw StateError('material_fonts not found under the Flutter SDK cache '
        '(${cache?.path}); run `flutter precache`');
  }
  File mf(String n) => File('${dir.path}/$n');
  final roboto = [
    for (final n in const [
      'roboto-regular.ttf',
      'roboto-medium.ttf',
      'roboto-bold.ttf',
      'roboto-light.ttf',
      'roboto-italic.ttf',
    ])
      mf(n),
  ];
  await _loadFamily('Roboto', roboto);
  await _loadFamily('MaterialIcons', [mf('materialicons-regular.otf')]);
  final winFonts =
      Directory('${Platform.environment['WINDIR'] ?? r'C:\Windows'}'
          '/Fonts');
  final segoe = [
    for (final n in const ['segoeui.ttf', 'seguisb.ttf', 'segoeuib.ttf'])
      File('${winFonts.path}/$n'),
  ].where((f) => f.existsSync()).toList();
  gRealSegoe = segoe.isNotEmpty;
  await _loadFamily('Segoe UI', gRealSegoe ? segoe : roboto);
}
