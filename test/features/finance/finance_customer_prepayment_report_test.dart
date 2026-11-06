import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_date_range_selection_button.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_client_picker.dart';
import 'package:uten_imp/features/finance/config/finance_report_config.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/finance/pages/finance_report_table_page.dart';
import 'package:uten_imp/features/finance/widgets/finance_date_range_filter.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import '../../support/table_read_status.dart';
import '../../support/versioned_summary_test_response.dart';

late SharedPreferences _preferences;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _preferences = await SharedPreferences.getInstance();
  });
  testWidgets(
    'prepayment history can select a hidden customer and query its original UUID',
    (tester) async {
      final api = _ReportApi();
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _reportApp(api, extraPermissions: {Perm.clientView}),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ClientPickerField));
      await tester.pumpAndSettle();
      expect(api.candidateQueries.single['selectableOnly'], isNot(true));
      await tester.tap(find.text('已隐藏历史客户'));
      await tester.pump();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(api.lastQuery?['clientId'], 'hidden-customer');
      expect(
        tester
            .widget<ClientPickerField>(find.byType(ClientPickerField))
            .initialName,
        '已隐藏历史客户',
      );
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'report config and route use exact endpoint and compound permissions',
    () {
      final card = financeReportCardById('customer-prepayment');
      expect(card.title, '客户预收流水');
      expect(card.variants.single.label, '客户预收流水');
      expect(
        card.variants.single.endpoint,
        '/finance/reports/customer-prepayment/events',
      );
      expect(
        requiredAnyPermFor(RouteName.financeReportCustomerPrepayment),
        const [Perm.financeReportView],
      );
      expect(
        requiredAllPermsFor(RouteName.financeReportCustomerPrepayment),
        const [
          Perm.financeReportView,
          Perm.customerPrepaymentView,
          Perm.financeViewAll,
        ],
      );
    },
  );

  testWidgets('375px report shows client/date filters and server columns', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _ReportApi();

    await tester.pumpWidget(_reportApp(api));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('客户预收流水'), findsWidgets);
    expect(find.byType(ClientPickerField), findsOneWidget);
    expect(find.byType(FinanceDateRangeFilter), findsOneWidget);
    final dates = tester.widget<UtenDateRangeSelectionButton>(
      find.descendant(
        of: find.byType(FinanceDateRangeFilter),
        matching: find.byType(UtenDateRangeSelectionButton),
      ),
    );
    expect(dates.from, isNotNull);
    expect(dates.to, isNotNull);
    expect(find.text('搜索'), findsNothing);
    expect(find.text('记账日期'), findsOneWidget);
    expect(find.text('资金单号'), findsOneWidget);
    expect(find.text('事件类型'), findsOneWidget);
    expect(find.text('预收现金(原币)'), findsOneWidget);
    expect(find.text('转销应收(原币)'), findsOneWidget);
    expect(find.text('汇兑差额'), findsOneWidget);
    expect(find.text('预收到账'), findsOneWidget);
    expect(find.text('YS-001'), findsOneWidget);
    expect(api.reportCalls, 1);
    expect(api.lastQuery?['dateFrom'], isNotNull);
    expect(api.lastQuery?['dateTo'], isNotNull);
    expect(api.lastQuery?.containsKey('keyword'), isFalse);

    final picker = tester.widget<ClientPickerField>(
      find.byType(ClientPickerField),
    );
    picker.onChanged('client-1');
    await tester.pumpAndSettle();
    expect(api.lastQuery?['clientId'], 'client-1');
  });

  testWidgets('report shows inline error and retry', (tester) async {
    final api = _ReportApi(fail: true);
    await tester.pumpWidget(_reportApp(api));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(FinanceReportTablePage)),
    );
    await expectTableReadFailureDetails(tester, l10n.financeReportLoadFailed);
    expect(find.text('重试'), findsOneWidget);
    api.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('YS-001'), findsOneWidget);
  });

  testWidgets('report preserves an explicit server rejection reason', (
    tester,
  ) async {
    const message = '当前账号不可查看该客户的预收流水';
    final api = _ReportApi(
      fail: true,
      failure: ApiException('FORBIDDEN', message, httpStatus: 403),
    );
    await tester.pumpWidget(_reportApp(api));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(FinanceReportTablePage)),
    );
    await expectTableReadFailureDetails(tester, message);
    expect(find.text(l10n.financeReportLoadFailed), findsNothing);
    expect(find.text('重试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finance hub hides report until every permission is present', (
    tester,
  ) async {
    await tester.pumpWidget(_hubApp(const {Perm.financeReportView}));
    await tester.pump();
    expect(find.text('客户预收流水'), findsNothing);

    await tester.pumpWidget(
      _hubApp(const {
        Perm.financeReportView,
        Perm.customerPrepaymentView,
        Perm.financeViewAll,
      }),
    );
    await tester.pump();
    expect(find.text('客户预收流水'), findsOneWidget);
  });
}

