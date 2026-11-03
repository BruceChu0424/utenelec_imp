import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'package:uten_imp/components/feedback/uten_segment_badge_label.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/pages/sales_order_progress_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  final reads = <String>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    reads.add(path);
    if (path == '/sales/orders/progress') {
      return const {
        'items': <Map<String, dynamic>>[],
        'page': 1,
        'size': 50,
        'total': 0,
        'totalPages': 0,
      };
    }
    return const {};
  }
}

BadgeSummary _summary({int rejected = 2, int pending = 3}) =>
    badgeSummaryFixture(
      facts: {
        'salesStage.DRAFT': 4,
        'salesStage.REJECTED': rejected,
        'salesStage.PENDING': pending,
        'salesStage.PRODUCING': 5,
        'salesStage.SHIPPABLE': 6,
        'salesStage.SHIPMENT_PENDING': 7,
        'salesStage.WAREHOUSE_PENDING': 8,
      },
    );

UtenSegmentBadgeLabel _segment(WidgetTester tester, String label) =>
    tester.widget(
      find.byWidgetPredicate(
        (widget) => widget is UtenSegmentBadgeLabel && widget.label == label,
      ),
    );

Future<void> _mount(
  WidgetTester tester,
  _Api api,
  FixedBadgeSummaryNotifier notifier,
) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: '/sales/progress',
    routes: [
      GoRoute(
        path: '/sales/progress',
        builder: (_, _) => const SalesOrderProgressPage(),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.binding.setSurfaceSize(const Size(1200, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.salesOrderView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        badgeSummaryProvider.overrideWith(() => notifier),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
}

void main() {
  testWidgets(
    'first frame reuses parent facts without another stage-count read',
    (tester) async {
      final api = _Api();
      final notifier = FixedBadgeSummaryNotifier(_summary());
      await _mount(tester, api, notifier);

      expect(_segment(tester, '草稿').count, 4);
      expect(_segment(tester, '进行中').count, 2);
      expect(_segment(tester, '进行中').inProgressCount, 8);
      expect(_segment(tester, '可发货').count, 6);
      expect(_segment(tester, '可发货').inProgressCount, 15);
      await tester.pumpAndSettle();
      expect(api.reads, isNot(contains('/sales/orders/progress/stage-counts')));
      expect(
        api.reads.where((path) => path == '/sales/orders/progress'),
        hasLength(1),
        reason: '已有红数自动选中草稿，首帧复用不再等待独立计数请求',
      );
      expect(notifier.refreshCalls, 0);

      notifier.emit(_summary(rejected: 9, pending: 10));
      await tester.pumpAndSettle();
      expect(_segment(tester, '进行中').count, 9);
      expect(_segment(tester, '进行中').inProgressCount, 15);
      expect(api.reads, isNot(contains('/sales/orders/progress/stage-counts')));

      await tester
          .widget<UtenRefreshButton>(find.byType(UtenRefreshButton))
          .onRefresh();
      expect(notifier.refreshCalls, 1);
    },
  );

  testWidgets('unloaded, unavailable and failed first sources remain unknown', (
    tester,
  ) async {
    final notifier = FixedBadgeSummaryNotifier(BadgeSummary.empty);
    await _mount(tester, _Api(), notifier);
    await tester.pumpAndSettle();

    void expectUnknown() {
      expect(_segment(tester, '草稿').count, isNull);
      expect(_segment(tester, '进行中').count, isNull);
      expect(_segment(tester, '进行中').inProgressCount, isNull);
      expect(_segment(tester, '可发货').count, isNull);
    }

    expectUnknown();
    notifier.emit(const BadgeSummary(loaded: true));
    await tester.pumpAndSettle();
    expectUnknown();
    notifier.emit(
      const BadgeSummary(loaded: true, staleSources: {'salesStage'}),
    );
    await tester.pumpAndSettle();
    expectUnknown();

    notifier.emit(_summary());
    await tester.pumpAndSettle();
    expect(_segment(tester, '进行中').count, 2);
    notifier.emit(
      const BadgeSummary(
        loaded: true,
        staleSources: {'salesStage'},
      ).keepStaleFrom(_summary()),
    );
    await tester.pumpAndSettle();
    expect(_segment(tester, '进行中').count, 2);
    expect(_segment(tester, '进行中').inProgressCount, 8);
  });

  testWidgets('a partial source cannot turn missing task facts into zero', (
    tester,
  ) async {
    await _mount(
      tester,
      _Api(),
      FixedBadgeSummaryNotifier(
        const BadgeSummary(loaded: true, facts: {'salesStage.DRAFT': 0}),
      ),
    );
    await tester.pumpAndSettle();
    expect(_segment(tester, '草稿').count, 0);
    expect(_segment(tester, '进行中').count, isNull);
    expect(_segment(tester, '进行中').inProgressCount, isNull);
    expect(_segment(tester, '可发货').count, isNull);
  });
}
