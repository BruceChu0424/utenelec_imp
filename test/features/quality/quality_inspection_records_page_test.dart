import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/quality/models/quality_inspection_record.dart';
import 'package:uten_imp/features/quality/pages/quality_inspection_records_page.dart';
import 'package:uten_imp/features/quality/repositories/quality_inspection_record_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

Future<void> _pumpPage(
  WidgetTester tester, {
  required _RecordApi api,
  required Set<String> permissions,
  Size size = const Size(375, 1000),
  QualityInspectionRecordDomain? initialDomain,
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        currentPermissionsProvider.overrideWithValue(permissions),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(
        theme: ThemeData.light(),
        darkTheme: ThemeData.dark(),
        themeMode: themeMode,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: QualityInspectionRecordsPage(initialDomain: initialDomain),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('repository sends one complete China business-day range', () async {
    final api = _RecordApi();
    await QualityInspectionRecordRepository(api).list(
      domain: QualityInspectionRecordDomain.iqc,
      dateRange: QualityInspectionDateRange(
        start: DateTime.utc(2026, 8, 31),
        end: DateTime.utc(2026, 8, 31),
      ),
    );

    expect(api.listQueries.single['from'], '2026-08-30T16:00:00.000Z');
    expect(api.listQueries.single['to'], '2026-08-31T15:59:59.999999Z');
  });

  testWidgets(
    '375px renders server metrics, filters, cards, and audited detail',
    (tester) async {
      final api = _RecordApi();
      await _pumpPage(
        tester,
        api: api,
        permissions: const {
          Perm.procurementInspectionView,
          Perm.productionQualityInspectionView,
        },
      );

      expect(find.text('检测记录'), findsOneWidget);
      expect(
        find.byKey(const Key('quality-inspection-record-mobile-list')),
        findsOneWidget,
      );
      expect(find.text('全部记录'), findsOneWidget);
      expect(find.text('PR20260831001'), findsOneWidget);
      expect(find.text('当前有效'), findsOneWidget);
      expect(api.listQueries.last['page'], 1);
      expect(api.listPaths.last, '/procurement/inspection/records');

      await tester.tap(find.text('不合格记录'));
      await tester.pumpAndSettle();
      expect(api.listQueries.last['decision'], 'FAIL');
      expect(api.listQueries.last['page'], 1);

      await tester.enterText(
        find.byKey(const Key('quality-inspection-record-search')),
        'V51043',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(api.listQueries.last['keyword'], 'V51043');

      await tester.tap(find.text('成品检验(FQC)'));
      await tester.pumpAndSettle();
      expect(api.listPaths.last, '/production/quality-inspections/records');
      expect(api.listQueries.last.containsKey('decision'), isFalse);
      expect(find.text('RB20260831001'), findsOneWidget);

      await tester.tap(find.text('RB20260831001'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('quality-inspection-record-fqc-event-1')),
        findsOneWidget,
      );
      expect(find.text('检测记录详情'), findsOneWidget);
      expect(find.text('尺寸抽检不合格'), findsOneWidget);
      expect(find.text('warehouse-1'), findsOneWidget);
      expect(
        api.detailPaths.last,
        '/production/quality-inspections/records/fqc-event-1',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'desktop uses the shared paged table and keeps stale data on error',
    (tester) async {
      final api = _RecordApi();
      await _pumpPage(
        tester,
        api: api,
        permissions: const {Perm.procurementInspectionView},
        size: const Size(1280, 900),
      );

      expect(
        find.byKey(const Key('quality-inspection-record-table')),
        findsOneWidget,
      );
      final table = tester.widget<MasterDataTableView<QualityInspectionRecord>>(
        find.byKey(const Key('quality-inspection-record-table')),
      );
      expect(table.items, hasLength(1));
      expect(table.currentPage, 1);
      expect(table.columns.map((column) => column.key), contains('effective'));

      api.failNextList = true;
      await tester.tap(find.text('刷新'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前仍显示上次成功结果'), findsOneWidget);
      expect(find.text('PR20260831001'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('no view permission fails closed without making API requests', (
    tester,
  ) async {
    final api = _RecordApi();
    await _pumpPage(tester, api: api, permissions: const {});

    expect(find.text('您暂无检测记录查看权限'), findsOneWidget);
    expect(api.listPaths, isEmpty);
    expect(api.detailPaths, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('375px dark mode and enlarged text stay operable', (
    tester,
  ) async {
    final api = _RecordApi();
    await _pumpPage(
      tester,
      api: api,
      permissions: const {Perm.procurementInspectionView},
      size: const Size(375, 1400),
      themeMode: ThemeMode.dark,
      textScale: 1.6,
    );

    expect(
      find.byKey(const Key('quality-inspection-record-mobile-list')),
      findsOneWidget,
    );
    expect(find.text('PR20260831001'), findsOneWidget);
    expect(find.textContaining('本页只读'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('enlarged-text empty state grows instead of overflowing', (
    tester,
  ) async {
    final api = _RecordApi(empty: true);
    await _pumpPage(
      tester,
      api: api,
      permissions: const {Perm.procurementInspectionView},
      textScale: 1.6,
    );

    expect(find.text('当前筛选下没有检测记录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _RecordApi extends ApiClient {
  _RecordApi({this.empty = false}) : super(Dio());

  final bool empty;
  final List<String> listPaths = [];
  final List<String> detailPaths = [];
  final List<Map<String, dynamic>> listQueries = [];
  bool failNextList = false;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final detail = RegExp(
      r'^/(?:procurement/inspection|production/quality-inspections)/records/[^/]+$',
    ).hasMatch(path);
    if (detail) {
      detailPaths.add(path);
      return _record(path.contains('/production/') ? 'FQC' : 'IQC');
    }
    listPaths.add(path);
    listQueries.add(Map<String, dynamic>.from(query ?? const {}));
    if (failNextList) {
      failNextList = false;
      throw DioException(
        requestOptions: RequestOptions(path: path),
        type: DioExceptionType.connectionError,
      );
    }
    final domain = path.contains('/production/') ? 'FQC' : 'IQC';
    return {
      'items': empty ? const <Map<String, dynamic>>[] : [_record(domain)],
      'page': (query?['page'] as num?)?.toInt() ?? 1,
      'size': 40,
      'total': empty ? 0 : 1,
      'totalPages': empty ? 0 : 1,
      'metrics': const {
        'ALL': 5,
        'PASS': 3,
        'PARTIAL': 1,
        'FAIL': 1,
        'CANCELLED': 0,
      },
    };
  }

  Map<String, dynamic> _record(String domain) => {
    'recordId': domain == 'FQC' ? 'fqc-event-1' : 'iqc-event-1',
    'domain': domain,
    'sourceType': domain == 'FQC' ? 'PRODUCTION' : 'PURCHASE',
    'inspectionId': '${domain.toLowerCase()}-inspection-1',
    'sourceId': '${domain.toLowerCase()}-source-1',
    'sourceItemId': '${domain.toLowerCase()}-source-item-1',
    'sourceNo': domain == 'FQC' ? 'RB20260831001' : 'PR20260831001',
    'sourceDate': '2026-08-31',
    'referenceNo': domain == 'FQC' ? 'SJ20260831001' : 'PO20260831001',
    'partnerId': domain == 'FQC' ? null : 'supplier-1',
    'partnerName': domain == 'FQC' ? null : '中山供应商',
    'warehouseId': 'warehouse-1',
    'warehouseName': '成品仓',
    'goodsId': 'goods-1',
    'goodsCode': 'V51043',
    'goodsName': '三极插套',
    'colorId': 'color-1',
    'colorName': '本色',
    'unitId': 'unit-1',
    'unitName': '件',
    'inspectedQty': 10,
    'currentPassedQty': 8,
    'currentFailedQty': 2,
    'currentRemainingQty': 0,
    'decision': 'PARTIAL',
    'passQty': 8,
    'failQty': 2,
    'dispositionCode': 'REWORK',
    'reason': '尺寸抽检不合格',
    'inspectorEmployeeId': 'employee-1',
    'inspectorName': '品质员甲',
    'decidedAt': '2026-08-31T02:30:00Z',
    'currentStatus': 'RESOLVED',
    'effective': true,
  };
}
