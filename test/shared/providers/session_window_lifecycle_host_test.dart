@TestOn('vm')
library;

import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/router/app_router.dart';
import 'package:uten_imp/core/security/pending_refresh_revocation_store.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/core/security/tab_scoped_store.dart';
import 'package:uten_imp/core/web_update/web_update_safety.dart';
import 'package:uten_imp/core/web_update/update_safety_navigation.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/auth/services/pending_refresh_revocation_drainer.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/session_window_lifecycle_host.dart';

class _Session extends SessionNotifier {
  int logoutCalls = 0;
  Completer<void>? logoutGate;

  @override
  SessionState build() => const SessionState(status: AuthStatus.authenticated);

  @override
  Future<void> logout() async {
    logoutCalls++;
    await logoutGate?.future;
    state = const SessionState();
  }
}

class _Drainer extends PendingRefreshRevocationDrainer {
  _Drainer()
    : super(
        store: PendingRefreshRevocationStore(
          SecureStorage(
            const FlutterSecureStorage(),
            sessionScope: ProcessSessionScopedStore(),
          ),
        ),
        revoke: (_) async => true,
      );

  int calls = 0;
  @override
  Future<void> drain() async {
    calls++;
  }
}

Future<AppExitResponse> _exit() =>
    WidgetsBinding.instance.handleRequestAppExit();

void main() {
  late GoRouter router;
  late _Session session;
  late _Drainer drainer;
  late Object owner;
  late UpdateSafetyNavigation safetyNavigation;

  setUp(() {
    owner = Object();
    session = _Session();
    drainer = _Drainer();
    webUpdateSafety.setReady(true);
    safetyNavigation = UpdateSafetyNavigation();
    router = GoRouter(
      observers: [safetyNavigation],
      navigatorKey: appNavigatorKey,
      routes: [GoRoute(path: '/', builder: (_, _) => const SizedBox.expand())],
    );
  });

  tearDown(() {
    FormDraftNavigation.unregister(owner);
    webUpdateSafety.unregister(owner);
    webUpdateSafety.setReady(false);
    drainer.dispose();
    router.dispose();
    safetyNavigation.dispose();
    UtenBusyOverlay.debugResetYield();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sessionProvider.overrideWith(() => session),
          pendingRefreshRevocationDrainerProvider.overrideWithValue(drainer),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          builder: (_, child) => Overlay.wrap(
            child: SessionWindowLifecycleHost(router: router, child: child!),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  _desktopTestWidgets(
    'cancelled editor leave keeps the session and skips logout',
    (tester) async {
      await mount(tester);
      FormDraftNavigation.register(
        owner,
        '/',
        () async => false,
        router: router,
      );
      final response = _exit();
      await tester.pump();
      expect(await response, AppExitResponse.cancel);
      expect(session.logoutCalls, 0);
      expect(drainer.calls, 0);
      expect(find.byType(UtenBusyOverlay), findsNothing);
    },
  );

  _desktopTestWidgets(
    'checkpoint completes before logout and repeated close shares one operation',
    (tester) async {
      await mount(tester);
      final checkpoint = Completer<void>();
      var checkpoints = 0;
      webUpdateSafety.registerServerReloadCheckpoint(owner, () async {
        checkpoints++;
        await checkpoint.future;
      });
      session.logoutGate = Completer<void>();
      final first = _exit();
      final second = _exit();
      await tester.pump();
      await tester.pump();
      expect(checkpoints, 1);
      expect(session.logoutCalls, 0);
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      checkpoint.complete();
      await tester.pump();
      expect(session.logoutCalls, 1);
      session.logoutGate!.complete();
      await tester.pumpAndSettle();
      expect(await first, AppExitResponse.exit);
      expect(await second, AppExitResponse.exit);
      expect(drainer.calls, 1);
      expect(find.byType(UtenBusyOverlay), findsNothing);
    },
  );

  _desktopTestWidgets(
    'native update exit is not blocked by its own named update surface',
    (tester) async {
      await mount(tester);
      unawaited(
        appNavigatorKey.currentState!.push<void>(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: RouteName.clientUpdate),
            builder: (_) => const Scaffold(body: Text('已接受更新交接')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(webUpdateSafety.snapshot.serverReloadSafe, isTrue);
      final response = _exit();
      await tester.pumpAndSettle();
      expect(await response, AppExitResponse.exit);
      expect(session.logoutCalls, 1);
      expect(find.text('请先完成当前操作再关闭窗口'), findsNothing);
    },
  );

  _desktopTestWidgets(
    'stuck checkpoint cancels close within ten seconds and a late completion can close on retry',
    (tester) async {
      await mount(tester);
      final checkpoint = Completer<void>();
      webUpdateSafety.registerServerReloadCheckpoint(
        owner,
        () => checkpoint.future,
      );
      final first = _exit();
      await tester.pump();
      await tester.pump();
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(session.logoutCalls, 0);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(find.text('请先完成当前操作再关闭窗口'), findsOneWidget);
      router.pop();
      await tester.pumpAndSettle();
      expect(await first, AppExitResponse.cancel);
      checkpoint.complete();
      await tester.pump();
      final retry = _exit();
      await tester.pumpAndSettle();
      expect(await retry, AppExitResponse.exit);
      expect(session.logoutCalls, 1);
    },
  );

  _desktopTestWidgets(
    'unresolved submission cancels close without revoking the session',
    (tester) async {
      await mount(tester);
      webUpdateSafety.register(
        owner,
        () => const WebUpdateSafetyState(busy: true, blocked: true),
      );
      final response = _exit();
      await tester.pumpAndSettle();
      expect(find.text('请先完成当前操作再关闭窗口'), findsOneWidget);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(session.logoutCalls, 0);
      router.pop();
      await tester.pumpAndSettle();
      expect(await response, AppExitResponse.cancel);
    },
  );

  _desktopTestWidgets('minimizing and losing focus never end the session', (
    tester,
  ) async {
    await mount(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(session.logoutCalls, 0);
    expect(drainer.calls, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}

void _desktopTestWidgets(String description, WidgetTesterCallback callback) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await callback(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
