import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/expense/models/expense_claim.dart';
import 'package:uten_imp/features/expense/pages/expense_list_page.dart';
import 'package:uten_imp/features/expense/providers/expense_providers.dart';
import 'package:uten_imp/features/production/models/production_daily_report.dart';
import 'package:uten_imp/features/production/models/production_plan.dart';
import 'package:uten_imp/features/production/pages/production_daily_report_list_page.dart';
import 'package:uten_imp/features/production/pages/production_plan_list_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../helpers/badge_summary_fixture.dart';
import '../helpers/document_scope_fixture.dart';

enum _Kind { plan, daily, expense }

const _permissions = {
  Perm.productionPlanDelete,
  Perm.productionDailyReportDelete,
  Perm.expenseApply,
};

class _Session extends SessionNotifier {
  void signOut() => state = const SessionState();

  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'user-1',
      employeeId: 'employee-1',
      code: 'E001',
      name: '测试员工',
      department: '生产部',
      permissions: [
        Perm.productionPlanDelete,
        Perm.productionDailyReportDelete,
        Perm.expenseApply,
      ],
    ),
  );
}

Future<FixedBadgeSummaryNotifier> _mount(
  WidgetTester tester,
  _Kind kind,
  _Api api, {
  Set<String> permissions = _permissions,
}) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues(const {});
  final preferences = await SharedPreferences.getInstance();
  final badges = FixedBadgeSummaryNotifier(badgeSummaryFixture());
  final page = switch (kind) {
    _Kind.plan => const ProductionPlanListPage(initialStatus: 'draft'),
    _Kind.daily => const ProductionDailyReportListPage(initialStatus: 'draft'),
    _Kind.expense => const ExpenseListPage(),
  };
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => page)],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_Session.new),
        currentPermissionsProvider.overrideWithValue(permissions),
        sharedPreferencesProvider.overrideWithValue(preferences),
        badgeSummaryProvider.overrideWith(() => badges),
        documentScopeOverride(owners: {'employee-1'}),
        expenseFilterProvider.overrideWith((_) => ExpenseFilter.draft),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return badges;
}

MasterDataTableView<T> _table<T>(WidgetTester tester) => tester.widget(
  find.byWidgetPredicate((widget) => widget is MasterDataTableView<T>),
);

