import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:uten_imp/core/constants/app_info.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/platform/platform_window_title.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';

const _channel = MethodChannel('com.uten.imp/window_title');
final _endpoint = StateProvider<String>((ref) => 'https://a.example/api');
final _brand = StateProvider<PlatformBranding>(
  (ref) => const PlatformBranding(platformName: '甲公司平台'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late PlatformWindowTitleController controller;
  setUp(() {
    calls = [];
    controller = PlatformWindowTitleController(enabled: true);
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return null;
    });
  });
  tearDown(() {
    controller.dispose();
    messenger.setMockMethodCallHandler(_channel, null);
  });

  test(
    'sends the configured Unicode platform name through the native caption channel',
    () async {
      await controller.update(
        title: '甲公司🌟管理平台',
        source: 'https://a.example/api',
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setTitle');
      expect(calls.single.arguments, '甲公司🌟管理平台');
    },
  );

  test(
    'default caption and duplicate metadata refreshes do not rename technical identity',
    () async {
      await controller.update(
        title: AppInfo.externalName,
        source: 'https://a.example/api',
      );
      expect(calls, isEmpty);
      await controller.update(title: '甲公司平台', source: 'https://a.example/api');
      await controller.update(title: '甲公司平台', source: 'https://a.example/api');
      await controller.update(
        title: '甲公司平台',
        source: 'https://cloud.example/api',
      );
      expect(calls, hasLength(1));
      expect(calls.single.arguments, '甲公司平台');
    },
  );

  test(
    'rapid server changes cancel a queued old caption before native dispatch',
    () async {
      final first = controller.update(
        title: '旧服务器公司',
        source: 'https://a.example/api',
      );
      final latest = controller.update(
        title: '当前服务器公司',
        source: 'https://b.example/api',
      );
      await Future.wait([first, latest]);
      expect(calls, hasLength(1));
      expect(calls.single.arguments, '当前服务器公司');
    },
  );

  test(
    'a late old-source failure cannot resend an old caption or invalidate the latest update',
    () async {
      final oldReply = Completer<Object?>();
      final oldStarted = Completer<void>();
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        if (call.arguments == '旧服务器公司') {
          oldStarted.complete();
          return oldReply.future;
        }
        return null;
      });
      final first = controller.update(
        title: '旧服务器公司',
        source: 'https://a.example/api',
      );
      await oldStarted.future;
      await controller.update(
        title: '当前服务器公司',
        source: 'https://b.example/api',
      );
      oldReply.completeError(PlatformException(code: 'WINDOW_UNAVAILABLE'));
      await first;
      await Future<void>.delayed(Duration.zero);
      await controller.update(
        title: '当前服务器公司',
        source: 'https://b.example/api',
      );
      expect(calls.map((call) => call.arguments), ['旧服务器公司', '当前服务器公司']);
    },
  );

  test(
    'an older runner missing the optional channel does not fail startup or keep probing',
    () async {
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        throw MissingPluginException();
      });
      await controller.update(title: '甲公司平台', source: 'https://a.example/api');
      await controller.update(title: '乙公司平台', source: 'https://b.example/api');
      expect(calls, hasLength(1));
    },
  );

  test(
    'unsupported platforms and malformed titles never issue native calls',
    () async {
      final nonWindows = PlatformWindowTitleController(enabled: false);
      addTearDown(nonWindows.dispose);
      await nonWindows.update(title: '公司平台', source: 'https://a.example/api');
      for (final title in [
        '',
        '   ',
        '甲\n乙',
        '甲\u0000乙',
        '甲\u0085乙',
        '甲' * 81,
      ]) {
        await controller.update(title: title, source: 'https://a.example/api');
      }
      expect(calls, isEmpty);
    },
  );

  test(
    'disposing the app cancels a scheduled caption without any native mutation',
    () async {
      final pending = controller.update(
        title: '公司平台',
        source: 'https://a.example/api',
      );
      controller.dispose();
      await pending;
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
    },
  );

  test(
    'the app sync keeps UTEN while company metadata and current endpoint change',
    () async {
      late ProviderContainer container;
      controller = PlatformWindowTitleController(
        enabled: true,
        isCurrent: (title, source) =>
            container.read(apiBaseUrlProvider) == source &&
            title == AppInfo.externalName,
      );
      container = ProviderContainer(
        overrides: [
          apiBaseUrlProvider.overrideWith((ref) => ref.watch(_endpoint)),
          platformBrandingSnapshotProvider.overrideWith(
            (ref) => ref.watch(_brand),
          ),
          platformWindowTitleControllerProvider.overrideWithValue(controller),
        ],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        platformWindowTitleSyncProvider,
        (_, _) {},
        fireImmediately: true,
      );
      container.read(_endpoint.notifier).state = 'https://b.example/api';
      container.read(_brand.notifier).state = const PlatformBranding(
        platformName: '乙公司平台',
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
      expect(
        container.read(platformBrandingSnapshotProvider).platformName,
        '乙公司平台',
      );
      subscription.close();
    },
  );

  test(
    'UTEN captions preserve the existing Windows preference storage identity',
    () async {
      // path_provider_windows derives the preference directory from these EXE
      // fields, so changing them during branding work would lose old settings.
      final resource = File('windows/runner/Runner.rc').readAsStringSync();
      expect(resource, contains('VALUE "FileDescription", "UTEN"'));
      expect(resource, contains('VALUE "CompanyName", "Uten"'));
      expect(resource, contains('VALUE "ProductName", "优腾综合管理平台"'));
      expect(
        File('windows/CMakeLists.txt').readAsStringSync(),
        contains('set(BINARY_NAME "uten_imp")'),
      );
      expect(
        File('windows/runner/main.cpp').readAsStringSync(),
        contains('window.Create(L"UTEN"'),
      );
      await controller.update(title: '其他公司平台', source: 'https://b.example/api');
      expect(calls.single.arguments, '其他公司平台');
      expect(File('windows/runner/Runner.rc').readAsStringSync(), resource);
    },
  );
}
