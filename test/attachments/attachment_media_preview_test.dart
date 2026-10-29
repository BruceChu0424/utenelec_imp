import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:uten_imp/shared/attachments/attachment_file_rules.dart';
import 'package:uten_imp/shared/attachments/attachment_media_preview.dart';
import 'package:uten_imp/shared/attachments/attachment_media_source.dart';
import 'package:uten_imp/shared/attachments/attachment_preview_dialog.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  final events = StreamController<VideoEvent>.broadcast();
  DataSource? data;
  int plays = 0;
  int disposals = 0;
  Duration? seek;
  bool hang = false;
  bool failCreate = false;
  final creation = Completer<int>();

  @override
  Future<void> init() async {}
  @override
  Future<int> createWithOptions(VideoCreationOptions options) async {
    data = options.dataSource;
    if (failCreate) throw PlatformException(code: 'codec');
    if (hang) return creation.future;
    return 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    scheduleMicrotask(
      () => events.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(minutes: 2),
          size: const Size(640, 360),
        ),
      ),
    );
    return events.stream;
  }

  @override
  Future<void> dispose(int playerId) async {
    disposals++;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> play(int playerId) async {
    plays++;
  }

  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seek = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async => seek ?? Duration.zero;
  @override
  Widget buildViewWithOptions(VideoViewOptions options) =>
      const SizedBox.expand();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _VideoPlatform platform;
  late VideoPlayerPlatform previous;
  setUp(() {
    previous = VideoPlayerPlatform.instance;
    platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
  });
  tearDown(() async {
    VideoPlayerPlatform.instance = previous;
    await platform.events.close();
  });

  test(
    'opaque library originals cannot gain preview through a familiar suffix',
    () {
      for (final name in ['设计.cdr', '文档.docx', '图片.png', '视频.mp4', '记录.txt']) {
        expect(
          attachmentPreviewKind(name, 'application/octet-stream'),
          AttachmentPreviewKind.none,
        );
      }
      expect(
        attachmentPreviewKind('视频.mp4', 'video/mp4'),
        AttachmentPreviewKind.video,
      );
      expect(
        attachmentPreviewKind('录音.mp3', 'audio/mpeg'),
        AttachmentPreviewKind.audio,
      );
      expect(guessAttachmentContentType('视频.mp4'), isNull);
    },
  );

  testWidgets(
    'verified local playback needs explicit play and releases on close',
    (tester) async {
      var released = 0;
      late VideoPlayerController controller;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentMediaPreview(
              bytes: Uint8List.fromList([1, 2, 3]),
              contentType: 'video/mp4',
              sourceLoader: (bytes, type) async {
                expect(bytes, [1, 2, 3]);
                expect(type, 'video/mp4');
                controller = VideoPlayerController.networkUrl(
                  Uri.parse('blob:local-only'),
                );
                return AttachmentMediaSource(
                  controller: controller,
                  release: () async {
                    released++;
                  },
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(platform.plays, 0);
      expect(platform.data!.uri, 'blob:local-only');
      expect(platform.data!.httpHeaders, isEmpty);
      await tester.tap(find.byTooltip('播放'));
      await tester.pump();
      expect(platform.plays, 1);
      expect(find.byTooltip('暂停'), findsOneWidget);
      await controller.seekTo(const Duration(seconds: 30));
      await tester.pump();
      expect(find.text('00:30 / 02:00'), findsOneWidget);
      await tester.tap(find.byTooltip('暂停'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();
      expect(platform.disposals, 1);
      expect(released, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late source after identity removal is released without initializing',
    (tester) async {
      final source = Completer<AttachmentMediaSource>();
      var released = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AttachmentMediaPreview(
            bytes: Uint8List(3),
            contentType: 'video/mp4',
            sourceLoader: (_, _) => source.future,
          ),
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      source.complete(
        AttachmentMediaSource(
          controller: VideoPlayerController.networkUrl(
            Uri.parse('blob:retired'),
          ),
          release: () async {
            released++;
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(platform.data, isNull);
      expect(platform.plays, 0);
      expect(released, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dialog fullscreen preserves the same player and playback position',
    (tester) async {
      var loads = 0;
      var released = 0;
      late VideoPlayerController controller;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AttachmentPreviewDialog(
              name: '培训.mp4',
              contentType: 'video/mp4',
              bytes: Uint8List(3),
              mediaSourceLoader: (_, _) async {
                loads++;
                controller = VideoPlayerController.networkUrl(
                  Uri.parse('blob:fullscreen'),
                );
                return AttachmentMediaSource(
                  controller: controller,
                  release: () async {
                    released++;
                  },
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await controller.seekTo(const Duration(seconds: 30));
      await tester.tap(find.byTooltip('播放'));
      await tester.pump();
      for (final toggle in ['全屏', '退出全屏']) {
        await tester.tap(find.byTooltip(toggle));
        await tester.pumpAndSettle();
        expect(loads, 1);
        expect(released, 0);
        expect(controller.value.position, const Duration(seconds: 30));
        expect(controller.value.isPlaying, isTrue);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await tester.pump();
      expect(released, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('codec failure shows download fallback and releases the source', (
    tester,
  ) async {
    var released = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AttachmentMediaPreview(
          bytes: Uint8List(3),
          contentType: 'audio/mpeg',
          audioOnly: true,
          sourceLoader: (_, _) async => AttachmentMediaSource(
            controller: VideoPlayerController.networkUrl(
              Uri.parse('blob:audio'),
            ),
            release: () async {
              released++;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    platform.events.addError(
      PlatformException(
        code: 'codec',
        message: 'private path must stay hidden',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('当前设备无法播放此文件'), findsOneWidget);
    expect(find.text('可用「下载原件」保存后用本机应用打开'), findsOneWidget);
    expect(find.textContaining('private path'), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.pump();
    expect(released, 1);
    expect(platform.disposals, 1);
    expect(tester.takeException(), isNull);
  });

  for (final fail in [true, false]) {
    testWidgets('failed/stuck creation releases owned bytes (throws=$fail)', (
      tester,
    ) async {
      platform.failCreate = fail;
      platform.hang = !fail;
      var released = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: AttachmentMediaPreview(
            bytes: Uint8List(3),
            contentType: 'video/mp4',
            sourceLoader: (_, _) async => AttachmentMediaSource(
              controller: VideoPlayerController.networkUrl(
                Uri.parse('blob:failed'),
              ),
              release: () async {
                released++;
              },
            ),
          ),
        ),
      );
      await tester.pump();
      if (!fail) await tester.pump(const Duration(seconds: 21));
      await tester.pump(const Duration(seconds: 3));
      expect(released, 1);
      expect(find.text('当前设备无法播放此文件'), findsOneWidget);
      expect(platform.plays, 0);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'native playback copy preserves bytes and removes only its private directory',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'uten-media-source-test-',
      );
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => root.path);
      try {
        final original = Uint8List.fromList(List.generate(256, (i) => i));
        final source = await createAttachmentMediaSource(original, 'video/mp4');
        final copy = File(Uri.parse(source.controller.dataSource).toFilePath());
        expect(await copy.readAsBytes(), original);
        expect(source.controller.httpHeaders, isEmpty);
        expect(copy.path, startsWith(root.path));
        await source.dispose();
        await source.dispose();
        expect(await root.list().toList(), isEmpty);
        await expectLater(
          createAttachmentMediaSource(original, 'application/octet-stream'),
          throwsArgumentError,
        );
        expect(await root.list().toList(), isEmpty);
      } finally {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await root.delete();
      }
    },
  );
}
