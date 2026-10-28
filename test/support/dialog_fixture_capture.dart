import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _captureKey = Key('dialog-fixture-capture');

final dialogFixtureCaptureEnabled =
    const bool.fromEnvironment('UI_CAPTURE') ||
    Platform.environment['UI_CAPTURE'] == '1';

Widget dialogFixtureBoundary(Widget child) =>
    RepaintBoundary(key: _captureKey, child: child);

Future<void> loadDialogFixtureFonts() async {
  final textLoader = FontLoader('NotoSansSC')
    ..addFont(rootBundle.load('assets/fonts/NotoSansSCFull.ttf'));
  final iconLoader = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await Future.wait([textLoader.load(), iconLoader.load()]);
}

/// Captures a real feature route in its test fixture. No backend is contacted.
Future<void> captureDialogFixture(WidgetTester tester, String filename) async {
  final previousShadows = debugDisableShadows;
  try {
    debugDisableShadows = false;
    FocusManager.instance.primaryFocus?.unfocus();
    for (final view in tester.binding.renderViews) {
      view.reassemble();
    }
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1.5);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = Directory('output/dialog-unification-20261028');
        await output.create(recursive: true);
        await File(
          '${output.path}/$filename.png',
        ).writeAsBytes(data!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });
  } finally {
    debugDisableShadows = previousShadows;
  }
}
