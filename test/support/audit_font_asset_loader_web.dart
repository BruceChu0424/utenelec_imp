import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui_web' as ui_web;

import 'package:web/web.dart' as web;
import 'package:flutter_test/flutter_test.dart' show addTearDown;

/// An audit explicitly requests its real font. Preserve every other tester
/// policy and restore the exact previous environment after this test.
void enableAuditFontMetrics() {
  final original = ui_web.TestEnvironment.instance;
  if (!original.forceTestFonts) return;
  ui_web.TestEnvironment.setUp(
    ui_web.TestEnvironment(
      ignorePlatformMessages: original.ignorePlatformMessages,
      // The default false honors the font explicitly loaded for this audit.
      disableFontFallbacks: original.disableFontFallbacks,
      keepSemanticsDisabledOnUpdate: original.keepSemanticsDisabledOnUpdate,
      defaultToTestUrlStrategy: original.defaultToTestUrlStrategy,
    ),
  );
  addTearDown(() => ui_web.TestEnvironment.setUp(original));
}

/// Web widget tests deliberately ignore platform messages, including assets.
/// Fetch the engine's actual asset URL instead of awaiting an ignored channel.
Future<ByteData> loadAuditFontAsset(String key) async {
  final response = await web.window
      .fetch(ui_web.assetManager.getAssetUrl(key).toJS)
      .toDart;
  if (!response.ok) {
    throw StateError('Audit font asset $key returned HTTP ${response.status}');
  }
  final bytes = await response.arrayBuffer().toDart;
  return ByteData.view(bytes.toDart);
}
