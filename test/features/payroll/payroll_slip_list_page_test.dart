import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/payroll/models/payroll_slip.dart';
import 'package:uten_imp/features/payroll/pages/payroll_slip_list_page.dart';
import 'package:uten_imp/features/payroll/providers/payroll_providers.dart';
import 'package:uten_imp/features/payroll/repositories/payroll_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _FakePayrollRepository extends Fake implements PayrollRepository {
  final List<Map<String, dynamic>> slipCalls = [];
  final headerCalls = <Map<String, dynamic>>[];

  @override
  Future<PagedResult<PayrollSlip>> listSlips({
    String? status,
    int page = 1,
    int size = 24,
    int? year,
    int? month,
    String? departmentId,
    Map<String, String?> columnSearch = const {},
    String? sort,
    String? order,
  }) async {
    slipCalls.add({'status': status, 'page': page});
    headerCalls.add({
      'status': status,
      'page': page,
      'size': size,
      'search': Map<String, String?>.of(columnSearch),
      'sort': sort,
      'order': order,
    });
    final statuses = switch (status) {
      'UNVIEWED' => [PayrollSlipStatus.published],
      'VIEWED' => [PayrollSlipStatus.viewed, PayrollSlipStatus.downloaded],
      'VIEWED_ONLY' => [PayrollSlipStatus.viewed],
      'DOWNLOADED' => [PayrollSlipStatus.downloaded],
      _ => throw StateError('Unexpected status $status'),
    };
    return PagedResult(
      items: [
        for (var i = (page - 1) * size; i < 50 && i < page * size; i++)
          PayrollSlip(
            id: 's-$status-$i',
            employeeId: 'emp-1',
            employeeName: '王小明',
            employeeCode: 'UT0001',
            year: 2026,
            month: 8,
            items: const [],
            grossIncome: 10000,
            totalDeduction: 2000,
            netIncome: 8000,
            status: statuses[i % statuses.length],
            publishedAt: DateTime(2026, 9, 1, 9),
          ),
      ],
      page: page,
      size: size,
      total: 50,
      totalPages: (50 / size).ceil(),
    );
  }
}

MasterDataTableView<PayrollSlip> _table(WidgetTester tester) =>
    tester.widget(find.byKey(const Key('payroll-slip-table')));

UtenFilterToolbar<PayrollFilter> _categories(WidgetTester tester) =>
    tester.widget(find.byKey(const Key('payroll-slip-categories')));

