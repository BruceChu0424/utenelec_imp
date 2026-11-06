// 我的访客（2026-09-10 状态表头筛选 + 批量确认接待）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/visitor/models/visitor_application.dart';
import 'package:uten_imp/features/visitor/repositories/visitor_staff_repository.dart';
import 'package:uten_imp/features/visitor_approval/pages/my_visitors_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../support/pump_until.dart';

class _FakeVisitorStaffRepository extends Fake
    implements VisitorStaffRepository {
  _FakeVisitorStaffRepository({required this.items, this.nextPage});

  final List<VisitorApplication> items;
  Completer<PagedResult<VisitorApplication>>? nextPage;
  final List<Map<String, dynamic>> listCalls = [];
  final List<String> confirmed = [];

  @override
  Future<PagedResult<VisitorApplication>> myAsHost({
    String? status,
    int page = 1,
    int size = 20,
    Map<String, String?> columns = const {},
    String? sort,
    bool ascending = true,
  }) async {
    listCalls.add({'status': status, 'page': page});
    if (page == 2 && nextPage != null) return nextPage!.future;
    return PagedResult(
      items: items,
      page: page,
      size: size,
      // Both pages describe the same dataset, so accepting page two must not
      // manufacture a count change that retires the prepared read window.
      total: items.length + (nextPage == null ? 0 : 1),
      totalPages: nextPage == null ? 1 : 2,
    );
  }

  @override
  Future<void> hostConfirm(
    String id, {
    required bool confirmed,
    String? comment,
  }) async {
    if (!confirmed) throw StateError('批量入口只确认，不拒绝');
    this.confirmed.add(id);
  }
}

VisitorApplication _application(String id, VisitorApplicationStatus status) =>
    VisitorApplication(
      id: id,
      visitorName: '访客$id',
      visitPurpose: '洽谈',
      status: status,
      plannedVisitAt: DateTime(2026, 9, 11, 9),
      appliedAt: DateTime(2026, 9, 10, 9),
      company: '外部公司',
      hostName: '王小明',
      hostDepartment: '研发部',
    );

Widget _app(_FakeVisitorStaffRepository repo, SharedPreferences preferences) =>
    ProviderScope(
      overrides: [
        visitorStaffRepositoryProvider.overrideWithValue(repo),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue({Perm.visitorHostConfirm}),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: MyVisitorsPage(),
      ),
    );

MasterDataTableView<VisitorApplication> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<VisitorApplication>>(
      find.byWidgetPredicate(
        (w) => w is MasterDataTableView<VisitorApplication>,
      ),
    );

void _expectHostReviewingReadWindow(
  _FakeVisitorStaffRepository repo, {
  required List<int> pages,
}) {
  expect(repo.listCalls.first, {'status': null, 'page': 1});
  expect(repo.listCalls, [
    for (final page in pages) {'status': null, 'page': page},
  ], reason: '完整读取按原范围取得全部内部批；失败后的明确重试重新验证完整范围');
}

