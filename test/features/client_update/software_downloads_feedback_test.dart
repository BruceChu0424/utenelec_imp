import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/performance/performance_tier.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_anim.dart';
import 'package:uten_imp/core/ui/opportunistic_dialog_coordinator.dart';
import 'package:uten_imp/features/client_update/software_downloads_controller.dart';
import 'package:uten_imp/features/client_update/software_downloads_page.dart';
import 'package:uten_imp/features/client_update/software_downloads_presentation.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/performance_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/software_downloads_fixture.dart';

late SharedPreferences _preferences;

class _Employee extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: 'employee-a', code: 'EA', name: '下载员工'),
  );
}

class _Tier extends PerformanceNotifier {
  _Tier(this.initial);
  final PerformanceTier initial;
  @override
  PerformanceTier build() => initial;
  void change(PerformanceTier next) => state = next;
}

class _Harness {
  _Harness(this.transport, this.saver);
  final SoftwareDownloadsTransport transport;
  final SoftwarePackageSaveFixture saver;
  final navigator = GlobalKey<NavigatorState>();
  final owner = StateProvider<AuthenticatedScope?>(
    (_) => const AuthenticatedScope(userId: 'employee-a'),
  );
  late final endpoint = StateProvider<SoftwareDownloadsTransport>(
    (_) => transport,
  );
  late ProviderContainer container;

  SoftwareDownloadsController get controller =>
      container.read(softwareDownloadsControllerProvider);
  OpportunisticDialogCoordinator get dialogs =>
      container.read(opportunisticDialogCoordinatorProvider);