Future<_FakePayrollRepository> _pumpPage(
  WidgetTester tester, {
  double width = 1200,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues(const {});
  final preferences = await SharedPreferences.getInstance();
  final repo = _FakePayrollRepository();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        payrollRepositoryProvider.overrideWithValue(repo),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(
        theme: ThemeData(brightness: brightness),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const PayrollSlipListPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets(
    'personal salary headers query all pages with exact amounts and preserve the status category',
    (tester) async {
      final repository = await _pumpPage(tester);
      expect(_table(tester).items, hasLength(50));
      expect(_table(tester).items.last.id, 's-UNVIEWED-49');
      await _scrollWithoutRead(tester, repository);
      await tester.tap(
        find.byKey(const ValueKey('master-column-filter-netIncome')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('uten-column-keyword-input')),
        '>=8000',
      );
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(_table(tester).currentPage, 1);
      expect(
        repository.headerCalls.last['search'],
        containsPair('search.netIncome', '>=8000'),
      );
      _table(tester).onFilterChanged('search.period', '2026-08');
      await tester.pumpAndSettle();
      _table(tester).onSortChange!('period', false);
      await tester.pumpAndSettle();
      expect(
        repository.headerCalls.last['search'],
        containsPair('search.period', '2026-08'),
      );
      expect(repository.headerCalls.last['sort'], 'period');
      expect(repository.headerCalls.last['order'], 'desc');
      _categories(tester).onSelectionChanged!(PayrollFilter.viewed);
      await tester.pumpAndSettle();
      expect(repository.headerCalls.last['status'], 'VIEWED');
      expect(
        repository.headerCalls.last['search'],
        containsPair('search.netIncome', '>=8000'),
      );
      expect(_table(tester).currentPage, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'read category includes downloaded in its complete continuous list',
    (tester) async {
      final repo = await _pumpPage(tester);
      expect(repo.slipCalls.first, {'status': 'UNVIEWED', 'page': 1});
      expect(_table(tester).currentPage, 1);
      expect(repo.slipCalls.map((call) => call['page']), [1, 2, 3]);
      expect(_categories(tester).segments.map((segment) => segment.label), [
        '未查看',
        '已查看',
      ]);
      expect(_categories(tester).selected, {PayrollFilter.published});

      expect(_table(tester).items, hasLength(50));
      expect(_table(tester).items.last.id, 's-UNVIEWED-49');
      await _scrollWithoutRead(tester, repo);
      expect(
        repo.slipCalls.where((call) => call['page'] == 2),
        hasLength(1),
        reason:
            'the complete internal second batch is not re-read on scrolling',
      );

      final beforeCategoryChange = repo.slipCalls.length;
      _categories(tester).onSelectionChanged!(PayrollFilter.viewed);
      await tester.pumpAndSettle();
      expect(repo.slipCalls.skip(beforeCategoryChange), [
        for (final page in [1, 2, 3]) {'status': 'VIEWED', 'page': page},
      ]);
      expect(_table(tester).currentPage, 1);
      expect(_table(tester).items, hasLength(50));
      expect(_table(tester).items.map((slip) => slip.status).toSet(), {
        PayrollSlipStatus.viewed,
        PayrollSlipStatus.downloaded,
      });
      expect(_table(tester).items.last.id, 's-VIEWED-49');
      expect(_table(tester).filters['status'], isNull);
      expect(_table(tester).facets['status']!.map((bucket) => bucket.value), [
        'viewed',
        'downloaded',
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('status detail and clear stay in the visible category', (
    tester,
  ) async {
    final repo = await _pumpPage(tester);
    _table(tester).onFilterChanged('status', null);
    await tester.pumpAndSettle();
    expect(repo.slipCalls.last['status'], 'UNVIEWED');

    _categories(tester).onSelectionChanged!(PayrollFilter.viewed);
    await tester.pumpAndSettle();
    var beforeFilterChange = repo.slipCalls.length;
    _table(tester).onFilterChanged('status', 'downloaded');
    await tester.pumpAndSettle();
    expect(repo.slipCalls.skip(beforeFilterChange), [
      for (final page in [1, 2, 3]) {'status': 'DOWNLOADED', 'page': page},
    ]);
    expect(_table(tester).currentPage, 1);
    expect(_table(tester).items, hasLength(50));
    expect(
      _table(
        tester,
      ).items.every((slip) => slip.status == PayrollSlipStatus.downloaded),
      isTrue,
    );
    expect(_categories(tester).selected, {PayrollFilter.viewed});
    expect(_table(tester).filters['status'], 'downloaded');

    await _scrollWithoutRead(tester, repo);
    beforeFilterChange = repo.slipCalls.length;
    _table(tester).onFilterChanged('status', null);
    await tester.pumpAndSettle();
    expect(repo.slipCalls.skip(beforeFilterChange), [
      for (final page in [1, 2, 3]) {'status': 'VIEWED', 'page': page},
    ]);
    expect(_table(tester).currentPage, 1);
    expect(_categories(tester).selected, {PayrollFilter.viewed});
    expect(_table(tester).filters['status'], isNull);

    beforeFilterChange = repo.slipCalls.length;
    _table(tester).onFilterChanged('status', 'viewed');
    await tester.pumpAndSettle();
    expect(repo.slipCalls.skip(beforeFilterChange), [
      for (final page in [1, 2, 3]) {'status': 'VIEWED_ONLY', 'page': page},
    ]);
    expect(_table(tester).currentPage, 1);
    expect(_table(tester).items, hasLength(50));
    expect(
      _table(
        tester,
      ).items.every((slip) => slip.status == PayrollSlipStatus.viewed),
      isTrue,
    );
    expect(_categories(tester).selected, {PayrollFilter.viewed});
    expect(_table(tester).filters['status'], 'viewed');
    beforeFilterChange = repo.slipCalls.length;
    _categories(tester).onSelectionChanged!(PayrollFilter.published);
    await tester.pumpAndSettle();
    expect(repo.slipCalls.skip(beforeFilterChange), [
      for (final page in [1, 2, 3]) {'status': 'UNVIEWED', 'page': page},
    ]);
    expect(_table(tester).currentPage, 1);
    expect(_table(tester).items, hasLength(50));
    expect(
      _table(
        tester,
      ).items.every((slip) => slip.status == PayrollSlipStatus.published),
      isTrue,
    );
    expect(_table(tester).filters['status'], isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [390.0, 1200.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'category is below title at $width $brightness and 200% text',
        (tester) async {
          await _pumpPage(
            tester,
            width: width,
            textScale: 2,
            brightness: brightness,
          );
          final appBar = tester.widget<UtenAppBar>(find.byType(UtenAppBar));
          expect(appBar.centerWidget, isNull);
          expect(
            tester
                .getTopLeft(find.byKey(const Key('payroll-slip-categories')))
                .dy,
            greaterThanOrEqualTo(
              tester.getBottomLeft(find.byType(UtenAppBar)).dy,
            ),
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}

Future<void> _scrollWithoutRead(
  WidgetTester tester,
  _FakePayrollRepository repository,
) async {
  final beforeScroll = repository.slipCalls.length;
  await tester.drag(
    find.byKey(const Key('payroll-slip-table')),
    const Offset(0, -700),
  );
  await tester.pumpAndSettle();
  expect(repository.slipCalls, hasLength(beforeScroll));
  expect(_table(tester).currentPage, 1);
  expect(_table(tester).totalPages, 1);
  expect(find.byKey(const ValueKey('master-table-page-next')), findsNothing);
}
