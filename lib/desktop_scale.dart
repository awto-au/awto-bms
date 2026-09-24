/// Desktop type scale (#68 predecessor): the Windows/Linux/macOS app renders
/// the phone-sized type otherwise; this ONE factor shrinks every text in the
/// app by 25 % on a desktop host. Mobile (and web) are untouched. Applied
/// through the [MaterialApp.builder] as a [TextScaler] composed with the
/// platform's own.
library;

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

const double kDesktopTextScale = 0.75;

/// True on a desktop host (Windows / Linux / macOS, not web).
bool get isDesktopHost =>
    !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

/// The desktop text scaler: [base] (the platform's scaler, e.g. the Windows
/// "Text size" setting) multiplied by [kDesktopTextScale]. With no platform
/// scaling this is exactly `TextScaler.linear(kDesktopTextScale)`.
TextScaler desktopTextScaler(TextScaler base) =>
    TextScaler.linear(base.scale(1.0) * kDesktopTextScale);

/// [MaterialApp.builder] hook: on a desktop host, re-issue the MediaQuery to
/// the whole navigator tree with the composed [desktopTextScaler]; anywhere
/// else the tree is passed through untouched.
Widget desktopTextScaleBuilder(BuildContext context, Widget? child) {
  final content = child ?? const SizedBox.shrink();
  if (!isDesktopHost) return content;
  final mq = MediaQuery.of(context);
  return MediaQuery(
    data: mq.copyWith(textScaler: desktopTextScaler(mq.textScaler)),
    child: content,
  );
}