  Future<void> pump(
    WidgetTester tester, {
    bool reducedMotion = false,
    bool tickers = true,
    PerformanceTier tier = PerformanceTier.standard,
  }) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(_Employee.new),
          authenticatedScopeProvider.overrideWith((ref) => ref.watch(owner)),
          sharedPreferencesProvider.overrideWithValue(_preferences),
          performanceProvider.overrideWith(() => _Tier(tier)),
          softwareHostReaderProvider.overrideWithValue(
            () async => const SoftwareHostInfo(
              platform: SoftwareDownloadPlatform.windows,
              osLabel: 'Windows 11',
              osVersion: 'windows11',
              architecture: 'x64',
              windowsRuntimeFamily: 'flutter',
            ),
          ),
          softwareDevicePlatformProvider.overrideWithValue(
            SoftwareDownloadPlatform.windows,
          ),
          apiClientProvider.overrideWith((ref) => ref.watch(endpoint).api),
          // Keep the production scope/API dependencies and real controller;
          // replace only the platform save boundary with an atomic fixture.
          softwareDownloadsControllerProvider.overrideWith((ref) {
            final scope = ref.watch(authenticatedScopeProvider);
            final controller = SoftwareDownloadsController(
              api: ref.watch(apiClientProvider),
              enabled: scope != null,
              save: saver.save,
            );
            ref.onDispose(controller.dispose);
            return controller;
          }),
        ],
        child: MaterialApp(
          navigatorKey: navigator,
          theme: buildLightTheme(),
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reducedMotion),
            child: TickerMode(enabled: tickers, child: child!),
          ),
          home: const SoftwareDownloadsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    container = ProviderScope.containerOf(
      tester.element(find.byType(SoftwareDownloadsPage)),
    );
  }

  void showBusinessDialog() {
    unawaited(
      navigator.currentState!.push<void>(
        DialogRoute<void>(
          context: navigator.currentContext!,
          builder: (context) => AlertDialog(
            title: const Text('业务确认'),
            content: const Text('保留当前业务内容'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('继续业务'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> _download(WidgetTester tester) async {
  final action = find.byKey(const ValueKey('software-downloads-windows'));
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pump();
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready, {
  Duration step = UtenAnim.fast,
}) async {
  for (var frame = 0; frame < 20 && !ready(); frame++) {
    await tester.pump(step);
  }
  expect(ready(), isTrue, reason: 'synthetic download should make progress');
  await tester.pump();
}

StreamController<Uint8List> _hold(SoftwareDownloadsTransport transport) {
  final chunks = StreamController<Uint8List>();
  transport.streamFactory = () => chunks.stream;
  addTearDown(() {
    if (!chunks.isClosed) unawaited(chunks.close());
  });
  return chunks;
}

Finder get _progress =>
    find.byKey(const ValueKey('software-download-progress'));

void _expectMotion(WidgetTester tester, Duration expected) {
  final tween = find.descendant(
    of: _progress,
    matching: find.byWidgetPredicate(
      (widget) => widget is TweenAnimationBuilder<double>,
    ),
  );
  final size = find.ancestor(
    of: _progress,
    matching: find.byType(AnimatedSize),
  );
  final switcher = find.ancestor(
    of: _progress,
    matching: find.byType(AnimatedSwitcher),
  );
  if (expected == Duration.zero) {
    expect(tween, findsNothing);
    expect(size, findsNothing);
    expect(switcher, findsNothing);
  } else {
    expect(
      tester.widget<TweenAnimationBuilder<double>>(tween).duration,
      expected,
    );
    expect(tester.widget<AnimatedSize>(size.first).duration, expected);
    expect(tester.widget<AnimatedSwitcher>(switcher.first).duration, expected);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });

  testWidgets(
    'verified completion explains the saved Setup.exe and first installation',
    (tester) async {
      final transport = SoftwareDownloadsTransport();
      final saver = SoftwarePackageSaveFixture();
      final harness = _Harness(transport, saver);
      await harness.pump(tester);
      await _download(tester);
      await tester.pumpAndSettle();
      expect(saver.published.single, transport.bytes);
      expect(find.text('安装程序已下载'), findsOneWidget);
      expect(
        find.textContaining('已校验并保存到：\nfixture-downloads/'),
        findsOneWidget,
      );
      expect(find.textContaining('双击 Setup.exe 完成首次安装'), findsOneWidget);
      expect(find.textContaining('已校验并保存：'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      expect(find.text('安装程序已下载'), findsNothing);
      expect(find.textContaining('已校验并保存：'), findsOneWidget);
      expect(saver.attempts, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failure offers an explicit retry and retries only after confirmation',
    (tester) async {
      final transport = SoftwareDownloadsTransport();
      final saver = SoftwarePackageSaveFixture()
        ..failure = StateError('fixture destination unavailable');
      final harness = _Harness(transport, saver);
      await harness.pump(tester);
      await _download(tester);
      await tester.pumpAndSettle();
      expect(find.text('下载未完成'), findsOneWidget);
      expect(find.text('重试下载'), findsOneWidget);
      expect(find.text('关闭'), findsOneWidget);
      expect(saver.published, isEmpty);
      expect(saver.attempts, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(saver.attempts, 1);
      saver.failure = null;
      await tester.tap(find.text('重试下载'));
      await tester.pumpAndSettle();
      expect(saver.attempts, 2);
      expect(saver.published.single, transport.bytes);
      expect(find.text('下载未完成'), findsNothing);
      expect(find.text('安装程序已下载'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing a failure keeps the error without retrying the download',
    (tester) async {
      final transport = SoftwareDownloadsTransport()..packageStatus = 503;
      final saver = SoftwarePackageSaveFixture();
      final harness = _Harness(transport, saver);
      await harness.pump(tester);
      await _download(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.text('下载未完成'), findsNothing);
      expect(
        find.byKey(const ValueKey('software-download-error')),
        findsOneWidget,
      );
      expect(
        transport.requests.where((item) => item.path.endsWith('/download')),
        hasLength(1),
      );
      expect(saver.published, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancellation discards the transfer and opens no result dialog', (
    tester,
  ) async {
    final transport = SoftwareDownloadsTransport();
    final chunks = _hold(transport);
    final saver = SoftwarePackageSaveFixture();
    final harness = _Harness(transport, saver);
    await harness.pump(tester);
    await _download(tester);
    await _until(tester, () => transport.packageRequested.isCompleted);
    await tester.ensureVisible(find.text('取消下载'));
    await tester.tap(find.text('取消下载'));
    chunks.add(transport.bytes);
    unawaited(chunks.close());
    await tester.pumpAndSettle();
    expect(transport.cancellationObserved, isTrue);
    expect(saver.published, isEmpty);
    expect(harness.controller.savedPath, isNull);
    expect(harness.controller.downloadError, isNull);
    expect(find.text('安装程序已下载'), findsNothing);
    expect(find.text('下载未完成'), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final boundary in ['account', 'logout', 'api']) {
    testWidgets(
      '$boundary replacement removes only its own completed-result dialog',
      (tester) async {
        final transport = SoftwareDownloadsTransport();
        final harness = _Harness(transport, SoftwarePackageSaveFixture());
        await harness.pump(tester);
        await _download(tester);
        await tester.pumpAndSettle();
        final result = ModalRoute.of(tester.element(find.text('安装程序已下载')))!;
        harness.showBusinessDialog();
        await tester.pumpAndSettle();
        if (boundary == 'account' || boundary == 'logout') {
          harness.container
              .read(harness.owner.notifier)
              .state = boundary == 'logout'
              ? null
              : const AuthenticatedScope(userId: 'employee-b');
        } else {
          harness.container.read(harness.endpoint.notifier).state =
              SoftwareDownloadsTransport();
        }
        await tester.pumpAndSettle();
        expect(result.isActive, isFalse);
        expect(find.text('安装程序已下载', skipOffstage: false), findsNothing);
        expect(find.text('业务确认'), findsOneWidget);
        expect(find.text('保留当前业务内容'), findsOneWidget);
        await tester.tap(find.text('继续业务'));
        await tester.pumpAndSettle();
        expect(find.byType(SoftwareDownloadsPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a security reservation takes priority over a completed download',
    (tester) async {
      final transport = SoftwareDownloadsTransport();
      final chunks = _hold(transport);
      final saver = SoftwarePackageSaveFixture();
      final harness = _Harness(transport, saver);
      await harness.pump(tester);
      await _download(tester);
      await _until(tester, () => transport.packageRequested.isCompleted);
      final priority = harness.dialogs.prioritize();
      addTearDown(priority.release);
      harness.showBusinessDialog();
      await tester.pump();
      chunks.add(transport.bytes);
      unawaited(chunks.close());
      await tester.pumpAndSettle();
      expect(saver.published.single, transport.bytes);
      expect(find.text('业务确认'), findsOneWidget);
      expect(find.text('安装程序已下载', skipOffstage: false), findsNothing);
      await tester.tap(find.text('继续业务'));
      priority.release();
      await tester.pumpAndSettle();
      expect(find.text('安装程序已下载'), findsNothing);
      expect(find.textContaining('已校验并保存：'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a later security reservation interrupts an already visible result',
    (tester) async {
      final harness = _Harness(
        SoftwareDownloadsTransport(),
        SoftwarePackageSaveFixture(),
      );
      await harness.pump(tester);
      await _download(tester);
      await tester.pumpAndSettle();
      expect(find.text('安装程序已下载'), findsOneWidget);
      final priority = harness.dialogs.prioritize();
      addTearDown(priority.release);
      harness.showBusinessDialog();
      await tester.pumpAndSettle();
      expect(find.text('安装程序已下载', skipOffstage: false), findsNothing);
      expect(find.text('业务确认'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'download progress moves smoothly between verified chunk counts',
    (tester) async {
      final transport = SoftwareDownloadsTransport();
      final chunks = _hold(transport);
      final harness = _Harness(transport, SoftwarePackageSaveFixture());
      await harness.pump(tester);
      await _download(tester);
      await _until(tester, () => transport.packageRequested.isCompleted);
      await tester.pump(UtenAnim.fast);
      final half = transport.bytes.length ~/ 2;
      chunks.add(Uint8List.sublistView(transport.bytes, 0, half));
      await _until(
        tester,
        () => harness.controller.progress == 0.5,
        step: Duration.zero,
      );
      _expectMotion(tester, UtenAnim.fast);
      final indicator = find.descendant(
        of: _progress,
        matching: find.byType(LinearProgressIndicator),
      );
      await tester.pump(
        Duration(microseconds: UtenAnim.fast.inMicroseconds ~/ 2),
      );
      final painted = tester.widget<LinearProgressIndicator>(indicator).value!;
      expect(painted, greaterThan(0));
      expect(painted, lessThan(0.5));
      await tester.pump(UtenAnim.fast);
      expect(tester.widget<LinearProgressIndicator>(indicator).value, 0.5);
      harness.controller.cancelDownload();
      unawaited(chunks.close());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  for (final quiet in ['accessibility', 'lite', 'tickers']) {
    testWidgets('$quiet removes all download-feedback animation durations', (
      tester,
    ) async {
      final transport = SoftwareDownloadsTransport();
      final chunks = _hold(transport);
      final harness = _Harness(transport, SoftwarePackageSaveFixture());
      await harness.pump(
        tester,
        reducedMotion: quiet == 'accessibility',
        tickers: quiet != 'tickers',
        tier: quiet == 'lite' ? PerformanceTier.lite : PerformanceTier.standard,
      );
      await _download(tester);
      await _until(tester, () => transport.packageRequested.isCompleted);
      chunks.add(
        Uint8List.sublistView(transport.bytes, 0, transport.bytes.length ~/ 2),
      );
      await _until(
        tester,
        () => harness.controller.progress == 0.5,
        step: Duration.zero,
      );
      _expectMotion(tester, Duration.zero);
      final indicator = find.descendant(
        of: _progress,
        matching: find.byType(LinearProgressIndicator),
      );
      expect(tester.widget<LinearProgressIndicator>(indicator).value, 0.5);
      harness.controller.cancelDownload();
      unawaited(chunks.close());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'an in-flight performance downgrade turns feedback motion off immediately',
    (tester) async {
      final transport = SoftwareDownloadsTransport();
      final chunks = _hold(transport);
      final harness = _Harness(transport, SoftwarePackageSaveFixture());
      await harness.pump(tester);
      await _download(tester);
      await _until(tester, () => transport.packageRequested.isCompleted);
      chunks.add(
        Uint8List.sublistView(transport.bytes, 0, transport.bytes.length ~/ 2),
      );
      await _until(
        tester,
        () => harness.controller.progress == 0.5,
        step: Duration.zero,
      );
      _expectMotion(tester, UtenAnim.fast);
      (harness.container.read(performanceProvider.notifier) as _Tier).change(
        PerformanceTier.lite,
      );
      await tester.pump();
      _expectMotion(tester, Duration.zero);
      final indicator = find.descendant(
        of: _progress,
        matching: find.byType(LinearProgressIndicator),
      );
      expect(tester.widget<LinearProgressIndicator>(indicator).value, 0.5);
      harness.controller.cancelDownload();
      unawaited(chunks.close());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