void main() {
  testWidgets(
    'pending internal batch keeps the table mounted and publishes only the complete result',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      final nextPage = Completer<PagedResult<VisitorApplication>>();
      final repo = _FakeVisitorStaffRepository(
        items: [_application('first', VisitorApplicationStatus.hostReviewing)],
        nextPage: nextPage,
      );
      await tester.pumpWidget(_app(repo, preferences));
      await pumpUntil(
        tester,
        () => repo.listCalls.length == 2,
        reason: '完整接待列表尚未读取第二个内部批',
      );

      final finder = find.byKey(const Key('my-visitors-table'));
      final originalState = tester.state(finder);
      expect(tester.state(finder), same(originalState));
      expect(_table(tester).isLoading, isTrue);
      expect(_table(tester).items, isEmpty);

      nextPage.complete(
        PagedResult(
          items: [
            _application('second', VisitorApplicationStatus.hostReviewing),
          ],
          page: 2,
          size: 20,
          total: 2,
          totalPages: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.state(finder), same(originalState));
      expect(_table(tester).currentPage, 1);
      expect(_table(tester).totalPages, 1);
      expect(_table(tester).rowsController!.items.map((row) => row.id), [
        'first',
        'second',
      ]);
      final beforeScroll = repo.listCalls.length;
      await tester.drag(finder, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(repo.listCalls, hasLength(beforeScroll));
      expect(
        find.byKey(const ValueKey('master-table-page-next')),
        findsNothing,
      );
      _expectHostReviewingReadWindow(repo, pages: [1, 2]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed complete refresh retains accepted rows and explicit retry reads the complete range',
    (tester) async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      final repo = _FakeVisitorStaffRepository(
        items: [_application('first', VisitorApplicationStatus.hostReviewing)],
      );
      await tester.pumpWidget(_app(repo, preferences));
      await tester.pumpAndSettle();

      final finder = find.byKey(const Key('my-visitors-table'));
      final originalState = tester.state(finder);
      final firstAttempt = Completer<PagedResult<VisitorApplication>>();
      repo.nextPage = firstAttempt;
      await tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh();
      await pumpUntil(
        tester,
        () => repo.listCalls.length == 3,
        reason: '完整刷新尚未进入待失败的第二个内部批',
      );
      expect(_table(tester).loadingMore, isTrue);
      expect(_table(tester).items.map((row) => row.id), ['first']);
      firstAttempt.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(
        repo.listCalls.where((call) => call['page'] == 2),
        hasLength(1),
        reason:
            'a failed complete read does not repeat its failed batch automatically',
      );
      expect(tester.state(finder), same(originalState));
      expect(_table(tester).currentPage, 1);
      expect(_table(tester).rowsController!.items.map((row) => row.id), [
        'first',
      ]);

      final retryReply = Completer<PagedResult<VisitorApplication>>();
      repo.nextPage = retryReply;
      await tester.tap(find.descendant(of: finder, matching: find.text('重试')));
      await tester.pump();
      retryReply.complete(
        PagedResult(
          items: [
            _application('second', VisitorApplicationStatus.hostReviewing),
          ],
          page: 2,
          size: 20,
          total: 2,
          totalPages: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(_table(tester).currentPage, 1);
      expect(_table(tester).totalPages, 1);
      expect(_table(tester).rowsController!.items.map((row) => row.id), [
        'first',
        'second',
      ]);
      expect(tester.state(finder), same(originalState));
      _expectHostReviewingReadWindow(repo, pages: [1, 1, 2, 1, 2]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('batch host-confirm skips rows not awaiting this host', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakeVisitorStaffRepository(
      items: [
        _application('v-1', VisitorApplicationStatus.hostReviewing),
        _application('v-2', VisitorApplicationStatus.hostReviewing),
        _application('v-3', VisitorApplicationStatus.approved),
      ],
    );
    await tester.pumpWidget(_app(repo, preferences));
    await tester.pumpAndSettle();

    final table = _table(tester);
    expect(table.selectable, isTrue, reason: '「待我确认」口径开多选');
    expect(table.filters['status'], 'hostReviewing');
    table.onSelectedIdsChanged!({'v-1', 'v-2', 'v-3'});
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('my-visitors-batch-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('已跳过'), findsOneWidget);
    await tester.tap(find.text('确认接待'));
    await tester.pumpAndSettle();

    expect(repo.confirmed, ['v-1', 'v-2'], reason: '已批准的行不重复确认');

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('status header facet is pushed to the backend and closes batch', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues(const {});
    final preferences = await SharedPreferences.getInstance();
    final repo = _FakeVisitorStaffRepository(
      items: [_application('v-1', VisitorApplicationStatus.approved)],
    );
    await tester.pumpWidget(_app(repo, preferences));
    await tester.pumpAndSettle();

    _table(tester).onFilterChanged('status', 'approved');
    await tester.pumpAndSettle();

    expect(repo.listCalls.last['status'], 'approved');
    expect(repo.listCalls.last['page'], 1);
    expect(_table(tester).selectable, isFalse, reason: '非「待我确认」口径不开批量确认');

    await tester.pumpWidget(const SizedBox());
  });
}
