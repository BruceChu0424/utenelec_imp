import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/pages/notice_detail_page.dart';
import 'package:uten_imp/features/notice/pages/notice_list_page.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';

const _orderId = '11111111-1111-4111-8111-111111111111';
const _orderPath = '/sales/orders/$_orderId';
const _stageKey = ValueKey('notice-group-stage');

Notice _notice(String id) => Notice(
  id: id,
  title: '订单节点-$id',
  content: '同一订单的进展已更新，请查看对应业务详情。',
  type: NoticeType.workflow,
  publisher: '业务协同中心',
  publishedAt: DateTime.utc(2026, 10, 28, 12),
  isRead: false,
  actionRoute: _orderPath,
);

class _Repository extends Fake implements NoticeRepository {
  _Repository(this.notices);

  final List<Notice> notices;
  final markReadCalls = <String>[];
  final detailCalls = <String>[];
  Completer<void>? markReadGate;

  @override
  Future<List<Notice>> list({bool? onlyUnread, bool? importantOnly}) async =>
      List.of(notices);

  @override
  Future<Notice> markRead(String id) async {
    markReadCalls.add(id);
    await markReadGate?.future;
    final index = notices.indexWhere((notice) => notice.id == id);
    return notices[index] = notices[index].copyWith(isRead: true);
  }

  @override
  Future<Notice?> getById(String id) async {
    detailCalls.add(id);
    return notices.where((notice) => notice.id == id).firstOrNull;
  }
}

/// Observe both real Navigators: visible text alone can miss a detail sheet
/// mounted beneath a root group dialog, or a group left over a new business page.
class _Routes extends NavigatorObserver {
  final active = <Route<dynamic>>[];
  int popupPushes = 0;

  List<PopupRoute<dynamic>> get popups =>
      active.whereType<PopupRoute<dynamic>>().toList();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    active.add(route);
    if (route is PopupRoute) popupPushes++;
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    active.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    active.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute == null) {
      if (newRoute != null) active.add(newRoute);
      return;
    }
    final index = active.indexOf(oldRoute);
    if (index >= 0) {
      if (newRoute == null) {
        active.removeAt(index);
      } else {
        active[index] = newRoute;
      }
    }
  }
}

class _Harness {
  _Harness(
    this.router,
    this.root,
    this.shell,
    this.rootRoutes,
    this.shellRoutes,
  );

  final GoRouter router;
  final GlobalKey<NavigatorState> root;
  final GlobalKey<NavigatorState> shell;
  final _Routes rootRoutes;
  final _Routes shellRoutes;
}

