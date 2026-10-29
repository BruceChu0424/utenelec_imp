@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_web/video_player_web.dart';
import 'package:web/web.dart' as web;
import 'package:uten_imp/shared/attachments/attachment_media_preview.dart';
import 'package:uten_imp/shared/attachments/attachment_media_source.dart';

import '../fixtures/synthetic_h264_mp4.dart';

void main() {
  // Flutter's browser test bootstrap does not run the application's generated
  // plugin registrant. Register the real endorsed HTML media implementation.
  VideoPlayerPlugin.registerWith(Registrar());
  testWidgets(
    'Chrome decodes private verified MP4 bytes, plays, pauses, seeks and revokes its blob',
    (tester) async {
      final bytes = syntheticH264Mp4();
      expect(sha256.convert(bytes).toString(), syntheticH264Sha256);
      AttachmentMediaSource? source;
      var released = false;
      Future<AttachmentMediaSource> realLoader(
        Uint8List input,
        String contentType,
      ) async {
        final realSource = await createAttachmentMediaSource(
          input,
          contentType,
        );
        source = AttachmentMediaSource(
          controller: realSource.controller,
          release: () async {
            await realSource.release();
            released = true;
          },
        );
        return source!;
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentMediaPreview(
              bytes: bytes,
              contentType: 'video/mp4',
              sourceLoader: realLoader,
            ),
          ),
        ),
      );
      await _until(
        tester,
        () => source?.controller.value.isInitialized ?? false,
        'real browser MP4 decoding',
      );
      await tester.pump();
      final controller = source!.controller;
      final blobUrl = controller.dataSource;
      expect(blobUrl, startsWith('blob:'));
      expect(controller.httpHeaders, isEmpty);
      expect(controller.value.size, const Size(160, 90));
      expect(controller.value.duration.inMilliseconds, closeTo(3000, 100));
      expect(controller.value.isPlaying, isFalse);
      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(find.text('当前设备无法播放此文件'), findsNothing);

      // Browser media clocks and decoder events run in real time, outside the
      // Flutter test's fake clock. A change in currentTime proves playback.
      await tester.tap(find.byTooltip('静音'));
      await tester.pump();
      await tester.tap(find.byTooltip('播放'));
      await _until(
        tester,
        () => controller.value.position.inMilliseconds > 100,
        'real media time to advance after play',
      );
      await tester.tap(find.byTooltip('暂停'));
      await _until(tester, () => !controller.value.isPlaying, 'pause');

      final progress = find.byType(VideoProgressIndicator);
      final rect = tester.getRect(progress);
      await tester.tapAt(Offset(rect.left + rect.width * .6, rect.center.dy));
      await _until(
        tester,
        () => controller.value.position.inMilliseconds >= 1500,
        'seek through the visible progress control',
      );
      expect(controller.value.isPlaying, isFalse);
      expect(controller.value.hasError, isFalse);

      // Before removal this local URL contains precisely the verified original.
      final response = await tester.runAsync(
        () => web.window.fetch(blobUrl.toJS).toDart,
      );
      expect(response!.ok, isTrue);
      final original = await response.arrayBuffer().toDart;
      expect(
        sha256.convert(original.toDart.asUint8List()).toString(),
        syntheticH264Sha256,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await _until(
        tester,
        () => released,
        'widget removal to release its source',
      );
      var revoked = false;
      await tester.runAsync(() async {
        try {
          await web.window.fetch(blobUrl.toJS).toDart;
        } catch (_) {
          revoked = true;
        }
      });
      expect(
        revoked,
        isTrue,
        reason: 'Closing must revoke the private blob URL',
      );
      expect(tester.takeException(), isNull);
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String reason,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  expect(condition(), isTrue, reason: reason);
}
