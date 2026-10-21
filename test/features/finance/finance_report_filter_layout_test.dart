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
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/utils/china_datetime.dart';
import 'package:uten_imp/features/finance/pages/finance_account_flow_page.dart';
import 'package:uten_imp/features/finance/pages/finance_ar_ap_page.dart';
import 'package:uten_imp/features/finance/pages/finance_reconciliation_page.dart';
import 'package:uten_imp/features/finance/pages/finance_report_table_page.dart';
import 'package:uten_imp/features/finance/pages/finance_statement_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_date_range_filter.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

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
  final pages = <String, Widget Function()>{
    'detail': () => const FinanceReportTablePage(cardId: 'detail'),
    'summary': () => const FinanceReportTablePage(cardId: 'summary'),
    'account-report': () => const FinanceAccountFlowPage(),
    'statement': () => const FinanceStatementPage(),
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
              variant.size.width < 600 ? variant.size.width : 180.1,
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

  testWidgets(
    'report preset and search update same request and preserve fixed direction',
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
      await tester.tap(find.byType(FinanceDateRangeFilter));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上月'));
      await tester.pumpAndSettle();
      final today = ChinaDateTime.today();
      expect(
        api.requests.last.$2['dateFrom'],
        ChinaDateTime.formatDate(DateTime.utc(today.year, today.month - 1)),
      );
      expect(
        api.requests.last.$2['dateTo'],
        ChinaDateTime.formatDate(DateTime.utc(today.year, today.month, 0)),
      );
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
      expect(
        api.requests.last.$2['dateFrom'],
        ChinaDateTime.formatDate(DateTime.utc(today.year, today.month - 1)),
      );
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
}) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api ?? _FilterApi()),
        sharedPreferencesProvider.overrideWithValue(preferences),
        currentPermissionsProvider.overrideWithValue(const {}),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: RepaintBoundary(
        key: capture,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: dark ? buildDarkTheme() : buildLightTheme(),
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
  _FilterApi() : super(Dio());
  final requests = <(String, Map<String, dynamic>)>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.startsWith('/finance/reports/')) {
      requests.add((path, Map.of(query ?? {})));
    }
    return {
      'columns': [
        {'key': 'billNo', 'label': '单据号', 'type': 'text'},
        {'key': 'amount', 'label': '金额', 'type': 'money'},
      ],
      'rows': <Object>[],
      'items': <Object>[],
      'facets': <String, dynamic>{},
      'page': 1,
      'total': 0,
      'totalPages': 1,
    };
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async =>
      const {};
}
