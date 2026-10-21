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
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';
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
    testWidgets('${layout.name}: both restrictions leave filters reachable', (
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
      final more = find.byKey(
        const Key('finance-asset-more-filters-FIXED_ASSET'),
      );
      if (more.evaluate().isNotEmpty) {
        await tester.ensureVisible(more);
        await tester.tap(more);
        await tester.pumpAndSettle();
      }
      final filters = <Finder>[
        search,
        find.byKey(const Key('asset-status-FIXED_ASSET-null')),
        find.byKey(const Key('asset-category-filter-FIXED_ASSET-null')),
        find.byType(UtenDepartmentPicker),
      ];
      for (final filter in filters.skip(1)) {
        expect(filter, findsOneWidget);
        await tester.ensureVisible(filter);
        await tester.pumpAndSettle();
        expect(filter.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'revealing $filter');
      }
      if (more.evaluate().isNotEmpty) {
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
      }

      if (layout.size.width >= 1280 && layout.scale == 1) {
        final search = tester.getRect(filters[0]);
        final category = tester.getRect(filters[2]);
        expect(
          (search.top - category.top).abs(),
          lessThan(30),
          reason: 'desktop filters should share a row instead of a tall stack',
        );
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

  testWidgets('compact filters apply once and cancellation discards draft', (
    tester,
  ) async {
    final repository = _LayoutAssetRepository();
    await _pump(tester, layout: _layouts[3], repository: repository);
    final before = repository.queries.length;
    final more = find.byKey(
      const Key('finance-asset-more-filters-FIXED_ASSET'),
    );
    await tester.ensureVisible(more);
    await tester.tap(more);
    await tester.pumpAndSettle();
    final status = find.byKey(const Key('asset-status-FIXED_ASSET-null'));
    tester.widget<UtenDropdownField>(status).onChanged('PENDING_APPROVAL');
    await tester.pumpAndSettle();
    expect(repository.queries.length, before);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(repository.queries.length, before);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(tester.widget<UtenDropdownField>(status).value, isNull);
    tester.widget<UtenDropdownField>(status).onChanged('PENDING_APPROVAL');
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    final applied = repository.queries.skip(before).toList();
    expect(applied.first.status, 'PENDING_APPROVAL');
    expect(applied.first.page, 1);
    expect(applied.where((query) => query.size != 1), hasLength(1));
    expect(tester.takeException(), isNull);
  });

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
        financeAssetCategoryRepositoryProvider.overrideWithValue(
          _LayoutCategoryRepository(),
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
  @override
  Future<List<FinanceAssetCategory>> list(
    FinanceAssetLedger objectType,
  ) async => const [];

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
