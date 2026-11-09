import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/buttons/uten_refresh_button.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/components/layout/uten_filter_toolbar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/pages/finance_applications_page.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(
      id: 'finance-user',
      employeeId: 'finance-employee',
      code: 'F001',
      name: '财务经办',
      department: '财务',
    ),
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());

  final List<({String path, Map<String, dynamic>? query})> queries = [];
  Completer<Map<String, dynamic>>? catalogGate, nextRows;
  bool catalogFails = false;
  int total = 1;
  final rowOwners = <bool Function()?>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    queries.add((path: path, query: query));
    if (path.endsWith('/catalog')) {
      if (catalogFails) throw StateError('catalog offline');
      if (catalogGate != null) return catalogGate!.future;
      return <String, dynamic>{};
    }
    rowOwners.add(PagedReadIntent.currentRead);
    if (nextRows case final pending?) {
      nextRows = null;
      return pending.future;
    }
    return <String, dynamic>{
      'rows': [
        for (
          var index = 0;
          index <
              (total -
                      (((query?['page'] as int? ?? 1) - 1) *
                          (query?['size'] as int? ?? 100)))
                  .clamp(0, query?['size'] as int? ?? 100);
          index++
        )
          {
            'id': 'fa-${query?['page']}-$index',
            'application_no': 'FK20261104${query?['page']}-$index',
            'kindLabel': '付款申请',
            'title': index == 0 ? '样例付款' : '分页样例-$index',
            'amount_original': '20.00',
            if (index == 0) 'currency_name': '美元',
            'status': 'PENDING',
          },
      ],
      'total': total,
      'page': query?['page'],
      'size': query?['size'],
    };
  }
}

Future<void> _pump(WidgetTester tester, _Api api) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        apiBaseUrlProvider.overrideWithValue('https://finance.test/api'),
        sharedPreferencesProvider.overrideWithValue(preferences),
        sessionProvider.overrideWith(_Session.new),
        currentPermissionsProvider.overrideWithValue({
          Perm.financeApplicationReview,
          Perm.financeApplicationApply,
        }),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: buildLightTheme(),
        home: const FinanceApplicationsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'slow or failed catalog never blocks rows or grants create from an old catalog',
    (tester) async {
      final api = _Api()..catalogGate = Completer<Map<String, dynamic>>();
      await _pump(tester, api);
      expect(find.text('样例付款'), findsOneWidget);
      UtenButton create() =>
          tester.widget<UtenButton>(find.widgetWithText(UtenButton, '新增'));
      expect(create().onPressed, isNull);
      api.catalogGate!.complete({'types': <dynamic>[]});
      await tester.pumpAndSettle();
      expect(create().onPressed, isNotNull);
      api.catalogFails = true;
      await tester.tap(find.widgetWithText(UtenButton, '刷新'));
      await tester.pumpAndSettle();
      expect(find.text('样例付款'), findsOneWidget);
      expect(create().onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'complete application rows reuse one catalog, scroll without reads, and retire the previous query',
    (tester) async {
      final api = _Api()..total = 90;
      await _pump(tester, api);
      expect(
        api.queries.where((q) => q.path.endsWith('/catalog')),
        hasLength(1),
      );
      expect(
        api.queries
            .where((q) => q.path == financeApplicationsApi)
            .map((q) => (q.query?['page'], q.query?['size'])),
        [
          (1, 50),
          (2, 50),
        ],
        reason: 'Ninety summaries stream as two aligned fifty-row batches',
      );
      final table = tester.widget<MasterDataTableView<Map<String, dynamic>>>(
        find.byType(MasterDataTableView<Map<String, dynamic>>),
      );
      expect(table.items, hasLength(90));
      final columns = table.columns.map((column) => column.key).toList();
      expect(columns[columns.indexOf('amount_original') + 1], 'currency');
      final currency = table.columns.singleWhere(
        (column) => column.key == 'currency',
      );
      expect(currency.value(table.items[0]), '美元');
      expect(currency.value(table.items[1]), isNull);
      expect(
        api.queries
            .lastWhere((query) => query.path == financeApplicationsApi)
            .query?['size'],
        50,
        reason: '读取按共享阶梯页大小透传，不再固定 100',
      );
      final reads = api.queries.length;
      final scroll = find
          .descendant(
            of: find.byType(MasterDataTableView<Map<String, dynamic>>),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.down,
            ),
          )
          .first;
      await tester.drag(scroll, const Offset(0, -500));
      await tester.pumpAndSettle();
      await tester.drag(scroll, const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(api.queries.length, reads);
      expect(
        find.byKey(const ValueKey('master-table-page-next')),
        findsNothing,
      );
      final pending = api.nextRows = Completer<Map<String, dynamic>>();
      final refreshingRows = Future<void>.sync(table.onRetry!);
      await tester.pump();
      final oldOwner = api.rowOwners.last!;
      expect(oldOwner(), true);
      final toolbar = tester.widget<UtenFilterToolbar<String>>(
        find.byType(UtenFilterToolbar<String>).first,
      );
      toolbar.onSelectionChanged!('history');
      await tester.pumpAndSettle();
      expect(oldOwner(), false);
      expect(
        api.queries.where((q) => q.path.endsWith('/catalog')),
        hasLength(1),
      );
      pending.complete({
        'rows': [
          {'id': 'old', 'title': '旧队列晚到'},
        ],
        'total': 1,
      });
      await refreshingRows;
      await tester.pumpAndSettle();
      expect(find.text('旧队列晚到'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'refresh sits in the app bar and the category row keeps only create',
    (tester) async {
      // 2026-11-04 刷新按钮归位：不再放分类栏行尾，与其他任务中心同位右上角
      // AppBar；行尾只保留「新增」。同时分类行进折叠头（上滑先把表格钉顶）。
      final api = _Api();
      await _pump(tester, api);
      final refresh = find.byType(UtenRefreshButton);
      expect(refresh, findsOneWidget);
      expect(
        find.ancestor(of: refresh, matching: find.byType(UtenAppBar)),
        findsOneWidget,
        reason: '刷新按钮应位于右上角 AppBar',
      );
      // 全页唯一的「刷新」按钮（AppBar 形态 UtenButton）就在 AppBar 里，
      // 分类栏行尾不再出现第二个。
      expect(
        find.widgetWithText(UtenButton, '刷新'),
        findsOneWidget,
        reason: '全页只保留一枚刷新按钮',
      );
      expect(
        find.descendant(
          of: find.byType(UtenAppBar),
          matching: find.widgetWithText(UtenButton, '刷新'),
        ),
        findsOneWidget,
        reason: '刷新按钮应位于右上角 AppBar，不在分类栏行内',
      );
      expect(find.widgetWithText(UtenButton, '新增'), findsOneWidget);
      expect(
        find.byType(UtenCollapsingHeaderScrollView),
        findsOneWidget,
        reason: '分类行应进折叠头，上滑先把表格钉顶',
      );
      expect(
        api.queries.where((q) => q.path == '/finance/applications'),
        isNotEmpty,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
