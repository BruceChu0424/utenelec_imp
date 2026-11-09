import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/pages/production_board_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../../helpers/badge_summary_fixture.dart';
import '../../../support/complete_read_plan_batches.dart';

const _emptyPage = <String, dynamic>{
  'items': <Object?>[],
  'page': 1,
  'size': 20,
  'total': 0,
  'totalPages': 1,
};

class _Api extends ApiClient {
  _Api() : super(Dio());

  final facets = Completer<Map<String, dynamic>>();
  final summary = Completer<Map<String, dynamic>>();
  final workshops = Completer<List<Map<String, dynamic>>>();
  final requests = <String>[];
  final progressQueries = <Map<String, dynamic>>[];
  bool completeProgress = false;
  // A later progress batch waits here, then fails (null: every batch answers).
  Completer<void>? failLaterProgress;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    requests.add(path);
    if (path == '/production/schedule/pending/facets') {
      if (query?['keyword'] == 'LATEST') {
        return {
          'status': [
            {'value': 'LATEST', 'label': '最新桶', 'count': 1},
          ],
        };
      }
      return facets.future;
    }
    if (path == '/production/plans/progress' && completeProgress) {
      progressQueries.add({...?query});
      // An offset-exact server: the requested (page, size) slice of one fixed
      // 251-row dataset, with total and totalPages echoed for that size.
      final page = query!['page'] as int;
      final size = query['size'] as int;
      if (progressQueries.length > 1 && failLaterProgress != null) {
        await failLaterProgress!.future;
        throw ApiException('SERVER_ERROR', '生产进度后续批读取失败');
      }
      return {
        'items': [
          for (var i = (page - 1) * size; i < page * size && i < 251; i++)
            {'planId': 'progress-$i', 'billNo': 'PP-$i', 'closed': true},
        ],
        'page': page,
        'size': size,
        'total': 251,
        'totalPages': (251 + size - 1) ~/ size,
      };
    }
    if (path == '/production/plans/progress/summary') return summary.future;
    return _emptyPage;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    requests.add(path);
    if (path == '/production/plans/progress/workshops') return workshops.future;
    return const [];
  }
}

Future<void> _mount(WidgetTester tester, _Api api) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(preferences),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'planner'),
        ),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.productionPlanView,
          Perm.productionMaterialAnalysisCreate,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        fixedBadgeSummaryOverride(badgeSummaryFixture()),
      ],
      child: const MaterialApp(
        locale: Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ProductionBoardPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'history progress exposes all 251 summaries and scrolls without paging controls or reads',
    (tester) async {
      final api = _Api()..completeProgress = true;
      await _mount(tester, api);
      // One complete read of 251 summaries in the shared progressive ladder:
      // (1,50) (2,50) (2,100) (2,200), each batch at its exact offset.
      final batches = completeReadPlanBatches(251);
      await tester.tap(find.text('历史记录'));
      for (
        var frame = 0;
        frame < 200 && api.progressQueries.length < batches.length;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pumpAndSettle();
      expect([
        for (final query in api.progressQueries)
          (page: query['page'] as int, size: query['size'] as int),
      ], batches);
      expect(find.text('20 条/页'), findsNothing);
      expect(find.text('50 条/页'), findsNothing);
      final list = find.byType(ListView).last;
      expect(tester.widget<ListView>(list).semanticChildCount, 251);
      final tail = find.byKey(
        const ValueKey('production-progress-plan-progress-250'),
      );
      expect(tail, findsNothing);
      final scrollable = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(tail, 400, scrollable: scrollable);
      expect(tail.hitTestable(), findsOneWidget);
      expect(find.byType(Card).evaluate().length, lessThan(40));
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(api.progressQueries, hasLength(batches.length));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'history progress takes its progressive plan cards down when a later batch fails',
    (tester) async {
      final api = _Api()
        ..completeProgress = true
        ..failLaterProgress = Completer<void>();
      await _mount(tester, api);
      await tester.tap(find.text('历史记录'));
      for (
        var frame = 0;
        frame < 200 && api.progressQueries.length < 2;
        frame++
      ) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      // The first validated batch is already on screen while the read goes on.
      final first = find.byKey(
        const ValueKey('production-progress-plan-progress-0'),
      );
      expect(first, findsOneWidget);
      api.failLaterProgress!.complete();
      await tester.pumpAndSettle();
      // The failed read withdraws every progressive card: only the failure
      // with its retry remains, never half of the plans as if complete.
      expect(first, findsNothing);
      expect(
        find.byType(Card).evaluate().where((card) {
          final key = card.widget.key;
          return key is ValueKey<String> &&
              key.value.startsWith('production-progress-plan-');
        }),
        isEmpty,
      );
      expect(find.text('生产进度后续批读取失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect([
        for (final query in api.progressQueries)
          (page: query['page'] as int, size: query['size'] as int),
      ], completeReadPlanBatches(251).take(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('待排产空列表不等待表头筛选桶', (tester) async {
    final api = _Api();
    await _mount(tester, api);
    await tester.tap(find.text('待排产'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final table = tester.widget<MasterDataTableView<SchedulePendingRow>>(
      find.byType(MasterDataTableView<SchedulePendingRow>),
    );
    expect(api.facets.isCompleted, isFalse);
    expect(table.isLoading, isFalse);
    expect(find.text('暂无待排产的订单行'), findsOneWidget);

    api.facets.completeError(StateError('facets unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('暂无待排产的订单行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('历史空列表不等待汇总或车间字典，附属失败仍可浏览', (tester) async {
    final api = _Api();
    await _mount(tester, api);
    await tester.tap(find.text('历史记录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.summary.isCompleted, isFalse);
    expect(api.workshops.isCompleted, isFalse);
    expect(find.text('暂无已完成计划'), findsOneWidget);
    expect(find.text('正在加载汇总'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    api.summary.completeError(StateError('summary unavailable'));
    api.workshops.completeError(StateError('workshops unavailable'));
    await tester.pumpAndSettle();
    expect(find.text('暂无已完成计划'), findsOneWidget);
    expect(find.text('汇总暂不可用，请刷新重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('新关键词列表完成后，迟到的旧筛选桶不能覆盖新桶', (tester) async {
    final api = _Api();
    await _mount(tester, api);
    await tester.tap(find.text('待排产'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(
      find.descendant(
        of: find.byType(UtenSearchBar).first,
        matching: find.byType(TextField),
      ),
      'LATEST',
    );
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    var table = tester.widget<MasterDataTableView<SchedulePendingRow>>(
      find.byType(MasterDataTableView<SchedulePendingRow>),
    );
    expect(table.facets['status']?.single.value, 'LATEST');
    api.facets.complete({
      'status': [
        {'value': 'STALE', 'label': '旧桶', 'count': 1},
      ],
    });
    await tester.pumpAndSettle();
    table = tester.widget<MasterDataTableView<SchedulePendingRow>>(
      find.byType(MasterDataTableView<SchedulePendingRow>),
    );
    expect(table.facets['status']?.single.value, 'LATEST');
    expect(tester.takeException(), isNull);
  });
}