Future<void> _confirmDelete(WidgetTester tester) async {
  await tester.tap(find.textContaining('删除所选草稿 ('));
  await tester.pumpAndSettle();
  await tester.tap(find.text('确认删除'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'plans restrict selection to drafts and retain one atomic batch',
    (tester) async {
      final api = _Api();
      await _mount(tester, _Kind.plan, api);
      var table = _table<ProductionPlanListItem>(tester);
      expect(table.selectable, isTrue);
      expect(table.idOf!(table.items.first), 'draft-1');
      expect(table.idOf!(table.items.last), isNull);
      expect(table.rowKeyOf!(table.items.last), 'approved');
      table.onSelectedIdsChanged!({'draft-1'});
      await tester.pump();
      table = _table<ProductionPlanListItem>(tester);
      table.onFilterChanged('status', '1');
      await tester.pumpAndSettle();
      table = _table<ProductionPlanListItem>(tester);
      expect(table.selectable, isFalse);
      expect(table.selectedIds, isEmpty);
      table.onFilterChanged('status', '0');
      await tester.pumpAndSettle();
      _table<ProductionPlanListItem>(tester).onSelectedIdsChanged!({
        'draft-1',
        'draft-2',
      });
      await tester.pump();
      await tester.tap(find.text('批量删除(2)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认批量删除'));
      await tester.pumpAndSettle();
      expect(api.batchCalls, [
        ['draft-1', 'draft-2'],
      ]);
      expect(api.deletes, isEmpty, reason: '保留服务端原有单事务，禁止降为逐单删除');
      expect(_table<ProductionPlanListItem>(tester).selectedIds, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final kind in _Kind.values) {
    testWidgets('${kind.name} hides multi-select without delete permission', (
      tester,
    ) async {
      await _mount(tester, kind, _Api(), permissions: const {});
      final selectable = switch (kind) {
        _Kind.plan => _table<ProductionPlanListItem>(tester).selectable,
        _Kind.daily => _table<ProductionDailyReportListItem>(tester).selectable,
        _Kind.expense => _table<ExpenseClaim>(tester).selectable,
      };
      expect(selectable, isFalse);
      expect(find.textContaining('删除所选草稿 ('), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('daily drafts clear filters and recheck status before deletion', (
    tester,
  ) async {
    final api = _Api();
    final badges = await _mount(tester, _Kind.daily, api);
    var table = _table<ProductionDailyReportListItem>(tester);
    expect(table.idOf!(table.items.last), isNull);
    expect(table.rowKeyOf!(table.items.last), 'approved');
    table.onSelectedIdsChanged!({'draft-1'});
    await tester.pump();
    _table<ProductionDailyReportListItem>(
      tester,
    ).onFilterChanged('workshop', 'workshop-1');
    await tester.pumpAndSettle();
    table = _table<ProductionDailyReportListItem>(tester);
    expect(table.selectedIds, isEmpty);
    table.onSelectedIdsChanged!({'draft-1', 'draft-2'});
    await tester.pump();
    api.changedDailyStatus = 1;
    await _confirmDelete(tester);
    expect(api.detailReads, containsAll(['draft-1', 'draft-2']));
    expect(api.deletes, ['/production/daily-reports/draft-2']);
    expect(_table<ProductionDailyReportListItem>(tester).selectedIds, isEmpty);
    expect(badges.refreshCalls, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('expense selects only own drafts and sends checked versions', (
    tester,
  ) async {
    final api = _Api();
    final badges = await _mount(tester, _Kind.expense, api);
    var table = _table<ExpenseClaim>(tester);
    expect(table.selectable, isTrue);
    expect(table.idOf!(table.items[0]), 'draft-1');
    expect(table.idOf!(table.items[2]), isNull, reason: '驳回单不是可删除草稿');
    expect(table.idOf!(table.items[3]), isNull, reason: '不能选中他人草稿');
    table.onSelectedIdsChanged!({'draft-1'});
    await tester.pump();
    _table<ExpenseClaim>(tester).onFilterChanged('category', 'TRAVEL');
    await tester.pumpAndSettle();
    table = _table<ExpenseClaim>(tester);
    expect(table.selectedIds, isEmpty);
    table.onSelectedIdsChanged!({'draft-1', 'draft-2'});
    await tester.pump();
    await _confirmDelete(tester);
    expect(api.detailReads, ['draft-1', 'draft-2']);
    expect(api.deletes, [
      '/expense-claims/draft-1?expectedVersion=4',
      '/expense-claims/draft-2?expectedVersion=4',
    ]);
    expect(_table<ExpenseClaim>(tester).selectedIds, isEmpty);
    expect(badges.refreshCalls, greaterThan(0));
    expect(tester.takeException(), isNull);
  });

  testWidgets('daily delete rejects a draft outside the writable owner scope', (
    tester,
  ) async {
    final api = _Api()..dailyOwner = 'employee-2';
    await _mount(tester, _Kind.daily, api);
    _table<ProductionDailyReportListItem>(tester).onSelectedIdsChanged!({
      'draft-1',
    });
    await tester.pump();
    await _confirmDelete(tester);
    expect(api.detailReads, ['draft-1']);
    expect(api.deletes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final kind in [_Kind.daily, _Kind.expense]) {
    for (final changeIdentity in [false, true]) {
      testWidgets(
        '${kind.name} rechecks ${changeIdentity ? 'identity' : 'selection'} after detail GET',
        (tester) async {
          final api = _Api()..detailGate = Completer<void>();
          await _mount(tester, kind, api);
          if (kind == _Kind.daily) {
            _table<ProductionDailyReportListItem>(tester).onSelectedIdsChanged!(
              {'draft-1'},
            );
          } else {
            _table<ExpenseClaim>(tester).onSelectedIdsChanged!({'draft-1'});
          }
          await tester.pump();
          await _confirmDelete(tester);
          expect(api.detailReads, ['draft-1']);
          if (changeIdentity) {
            final element = kind == _Kind.daily
                ? tester.element(find.byType(ProductionDailyReportListPage))
                : tester.element(find.byType(ExpenseListPage));
            final container = ProviderScope.containerOf(element);
            (container.read(sessionProvider.notifier) as _Session).signOut();
          } else if (kind == _Kind.daily) {
            _table<ProductionDailyReportListItem>(
              tester,
            ).onFilterChanged('workshop', 'other');
          } else {
            _table<ExpenseClaim>(tester).onFilterChanged('category', 'TRAVEL');
          }
          await tester.pumpAndSettle();
          api.detailGate!.complete();
          await tester.pumpAndSettle();
          expect(api.deletes, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('expense version change is refused before destructive request', (
    tester,
  ) async {
    final api = _Api();
    await _mount(tester, _Kind.expense, api);
    _table<ExpenseClaim>(tester).onSelectedIdsChanged!({'draft-1'});
    await tester.pump();
    api.changedExpenseVersion = 5;
    await _confirmDelete(tester);
    expect(api.detailReads, ['draft-1']);
    expect(api.deletes, isEmpty);
    expect(_table<ExpenseClaim>(tester).selectedIds, {'draft-1'});
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ExpenseListPage)),
    );
    expect(
      container.read(appNotificationProvider).last.message,
      contains('报销单已被修改'),
    );
    expect(tester.takeException(), isNull);
  });
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  final deletes = <String>[];
  final batchCalls = <List<String>>[];
  final detailReads = <String>[];
  final removed = <String>{};
  int? changedDailyStatus;
  int? changedExpenseVersion;
  String dailyOwner = 'employee-1';
  Completer<void>? detailGate;

  Map<String, dynamic> _productionRow(String id, int status) => {
    'id': id,
    'billNo': 'SC-$id',
    'billDate': '2026-09-26',
    'status': id == 'draft-1' ? changedDailyStatus ?? status : status,
    'makerId': dailyOwner,
    'items': <Map<String, dynamic>>[],
  };

  Map<String, dynamic> _expenseRow(
    String id,
    String status, {
    String applicant = 'employee-1',
  }) => {
    'id': id,
    'claimNo': 'BX-$id',
    'applicantId': applicant,
    'applicantName': '测试员工',
    'title': '测试报销',
    'status': status,
    'totalAmount': 1,
    'version': id == 'draft-1' ? changedExpenseVersion ?? 4 : 4,
    'createdAt': '2026-09-26T12:00:00Z',
    'items': <Map<String, dynamic>>[],
  };

  Map<String, dynamic> _page(List<Map<String, dynamic>> rows) => {
    'items': rows.where((row) => !removed.contains(row['id'])).toList(),
    'page': 1,
    'size': 20,
    'total': rows.length - removed.length,
    'totalPages': 1,
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/production/plans' || path == '/production/daily-reports') {
      return _page([
        _productionRow('draft-1', 0),
        _productionRow('draft-2', 0),
        _productionRow('approved', 1),
      ]);
    }
    if (path == '/expense-claims/mine') {
      return _page([
        _expenseRow('draft-1', 'DRAFT'),
        _expenseRow('draft-2', 'DRAFT'),
        _expenseRow('rejected', 'REJECTED'),
        _expenseRow('foreign', 'DRAFT', applicant: 'employee-2'),
      ]);
    }
    if (path.startsWith('/production/daily-reports/draft-')) {
      final id = path.split('/').last;
      detailReads.add(id);
      await detailGate?.future;
      return _productionRow(id, 0);
    }
    if (path.startsWith('/expense-claims/draft-')) {
      final id = path.split('/').last;
      detailReads.add(id);
      await detailGate?.future;
      return _expenseRow(id, 'DRAFT');
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<void> delete(String path) async {
    deletes.add(path);
    removed.add(Uri.parse(path).pathSegments.last);
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path != '/production/plans/batch-delete') {
      throw StateError('unexpected post $path');
    }
    final ids = List<String>.from((body as Map)['ids'] as List);
    batchCalls.add(ids);
    removed.addAll(ids);
    return {
      'done': [
        for (final id in ids) {'id': id},
      ],
      'skipped': <Map<String, dynamic>>[],
    };
  }
}
