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
  late bool nativeMaximized;

  setUp(() {
    calls = [];
    nativeMaximized = false;
    controller = DesktopWindowController(enabled: true);
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method == 'toggleMaximize') nativeMaximized = !nativeMaximized;
      if (call.method == 'getWindowState') {
        return {'maximized': nativeMaximized};
      }
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
      expect(calls.map((call) => call.method), [
        'setMode',
        'setMode',
        'getWindowState',
        'setMode',
      ]);
      expect(
        calls
            .where((call) => call.method == 'setMode')
            .map((call) => call.arguments),
        ['login', 'main', 'login'],
      );
    },
  );

  test('a queued stale login cannot shrink the authenticated window', () async {
    final login = controller.setMode(DesktopWindowMode.login);
    final main = controller.setMode(DesktopWindowMode.main);
    await Future.wait([login, main]);
    expect(calls.first.arguments, 'main');
    expect(calls.map((call) => call.method), ['setMode', 'getWindowState']);
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

  test(
    'shared controls act in both modes and maximize only the main window',
    () async {
      await controller.setMode(DesktopWindowMode.login);
      await controller.beginDrag();
      await controller.minimize();
      await controller.close();
      await controller.toggleMaximize();
      await controller.setMode(DesktopWindowMode.main);
      await controller.beginDrag();
      await controller.minimize();
      await controller.close();
      await controller.toggleMaximize();
      expect(controller.maximized.value, isTrue);
      await controller.toggleMaximize();
      expect(controller.maximized.value, isFalse);
      expect(calls.map((call) => call.method), [
        'setMode',
        'beginDrag',
        'minimize',
        'close',
        'setMode',
        'getWindowState',
        'beginDrag',
        'minimize',
        'close',
        'toggleMaximize',
        'getWindowState',
        'toggleMaximize',
        'getWindowState',
      ]);
    },
  );

  test('native state changes update expansion and login resets it', () async {
    await controller.setMode(DesktopWindowMode.main);
    expect(controller.maximized.value, isFalse);
    await _nativeState({'maximized': true});
    expect(controller.maximized.value, isTrue);
    await _nativeState({'maximized': 'invalid'});
    expect(controller.maximized.value, isTrue);
    await controller.setMode(DesktopWindowMode.login);
    expect(controller.maximized.value, isFalse);
    await _nativeState({'maximized': true});
    expect(controller.maximized.value, isFalse);
  });

  test('concurrent maximize actions share one native operation', () async {
    await controller.setMode(DesktopWindowMode.main);
    calls.clear();
    final reply = Completer<void>();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method == 'toggleMaximize') await reply.future;
      if (call.method == 'getWindowState') return {'maximized': true};
      return null;
    });
    final first = controller.toggleMaximize();
    final second = controller.toggleMaximize();
    reply.complete();
    await Future.wait([first, second]);
    expect(calls.map((call) => call.method), [
      'toggleMaximize',
      'getWindowState',
    ]);
    expect(controller.maximized.value, isTrue);
  });

  test(
    'an older state protocol does not disable supported window actions',
    () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (call.method == 'getWindowState') throw MissingPluginException();
        return null;
      });
      await controller.setMode(DesktopWindowMode.main);
      await controller.close();
      expect(calls.map((call) => call.method), [
        'setMode',
        'getWindowState',
        'close',
      ]);
    },
  );

  test('a stale state query cannot overwrite a newer native event', () async {
    final reply = Completer<Object?>();
    final started = Completer<void>();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      if (call.method == 'getWindowState') {
        started.complete();
        return reply.future;
      }
      return null;
    });
    final pending = controller.setMode(DesktopWindowMode.main);
    await started.future;
    await _nativeState({'maximized': true});
    reply.complete({'maximized': false});
    await pending;
    expect(controller.maximized.value, isTrue);
  });

  test(
    'a main state reply arriving after logout cannot restore expansion',
    () async {
      final reply = Completer<Object?>();
      final started = Completer<void>();
      messenger.setMockMethodCallHandler(_channel, (call) async {
        if (call.method == 'getWindowState') {
          started.complete();
          return reply.future;
        }
        return null;
      });
      final pending = controller.setMode(DesktopWindowMode.main);
      await started.future;
      await controller.setMode(DesktopWindowMode.login);
      reply.complete({'maximized': true});
      await pending;
      expect(controller.maximized.value, isFalse);
    },
  );

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

Future<void> _nativeState(Object? state) {
  final delivered = Completer<void>();
  ServicesBinding.instance.channelBuffers.push(
    _channel.name,
    _channel.codec.encodeMethodCall(MethodCall('windowStateChanged', state)),
    (_) => delivered.complete(),
  );
  return delivered.future;
}
