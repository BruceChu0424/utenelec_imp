import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/feedback/uten_date_range_picker.dart';
import 'package:uten_imp/components/buttons/uten_date_range_selection_button.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_table_action_scope.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/features/finance/pages/finance_account_flow_page.dart';
import 'package:uten_imp/features/finance/pages/finance_ar_ap_page.dart';
import 'package:uten_imp/features/finance/pages/finance_reconciliation_page.dart';
import 'package:uten_imp/features/finance/pages/finance_report_table_page.dart';
import 'package:uten_imp/features/finance/pages/finance_statement_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_date_range_filter.dart';
import 'package:uten_imp/features/report/shared/report_filter_prefs.dart';
import 'package:uten_imp/features/purchase/config/purchase_report_config.dart';
import 'package:uten_imp/features/purchase/pages/purchase_report_table_page.dart';
import 'package:uten_imp/features/sales/pages/sales_report_page.dart';
import 'package:uten_imp/features/sales/config/sales_report_config.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_report_table_page.dart';
import 'package:uten_imp/features/subcontract/config/subcontract_report_config.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_report_table_page.dart';
import 'package:uten_imp/features/warehouse/config/warehouse_report_config.dart';
import 'package:uten_imp/features/production/pages/production_report_page.dart';
import 'package:uten_imp/features/production/config/production_report_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../support/audit_screenshot_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader(
      'NotoSansSC',
    )..addFont(rootBundle.load('assets/fonts/NotoSansSCFull.ttf'))).load();
  });
  final pages = <String, Widget Function()>{
    'detail': () => const FinanceReportTablePage(cardId: 'detail'),
    'summary': () => const FinanceReportTablePage(cardId: 'summary'),
    'account-report': () => const FinanceAccountFlowPage(),
    'statement': () => const FinanceStatementPage(),
    'purchase-report': () =>
        const PurchaseReportTablePage(kind: PurchaseReportKind.detail),
    'ar-ap-ledger': () => const FinanceArApPage(),
    'account-ledger': () => const FinanceReconciliationPage(),
  };
  for (final page in pages.entries) {
    testWidgets(
      '${page.key} keeps short search with classifications across viewports',
      (tester) async {
        for (final variant in [
          (size: const Size(1920, 945), scale: 1.0, dark: false),
          (size: const Size(720, 900), scale: 1.0, dark: false),
          (size: const Size(360, 800), scale: 1.5, dark: true),
          (size: const Size(844, 390), scale: 1.5, dark: true),
        ]) {
          await tester.binding.setSurfaceSize(variant.size);
          final capture = GlobalKey();
          await _pump(
            tester,
            page.value(),
            scale: variant.scale,
            dark: variant.dark,
            capture: capture,
            viewport: variant.size,
          );
          expect(
            tester.takeException(),
            isNull,
            reason: '${page.key} ${variant.size}',
          );
          final search = find.byType(UtenSearchBar);
          expect(search, findsOneWidget);
          expect(
            tester.getSize(search).width,
            lessThanOrEqualTo(
              page.key == 'purchase-report' || variant.size.width < 600
                  ? variant.size.width
                  : 180.1,
            ),
          );
          expect(
            find.ancestor(
              of: search,
              matching: find.byWidgetPredicate(
                (widget) => widget is UtenFilterToolbar,
              ),
            ),
            findsOneWidget,
          );
          for (final element
              in find.byType(UtenDateRangeSelectionButton).evaluate()) {
            expect(
              find.ancestor(
                of: find.byWidget(element.widget),
                matching: find.byType(UtenTableActionScope),
              ),
              findsOneWidget,
            );
          }
          if (const bool.fromEnvironment('UI_CAPTURE')) {
            await _capture(
              tester,
              capture,
              '${page.key}-${variant.size.width.toInt()}-${variant.scale}',
            );
          }
          await tester.ensureVisible(search);
          await tester.pumpAndSettle();
          expect(search.hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
        await tester.binding.setSurfaceSize(null);
      },
    );
  }

  for (final report in <String, Widget Function()>{
    'finance': () => const FinanceReportTablePage(cardId: 'summary'),
    'purchase': () =>
        const PurchaseReportTablePage(kind: PurchaseReportKind.detail),
    'sales': () => const SalesReportPage(kind: SalesReportKind.detail),
    'subcontract': () =>
        const SubcontractReportTablePage(kind: SubcontractReportKind.detail),
    'warehouse': () =>
        const WarehouseReportTablePage(kind: WarehouseReportKind.detail),
    'production': () =>
        const ProductionReportPage(kind: ProductionReportKind.detail),
  }.entries) {
    testWidgets('${report.key}首次无元数据失败后可在原工具栏改日期恢复', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _FilterApi(failFirstReport: true);
      await _pump(tester, report.value(), api: api);
      expect(api.requests, hasLength(1));
      final date = find.byType(UtenDateRangeSelectionButton);
      expect(date, findsOneWidget);
      expect(
        find.ancestor(of: date, matching: find.byType(UtenTableActionScope)),
        findsOneWidget,
      );
      await tester.ensureVisible(date);
      await tester.tap(
        find.descendant(of: date, matching: find.byType(UtenButton)).first,
      );
      await tester.pumpAndSettle();
      Navigator.of(
        tester.element(find.byType(UtenDateRangePickerDialog)),
      ).pop((start: DateTime(2026, 10), end: DateTime(2026, 10, 2)));
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(2));
      expect(api.requests.last.$2['dateFrom'], '2026-10-01');
      expect(api.requests.last.$2['dateTo'], '2026-10-02');
      expect(find.text('XD202611030001'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'report calendar and search update same request and preserve fixed direction',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1920, 945));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final api = _FilterApi();
      await _pump(
        tester,
        const FinanceReportTablePage(cardId: 'summary'),
        api: api,
      );
      final initial = api.requests.last;
      expect(initial.$2['direction'], 'AR');
      final requestsBefore = api.requests.length;
      await tester.tap(find.byType(FinanceDateRangeFilter));
      await tester.pumpAndSettle();
      final today = ChinaDateTime.today();
      final start = DateTime.utc(today.year, today.month - 1);
      final end = DateTime.utc(today.year, today.month, 0);
      await tester.tap(find.byKey(const Key('uten-calendar-month-year')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey<int>(start.year)));
      await tester.pumpAndSettle();
      final month = find.byKey(ValueKey('uten-calendar-month-${start.month}'));
      await tester.ensureVisible(month);
      await tester.tap(month.hitTestable());
      await tester.pumpAndSettle();
      final calendar = find.byType(UtenDateRangePickerDialog);
      await tester.tap(find.descendant(of: calendar, matching: find.text('1')));
      await tester.tap(
        find.descendant(of: calendar, matching: find.text('${end.day}')),
      );
      expect(api.requests.length, requestsBefore);
      await tester.tap(
        find.descendant(of: calendar, matching: find.text('确定')),
      );
      await tester.pumpAndSettle();
      expect(api.requests.last.$2['dateFrom'], ChinaDateTime.formatDate(start));
      expect(api.requests.last.$2['dateTo'], ChinaDateTime.formatDate(end));
      expect(api.requests.last.$2['direction'], 'AR');
      expect(api.requests.last.$2['page'], 1);
      await tester.enterText(
        find.descendant(
          of: find.byType(UtenSearchBar),
          matching: find.byType(TextField),
        ),
        '客户 01',
      );
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(api.requests.last.$2['keyword'], '客户 01');
      expect(api.requests.last.$2['dateFrom'], ChinaDateTime.formatDate(start));
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _pump(
  WidgetTester tester,
  Widget page, {
  double scale = 1,
  bool dark = false,
  _FilterApi? api,
  GlobalKey? capture,
  Size viewport = const Size(1920, 945),
}) async {
  await tester.binding.setSurfaceSize(viewport);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = viewport;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api ?? _FilterApi()),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.financeReportView,
          Perm.financeReportExport,
          Perm.financeViewAll,
          Perm.purchaseReportExport,
        }),
        if (page is FinanceStatementPage)
          financeStatementReportPrefsProvider.overrideWith(_StatementPrefs.new),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: const bool.fromEnvironment('UI_CAPTURE')
              ? auditScreenshotTheme(
                  (dark ? buildDarkTheme() : buildLightTheme()).copyWith(
                    platform: TargetPlatform.windows,
                  ),
                )
              : dark
              ? buildDarkTheme()
              : buildLightTheme(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: page,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final rendered = await boundary.toImage();
    final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
    final folder = Directory('output/finance-redesign/previews');
    await folder.create(recursive: true);
    await File(
      '${folder.path}/reports-$name.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    rendered.dispose();
  });
}

