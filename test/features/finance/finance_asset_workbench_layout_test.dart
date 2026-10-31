import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/finance/models/finance_asset_category_models.dart';
import 'package:uten_imp/features/finance/models/finance_asset_models.dart';
import 'package:uten_imp/features/finance/pages/finance_asset_workbench_page.dart';
import 'package:uten_imp/features/finance/repositories/finance_asset_category_repository.dart';
import 'package:uten_imp/features/finance/repositories/finance_asset_overview_repository.dart';
import 'package:uten_imp/features/finance/repositories/finance_asset_workbench_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

typedef _LayoutCase = ({String name, Size size, double scale, bool dark});

const _layouts = <_LayoutCase>[
  (name: 'desktop-1920', size: Size(1920, 945), scale: 1, dark: false),
  (name: 'desktop-1280', size: Size(1280, 900), scale: 1, dark: false),
  (name: 'tablet-720', size: Size(720, 900), scale: 1, dark: false),
  (name: 'mobile-360', size: Size(360, 800), scale: 1, dark: false),
  (name: 'landscape-844', size: Size(844, 390), scale: 1, dark: false),
  (name: 'desktop-large-dark', size: Size(1280, 900), scale: 1.5, dark: true),
  (name: 'mobile-large-dark', size: Size(360, 800), scale: 1.5, dark: true),
  (name: 'landscape-large-dark', size: Size(844, 390), scale: 1.5, dark: true),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSC.ttf'))).load();
  });

  for (final layout in _layouts) {
    testWidgets('${layout.name}: only header filters remain reachable', (
      tester,
    ) async {
      final capture = GlobalKey();
      await _pump(tester, layout: layout, capture: capture);

      expect(tester.takeException(), isNull, reason: 'initial layout');
      expect(find.byKey(const Key('finance-asset-sections')), findsOneWidget);
      expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
      final create = find.byKey(const Key('finance-asset-create-FIXED_ASSET'));
      expect(create, findsOneWidget);
      expect(find.text('新建固定资产'), findsOneWidget);
      expect(create.hitTestable(), findsOneWidget);
      await _capture(tester, capture, layout.name);

      final search = find.byKey(const Key('asset-search-FIXED_ASSET'));
      if (search.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          search,
          100,
          scrollable: find
              .descendant(
                of: find.byType(UtenCollapsingHeaderScrollView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
      }
      await tester.ensureVisible(search);
      await tester.pumpAndSettle();
      expect(search.hitTestable(), findsOneWidget);
      expect(find.text('重置筛选'), findsNothing);
      expect(find.byType(UtenDepartmentPicker), findsNothing);
      expect(
        find.byKey(const Key('finance-asset-more-filters-FIXED_ASSET')),
        findsNothing,
      );
      for (final column in ['status', 'categoryName', 'departmentName']) {
        final header = find.byKey(ValueKey('master-column-filter-$column'));
        expect(header, findsOneWidget);
        await tester.ensureVisible(header);
        await tester.pumpAndSettle();
        expect(header.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'revealing $column');
      }
    });
  }

  testWidgets('ledger navigation retains exactly one create action', (
    tester,
  ) async {
    final repository = _LayoutAssetRepository();
    await _pump(tester, layout: _layouts.first, repository: repository);
    await tester.tap(find.text('长期待摊'));
    await tester.pumpAndSettle();

    expect(find.text('新建固定资产'), findsNothing);
    expect(find.text('新建长期待摊'), findsOneWidget);
    expect(find.byType(UtenFloatingActionGroup), findsOneWidget);
    expect(repository.ledgers, contains(FinanceAssetLedger.deferredExpense));

    await tester.tap(find.text('固定资产'));
    await tester.pumpAndSettle();
    expect(find.text('新建固定资产'), findsOneWidget);
    expect(find.text('新建长期待摊'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fullscreen keeps search and exactly one create entry', (
    tester,
  ) async {
    await _pump(tester, layout: _layouts.first);
    final search = find.descendant(
      of: find.byKey(const Key('asset-search-FIXED_ASSET')),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, '设备');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('master-table-fullscreen-toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('finance-asset-create-FIXED_ASSET')),
      findsNothing,
    );
    expect(
      find
          .byKey(const Key('finance-asset-create-fullscreen-FIXED_ASSET'))
          .hitTestable(),
      findsOneWidget,
    );
    expect(find.text('新建固定资产'), findsOneWidget);
    expect(tester.widget<TextField>(search).controller!.text, '设备');
    await tester.tap(find.byKey(const Key('master-table-fullscreen-toggle')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('finance-asset-create-FIXED_ASSET')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('finance-asset-create-fullscreen-FIXED_ASSET')),
      findsNothing,
    );
    expect(tester.widget<TextField>(search).controller!.text, '设备');
    expect(tester.takeException(), isNull);
  });

  for (final layout in [_layouts.first, _layouts[3]]) {
    for (final ledger in FinanceAssetLedger.values) {
      testWidgets('${layout.name}: ${ledger.name} filters through headers', (
        tester,
      ) async {
        final repository = _LayoutAssetRepository();
        final categories = _LayoutCategoryRepository();
        await _pump(
          tester,
          layout: layout,
          repository: repository,
          categories: categories,
        );
        if (ledger == FinanceAssetLedger.deferredExpense) {
          await tester.tap(find.text('长期待摊'));
          await tester.pumpAndSettle();
        }
        final search = find.descendant(
          of: find.byKey(Key('asset-search-${ledger.apiValue}')),
          matching: find.byType(TextField),
        );
        await tester.ensureVisible(search);
        await tester.enterText(search, '设备');
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();

        Future<void> openHeader(String column) async {
          final header = find.byKey(ValueKey('master-column-filter-$column'));
          await tester.ensureVisible(header);
          await tester.pumpAndSettle();
          await tester.tap(header);
          await tester.pumpAndSettle();
        }

        FinanceAssetQuery lastQuery() =>
            repository.queries.where((query) => query.size != 1).last;

        await openHeader('status');
        await tester.tap(find.text('待审批').last);
        await tester.pumpAndSettle();
        expect(lastQuery().status, 'PENDING_APPROVAL');
        expect(lastQuery().q, '设备');
        expect(lastQuery().page, 1);

        categories.failNext = true;
        await openHeader('categoryName');
        final retry = find.text('候选加载失败，点击重试');
        expect(retry, findsOneWidget);
        await tester.tap(retry);
        await tester.pumpAndSettle();
        await tester.tap(find.text('CAT · 设备分类'));
        await tester.pumpAndSettle();
        expect(lastQuery().categoryId, 'category-id');
        expect(lastQuery().status, 'PENDING_APPROVAL');

        final beforeDepartment = repository.queries.length;
        await openHeader('departmentName');
        await tester.tap(find.text('财税部').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        expect(repository.queries.length, beforeDepartment);
        await openHeader('departmentName');
        await tester.tap(find.text('财税部').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('确定').last);
        await tester.pumpAndSettle();
        expect(lastQuery().departmentId, 'department-id');
        expect(lastQuery().categoryId, 'category-id');

        for (final column in ['status', 'categoryName']) {
          await openHeader(column);
          await tester.tap(find.text('所有').last);
          await tester.pumpAndSettle();
        }
        expect(lastQuery().status, isNull);
        expect(lastQuery().categoryId, isNull);
        expect(lastQuery().departmentId, 'department-id');
        expect(lastQuery().q, '设备');
        await openHeader('departmentName');
        await tester.tap(find.text('清空').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消').last);
        await tester.pumpAndSettle();
        expect(lastQuery().departmentId, 'department-id');
        await openHeader('departmentName');
        await tester.tap(find.text('清空').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('确定').last);
        await tester.pumpAndSettle();
        expect(lastQuery().departmentId, isNull);
        expect(lastQuery().q, '设备');
        expect(find.text('重置筛选'), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'restriction details preserve policy and operational distinction',
    (tester) async {
      await _pump(tester, layout: _layouts[1]);
      final toggle = find.byKey(const Key('finance-asset-restrictions-toggle'));
      expect(toggle, findsOneWidget);
      await tester.tap(toggle);
      await tester.pumpAndSettle();

      expect(find.textContaining('固定资产类别政策'), findsOneWidget);
      expect(find.textContaining('长期待摊费用类别政策'), findsOneWidget);
      expect(find.textContaining('CATEGORY_POLICY'), findsNothing);
      expect(find.textContaining('BUSINESS_EVENT_REVERSAL'), findsNothing);
      expect(
        find.byKey(const Key('finance-asset-configure-policy')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('read-only ledger has no create or policy configuration action', (
    tester,
  ) async {
    await _pump(tester, layout: _layouts[3], readOnly: true);
    expect(find.text('新建固定资产'), findsNothing);
    expect(find.byType(UtenFloatingActionGroup), findsNothing);
    expect(
      find.byKey(const Key('finance-asset-configure-policy')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required _LayoutCase layout,
  GlobalKey? capture,
  _LayoutAssetRepository? repository,
  _LayoutCategoryRepository? categories,
  bool readOnly = false,
}) async {
  tester.view.physicalSize = layout.size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWith(
          (ref) => {
            Perm.financeAssetView,
            if (!readOnly) ...[Perm.financeAssetEdit, Perm.financeAssetApprove],
          },
        ),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
        financeAssetWorkbenchRepositoryProvider.overrideWithValue(
          repository ?? _LayoutAssetRepository(),
        ),
        financeAssetOverviewRepositoryProvider.overrideWithValue(
          _LayoutOverviewRepository(),
        ),
        departmentPickerTreeProvider.overrideWith(
          (ref) async => [
            DepartmentNode(
              id: 'department-id',
              code: 'DEPT_FIN',
              name: '财税部',
              level: '一级部门',
              children: [],
            ),
          ],
        ),
        financeAssetCategoryRepositoryProvider.overrideWithValue(
          categories ?? _LayoutCategoryRepository(),
        ),
      ],
      child: RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildLightTheme(),
          darkTheme: buildDarkTheme(),
          themeMode: layout.dark ? ThemeMode.dark : ThemeMode.light,
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(layout.scale)),
            child: child!,
          ),
          home: const FinanceAssetWorkbenchPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  if (!const bool.fromEnvironment('UI_CAPTURE')) return;
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final picture = await boundary.toImage();
    final data = await picture.toByteData(format: ui.ImageByteFormat.png);
    final file = File('output/asset-workbench-redesign/previews/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(data!.buffer.asUint8List());
    picture.dispose();
  });
}

class _LayoutOverviewRepository implements FinanceAssetOverviewRepository {
  @override
  Future<FinanceAssetWorkbenchOverview> load() async =>
      const FinanceAssetWorkbenchOverview(
        metrics: FinanceAssetOverview(
          originalValue: '100000.00',
          netBookValue: '82000.00',
          deferredBalance: '21000.00',
          pendingOrExceptionCount: 2,
        ),
        policyReady: false,
        missingPolicyItems: [
          'FIXED_ASSET_CATEGORY_POLICY',
          'DEFERRED_EXPENSE_CATEGORY_POLICY',
        ],
        postedWorkflowsEnabled: false,
        operationalBlockers: ['BUSINESS_EVENT_REVERSAL_NOT_READY'],
      );
}

class _LayoutCategoryRepository implements FinanceAssetCategoryRepository {
  bool failNext = false;

  @override
  Future<List<FinanceAssetCategory>> list(FinanceAssetLedger objectType) async {
    if (failNext) {
      failNext = false;
      throw StateError('category load failed');
    }
    return [
      FinanceAssetCategory.fromJson({
        'id': 'category-id',
        'objectType': objectType.apiValue,
        'code': 'CAT',
        'name': '设备分类',
      }),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _LayoutAssetRepository implements FinanceAssetWorkbenchRepository {
  final ledgers = <FinanceAssetLedger>[];
  final queries = <FinanceAssetQuery>[];

  @override
  Future<PagedResult<FinanceAssetSummary>> list(
    FinanceAssetLedger ledger, {
    FinanceAssetQuery query = const FinanceAssetQuery(),
  }) async {
    ledgers.add(ledger);
    queries.add(query);
    return PagedResult(
      items: const [],
      page: query.page,
      size: query.size,
      total: 0,
      totalPages: 1,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
