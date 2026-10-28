import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/app.dart';
import 'package:uten_imp/components/buttons/uten_back_button.dart';
import 'package:uten_imp/core/maintenance/server_maintenance.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/connection_recovery.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/platform/desktop_window.dart';
import 'package:uten_imp/core/platform/platform_window_title.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/auth/pages/login_page.dart';
import 'package:uten_imp/features/auth/widgets/account_field.dart';
import 'package:uten_imp/features/disaster_recovery/disaster_recovery_page.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding.dart';
import 'package:uten_imp/shared/platform_branding/platform_branding_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _OfflineSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

const _screenshotDirectory = String.fromEnvironment(
  'UTEN_NAVIGATION_SCREENSHOT_DIR',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('com.uten.imp/desktop_window');

  setUpAll(() async {
    if (_screenshotDirectory.isEmpty) return;
    final font = FontLoader('NotoSansSC')
      ..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  for (final platform in [TargetPlatform.windows, TargetPlatform.macOS]) {
    for (final size in [const Size(800, 540), const Size(460, 720)]) {
      testWidgets(
        '${platform.name} ${size.width}: login recovery uses its own window and returns without losing input',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({'themeMode': 'dark'});
          FlutterSecureStorage.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final controller = DesktopWindowController(enabled: true);
          var reachable = false;
          var probes = 0;
          final connection = ConnectionRecoveryController(
            probe: () async {
              probes++;
              return reachable;
            },
            probeDelays: const [Duration(hours: 1)],
          );
          final maintenance = ServerMaintenanceController(
            read: () async => ServerMaintenanceSnapshot(
              phase: ServerMaintenancePhase.available,
              serverTime: DateTime.utc(2026, 10, 26),
            ),
            ready: () async => true,
          );
          final calls = <MethodCall>[];
          var nativeMaximized = false;
          messenger.setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'toggleMaximize') {
              nativeMaximized = !nativeMaximized;
            }
            if (call.method == 'getWindowState') {
              return {'maximized': nativeMaximized};
            }
            return null;
          });
          addTearDown(() {
            controller.dispose();
            maintenance.dispose();
            messenger.setMockMethodCallHandler(channel, null);
          });
          final container = ProviderContainer(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(preferences),
              sessionProvider.overrideWith(_OfflineSession.new),
              apiBaseUrlProvider.overrideWithValue(
                'https://unavailable.example/api',
              ),
              apiClientProvider.overrideWith(
                (ref) => throw StateError('Business API unavailable'),
              ),
              desktopWindowControllerProvider.overrideWithValue(controller),
              connectionRecoveryProvider.overrideWith((ref) => connection),
              serverMaintenanceControllerProvider.overrideWithValue(
                maintenance,
              ),
              platformWindowTitleSyncProvider.overrideWith((ref) {}),
              platformBrandingSnapshotProvider.overrideWithValue(
                PlatformBranding.defaults,
              ),
              rescueLauncherProvider.overrideWithValue((uri) async => true),
            ],
          );
          addTearDown(container.dispose);
          final captureKey = GlobalKey();
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: RepaintBoundary(key: captureKey, child: const UtenApp()),
            ),
          );
          await tester.pumpAndSettle();
          final loginState = tester.state(find.byType(LoginPage));
          final account = find.descendant(
            of: find.byType(AccountField),
            matching: find.byType(TextField),
          );
          await tester.ensureVisible(account);
          await tester.enterText(account, 'keep-my-account');
          expect(
            find.byKey(const Key('login-disaster-recovery')),
            findsNothing,
          );

          connection.markDisconnected();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          final retry = find.byKey(const ValueKey('connection-recovery-retry'));
          expect(retry, findsOneWidget);
          await _capture(
            tester,
            captureKey,
            '${platform.name}-${size.width.toInt()}-login-offline',
          );

          // Exercise the same window coordinates as a real pointer. The native
          // drag strip previously intercepted this action above the banner.
          reachable = true;
          await tester.tapAt(tester.getCenter(retry));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          expect(probes, 1);
          expect(connection.state.phase, ConnectionRecoveryPhase.restored);
          expect(
            calls.where(
              (call) => call.method == 'close' || call.method == 'beginDrag',
            ),
            isEmpty,
          );
          expect(tester.state(find.byType(LoginPage)), same(loginState));
          expect(
            tester.widget<TextField>(account).controller!.text,
            'keep-my-account',
          );
          await tester.pump(const Duration(seconds: 3));
          await tester.pumpAndSettle();
          expect(connection.state.phase, ConnectionRecoveryPhase.connected);

          final router = container.read(appRouterProvider);
          router.push(RouteName.disasterRecovery);
          await tester.pumpAndSettle();
          expect(topMatchedLocationOf(router), RouteName.disasterRecovery);
          // go_router's default push deliberately keeps the source address.
          expect(
            router.routerDelegate.currentConfiguration.uri.path,
            RouteName.login,
          );
          expect(find.byType(DisasterRecoveryPage), findsOneWidget);
          expect(find.byKey(const Key('desktop-window-drag')), findsOneWidget);
          expect(find.byKey(const Key('desktop-window-close')), findsOneWidget);
          expect(
            find.byKey(const Key('desktop-window-maximize')),
            findsOneWidget,
          );
          expect(
            tester.getRect(find.byType(UtenBackButton)).top,
            greaterThanOrEqualTo(36),
          );
          expect(
            calls.where((call) => call.method == 'setMode').last.arguments,
            'main',
          );
          await _capture(
            tester,
            captureKey,
            '${platform.name}-${size.width.toInt()}-recovery',
          );

          // The routed main presentation and native state share the same
          // controls, including restore, without recreating the login form.
          await tester.tap(find.byKey(const Key('desktop-window-maximize')));
          await tester.pumpAndSettle();
          expect(find.byTooltip('还原'), findsOneWidget);
          await tester.tap(find.byKey(const Key('desktop-window-maximize')));
          await tester.pumpAndSettle();
          expect(find.byTooltip('最大化'), findsOneWidget);
          if (size.width == 800) {
            tester.view.physicalSize = const Size(1280, 800);
            await tester.pumpAndSettle();
            await _capture(
              tester,
              captureKey,
              '${platform.name}-1280-main-recovery',
            );
            tester.view.physicalSize = size;
            await tester.pumpAndSettle();
          }

          // This coordinate was swallowed by the login drag strip on Windows
          // and the close button on macOS, both occupying the top 36 pixels.
          await tester.tapAt(tester.getCenter(find.byType(UtenBackButton)));
          await tester.pumpAndSettle();
          expect(topMatchedLocationOf(router), RouteName.login);
          expect(tester.state(find.byType(LoginPage)), same(loginState));
          expect(
            tester.widget<TextField>(account).controller!.text,
            'keep-my-account',
          );
          expect(find.byKey(const Key('desktop-window-close')), findsOneWidget);
          expect(
            find.byKey(const Key('desktop-window-maximize')),
            findsNothing,
          );
          expect(
            calls
                .where((call) => call.method == 'setMode')
                .map((call) => call.arguments),
            ['login', 'main', 'login'],
          );
          expect(
            calls.where(
              (call) => call.method == 'close' || call.method == 'beginDrag',
            ),
            isEmpty,
          );
          expect(tester.takeException(), isNull);
          await _capture(
            tester,
            captureKey,
            '${platform.name}-${size.width.toInt()}-login-returned',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          maintenance.setVisible(false);
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (_screenshotDirectory.isEmpty) return;
  // Complete the first asset decode before painting a screenshot. Later tests
  // can otherwise look complete only because their images are already cached.
  await tester.runAsync(() async {
    for (final element in find.byType(Image).evaluate()) {
      final image = element.widget as Image;
      await precacheImage(image.image, element);
    }
  });
  await tester.pump();
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      final output = File('$_screenshotDirectory/$name.png');
      await output.parent.create(recursive: true);
      await output.writeAsBytes(png!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