Future<_Harness> _mount(
  WidgetTester tester,
  _Repository repository,
  double width,
) async {
  await tester.binding.setSurfaceSize(Size(width, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final root = GlobalKey<NavigatorState>();
  final shell = GlobalKey<NavigatorState>();
  final rootRoutes = _Routes();
  final shellRoutes = _Routes();
  final router = GoRouter(
    navigatorKey: root,
    observers: [rootRoutes],
    initialLocation: '/notice',
    routes: [
      ShellRoute(
        navigatorKey: shell,
        observers: [shellRoutes],
        builder: (_, _, child) => Scaffold(body: child),
        routes: [
          GoRoute(path: '/notice', builder: (_, _) => const NoticeListPage()),
          GoRoute(
            path: '/sales/orders/:id',
            builder: (_, _) => const Scaffold(body: Text('订单业务页面')),
          ),
        ],
      ),
    ],
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
    router.dispose();
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        noticeRepositoryProvider.overrideWithValue(repository),
        authenticatedScopeProvider.overrideWithValue(null),
        apiBaseUrlProvider.overrideWithValue('https://example.invalid'),
        badgeSummaryProvider.overrideWith(
          () => FixedBadgeSummaryNotifier(badgeSummaryFixture()),
        ),
      ],
      child: MaterialApp.router(
        routerConfig: router,
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildLightTheme(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(root.currentState, isNotNull);
  expect(shell.currentState, isNotNull);
  expect(root.currentState, isNot(same(shell.currentState)));
  return _Harness(router, root, shell, rootRoutes, shellRoutes);
}

void _expectTopDetail(WidgetTester tester, _Harness harness, int popupCount) {
  final detail = find.byType(NoticeDetailPage);
  expect(detail, findsOneWidget);
  final route = ModalRoute.of(tester.element(detail))!;
  expect(route.isCurrent, isTrue, reason: '详情必须在相关通知组上方接收交互');
  expect(route.navigator, same(harness.root.currentState));
  expect(harness.rootRoutes.popups, hasLength(popupCount));
  expect(harness.shellRoutes.popups, isEmpty);
}

void main() {
  for (final width in [375.0, 1400.0]) {
    testWidgets(
      'nested shell stack detail is topmost and business action removes both layers at $width',
      (tester) async {
        final repository = _Repository([
          _notice('receipt'),
          _notice('approved'),
        ]);
        final harness = await _mount(tester, repository, width);
        final pageBarriers = find.byType(ModalBarrier).evaluate().length;
        await tester.tap(find.textContaining('共 2 条'));
        await tester.pumpAndSettle();
        expect(harness.rootRoutes.popups, hasLength(1));
        expect(harness.shellRoutes.popups, isEmpty);

        final stage = find.byKey(_stageKey);
        final groupRoute = ModalRoute.of(tester.element(stage))!;
        expect(groupRoute.navigator, same(harness.root.currentState));
        final card = find.descendant(
          of: stage,
          matching: find.text('订单节点-approved'),
        );
        await tester.ensureVisible(card);
        await tester.tap(card);
        await tester.pumpAndSettle();

        expect(repository.markReadCalls, ['approved']);
        _expectTopDetail(tester, harness, 2);
        expect(groupRoute.isCurrent, isFalse);
        final action = find.descendant(
          of: find.byType(NoticeDetailPage),
          matching: find.text('查看详情'),
        );
        await tester.ensureVisible(action);
        expect(action.hitTestable(), findsOneWidget);
        await tester.tap(action);
        await tester.pumpAndSettle();

        expect(harness.router.state.uri.path, _orderPath);
        expect(harness.router.state.uri.queryParameters['returnTo'], '/notice');
        expect(find.text('订单业务页面').hitTestable(), findsOneWidget);
        expect(find.byType(NoticeDetailPage), findsNothing);
        expect(find.byKey(_stageKey), findsNothing);
        // Root and shell PageRoutes also own non-interactive barrier entries.
        // Opening/closing the two popup routes must leave only that baseline.
        expect(find.byType(ModalBarrier), findsNWidgets(pageBarriers));
        expect(find.byType(ModalBarrier).hitTestable(), findsNothing);
        expect(harness.rootRoutes.popups, isEmpty);
        expect(harness.shellRoutes.popups, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'single card rapid taps while marking read open exactly one detail at $width',
      (tester) async {
        final gate = Completer<void>();
        final repository = _Repository([_notice('single')])
          ..markReadGate = gate;
        final harness = await _mount(tester, repository, width);
        final card = find.text('订单节点-single');
        await tester.tap(card);
        await tester.pump(const Duration(milliseconds: 25));
        await tester.tap(card);
        await tester.pump(const Duration(milliseconds: 25));

        expect(repository.markReadCalls, ['single']);
        expect(repository.detailCalls, isEmpty);
        expect(harness.rootRoutes.popups, isEmpty);
        expect(find.byType(NoticeDetailPage), findsNothing);
        gate.complete();
        await tester.pumpAndSettle();

        _expectTopDetail(tester, harness, 1);
        expect(harness.rootRoutes.popupPushes, 1);
        expect(repository.markReadCalls, ['single']);
        expect(repository.detailCalls, ['single']);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'group card rapid taps while marking read open exactly one detail at $width',
      (tester) async {
        final gate = Completer<void>();
        final repository = _Repository([
          _notice('receipt'),
          _notice('approved'),
        ])..markReadGate = gate;
        final harness = await _mount(tester, repository, width);
        await tester.tap(find.textContaining('共 2 条'));
        await tester.pumpAndSettle();
        final card = find.descendant(
          of: find.byKey(_stageKey),
          matching: find.text('订单节点-approved'),
        );
        await tester.ensureVisible(card);
        await tester.tap(card);
        await tester.pump(const Duration(milliseconds: 25));
        await tester.tap(card);
        await tester.pump(const Duration(milliseconds: 25));

        expect(repository.markReadCalls, ['approved']);
        expect(repository.detailCalls, isEmpty);
        expect(harness.rootRoutes.popups, hasLength(1));
        gate.complete();
        await tester.pumpAndSettle();

        _expectTopDetail(tester, harness, 2);
        expect(harness.rootRoutes.popupPushes, 2);
        expect(repository.markReadCalls, ['approved']);
        expect(repository.detailCalls, ['approved']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