class _FilterApi extends ApiClient {
  _FilterApi({this.failFirstReport = false}) : super(Dio());
  final bool failFirstReport;
  final requests = <(String, Map<String, dynamic>)>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('/reports/')) {
      requests.add((path, Map.of(query ?? {})));
      if (failFirstReport && requests.length == 1) {
        throw NetworkTimeoutException();
      }
    }
    return {
      'columns': [
        {'key': 'billNo', 'label': '单据号', 'type': 'text'},
        {'key': 'amount', 'label': '金额', 'type': 'money'},
      ],
      'rows': [
        {'billNo': 'XD202611030001', 'amount': '12345.67'},
        {'billNo': 'SK202611030002', 'amount': '2345.67'},
      ],
      'items': <Object>[],
      'facets': <String, dynamic>{},
      'page': 1,
      'total': 2,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path.endsWith('/lookup')
      ? [
          {
            'id': '00000000-0000-0000-0000-000000000123',
            'name': '安信照明有限公司',
            'code': 'KH000123',
          },
        ]
      : const [];

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async =>
      const {};
}

class _StatementPrefs extends FinanceStatementReportPrefsNotifier {
  @override
  ReportFilterPrefs build() => const ReportFilterPrefs(
    docType: 'AR',
    extra: {'partyId': '00000000-0000-0000-0000-000000000123'},
  );

  @override
  void update(ReportFilterPrefs value) => state = value;
}
