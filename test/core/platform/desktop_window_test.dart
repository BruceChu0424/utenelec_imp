import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/platform/desktop_window.dart';

const _channel = MethodChannel('com.uten.imp/desktop_window');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late DesktopWindowController controller;
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    controller = DesktopWindowController(enabled: true);
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    controller.dispose();
    messenger.setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('only native Windows and macOS enable the desktop window', () {
    for (final platform in TargetPlatform.values) {
      debugDefaultTargetPlatformOverride = platform;
      expect(
        supportsDesktopWindow,
        platform == TargetPlatform.windows || platform == TargetPlatform.macOS,
      );
    }
  });

  test(
    'login, main and logout have one ordered presentation change each',
    () async {
      await controller.setMode(DesktopWindowMode.login);
      await controller.setMode(DesktopWindowMode.login);
      await controller.setMode(DesktopWindowMode.main);
      await controller.setMode(DesktopWindowMode.main);
      await controller.setMode(DesktopWindowMode.login);
      expect(calls.map((call) => call.method), everyElement('setMode'));
      expect(calls.map((call) => call.arguments), ['login', 'main', 'login']);
    },
  );

  test('a queued stale login cannot shrink the authenticated window', () async {
    final login = controller.setMode(DesktopWindowMode.login);
    final main = controller.setMode(DesktopWindowMode.main);
    await Future.wait([login, main]);
    expect(calls.single.arguments, 'main');
  });

  test('late native error cannot invalidate the latest mode', () async {
    final oldReply = Completer<Object?>();
    final oldStarted = Completer<void>();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.arguments == 'main') {
        oldStarted.complete();
        return oldReply.future;
      }
      return null;
    });
    final old = controller.setMode(DesktopWindowMode.main);
    await oldStarted.future;
    await controller.setMode(DesktopWindowMode.login);
    oldReply.completeError(PlatformException(code: 'WINDOW_UNAVAILABLE'));
    await old;
    await Future<void>.delayed(Duration.zero);
    await controller.setMode(DesktopWindowMode.login);
    expect(calls.map((call) => call.arguments), ['main', 'login']);
  });

  test('a current native failure permits a later presentation retry', () async {
    var fail = true;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (fail) throw PlatformException(code: 'WINDOW_UNAVAILABLE');
      return null;
    });
    await controller.setMode(DesktopWindowMode.login);
    fail = false;
    await controller.setMode(DesktopWindowMode.login);
    expect(calls, hasLength(2));
  });

  test(
    'an old runner missing the channel stays usable and stops probing',
    () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        throw MissingPluginException();
      });
      await controller.setMode(DesktopWindowMode.login);
      await controller.setMode(DesktopWindowMode.main);
      await controller.close();
      expect(calls, hasLength(1));
    },
  );

  test('login controls cannot drag, minimize or close a main window', () async {
    await controller.setMode(DesktopWindowMode.login);
    await controller.beginDrag();
    await controller.minimize();
    await controller.close();
    await controller.setMode(DesktopWindowMode.main);
    await controller.beginDrag();
    await controller.minimize();
    await controller.close();
    expect(calls.map((call) => call.method), [
      'setMode',
      'beginDrag',
      'minimize',
      'close',
      'setMode',
    ]);
  });

  test('unsupported or disposed controllers never send native work', () async {
    final unsupported = DesktopWindowController(enabled: false);
    await unsupported.setMode(DesktopWindowMode.login);
    await unsupported.close();
    unsupported.dispose();
    final queued = controller.setMode(DesktopWindowMode.login);
    controller.dispose();
    await queued;
    await Future<void>.delayed(Duration.zero);
    await controller.setMode(DesktopWindowMode.main);
    expect(calls, isEmpty);
  });
}