Widget _reportApp(_ReportApi api, {Set<String> extraPermissions = const {}}) =>
    ProviderScope(
      overrides: [
        localServerReachableProvider.overrideWith(
          (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
        ),
        sharedPreferencesProvider.overrideWithValue(_preferences),
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue({
          Perm.financeReportView,
          Perm.customerPrepaymentView,
          Perm.financeViewAll,
          ...extraPermissions,
        }),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: FinanceReportTablePage(cardId: 'customer-prepayment'),
      ),
    );

Widget _hubApp(Set<String> permissions) => ProviderScope(
  overrides: [
    localServerReachableProvider.overrideWith(
      (ref) => LocalServerReachabilityNotifier(_preferences, web: true),
    ),
    sharedPreferencesProvider.overrideWithValue(_preferences),
    currentPermissionsProvider.overrideWithValue(permissions),
    isSuperAdminProvider.overrideWithValue(false),
  ],
  child: const MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: Locale('zh'),
    home: FinanceHubPage(),
  ),
);

class _ReportApi extends ApiClient {
  _ReportApi({this.fail = false, this.failure}) : super(Dio());

  bool fail;
  final Object? failure;
  int reportCalls = 0;
  Map<String, dynamic>? lastQuery;
  final candidateQueries = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    expect(path, '/business-references/clients/summaries');
    final request = Map<String, dynamic>.from(body! as Map);
    final filter = Map<String, dynamic>.from(request['filter'] as Map);
    candidateQueries.add(filter);
    expect(request['size'], 100);
    return versionedSummaryTestResponse(
      [
        if (filter['selectableOnly'] != true)
          {
            'id': 'hidden-customer',
            'name': '已隐藏历史客户',
            'categoryId': 'client-root',
            'status': '使用',
          },
      ],
      request,
      revision: 'a' * 64,
      dataVersion: 'b' * 64,
    );
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/business-references/clients') {
      candidateQueries.add({...?query});
      final items = [
        if (query?['selectableOnly'] != true)
          {
            'id': 'hidden-customer',
            'name': '已隐藏历史客户',
            'categoryId': 'client-root',
            'status': '使用',
          },
      ];
      return {
        'items': items,
        'page': 1,
        'size': 100,
        'total': items.length,
        'totalPages': 1,
      };
    }
    if (path == '/finance/reports/customer-prepayment/events') {
      reportCalls++;
      lastQuery = Map<String, dynamic>.from(query ?? const {});
      if (fail) throw failure ?? StateError('offline');
      return _response;
    }
    return const <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => path == '/business-references/client-categories'
      ? [
          {
            'id': 'client-root',
            'name': '客户分类',
            'code': 'C',
            'level': 0,
            'children': <Object>[],
          },
        ]
      : [];
}

const _response = <String, dynamic>{
  'columns': [
    {'key': 'eventDate', 'label': '记账日期', 'type': 'date', 'width': 120},
    {'key': 'eventNo', 'label': '资金单号', 'type': 'text', 'width': 180},
    {'key': 'eventTypeLabel', 'label': '事件类型', 'type': 'text', 'width': 150},
    {'key': 'salesOrderNos', 'label': '销售单', 'type': 'text', 'width': 180},
    {'key': 'clientName', 'label': '客户名称', 'type': 'text', 'width': 180},
    {'key': 'currencyCode', 'label': '币别', 'type': 'text', 'width': 90},
    {
      'key': 'prepaymentCashOriginal',
      'label': '预收现金(原币)',
      'type': 'money',
      'width': 130,
    },
    {
      'key': 'appliedOriginal',
      'label': '转销应收(原币)',
      'type': 'money',
      'width': 130,
    },
    {
      'key': 'exchangeDifferenceLocal',
      'label': '汇兑差额',
      'type': 'money',
      'width': 120,
    },
    {'key': 'reason', 'label': '摘要', 'type': 'text', 'width': 220},
  ],
  'rows': [
    {
      'eventDate': '2026-08-23',
      'eventNo': 'YS-001',
      'eventTypeLabel': '预收到账',
      'salesOrderNos': 'XD-001',
      'clientName': '甲客户',
      'currencyCode': 'USD',
      'prepaymentCashOriginal': '88.1234',
      'appliedOriginal': '0.0000',
      'exchangeDifferenceLocal': '0.0000',
      'reason': '订单预收到账',
    },
  ],
  'facets': <String, dynamic>{},
  'page': 1,
  'size': 50,
  'total': 1,
  'totalPages': 1,
};
