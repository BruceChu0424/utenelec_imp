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
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
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
      // 2026-09-29「大小屏共用一张表」：窄屏由表格内建卡片形态接管，
      // mobile-list 键退役；同一张表（含卡片形态）挂 quality-inspection-record-table。
      expect(
        find.byKey(const Key('quality-inspection-record-table')),
        findsOneWidget,
      );
      expect(find.text('全部记录'), findsOneWidget);
      // 卡片形态副行是「单号 · 编号」拼接串，用包含匹配。
      expect(find.textContaining('PR20260831001'), findsOneWidget);
      // 卡片明细是「标签 值」富文本，用包含匹配。
      expect(find.textContaining('当前有效'), findsOneWidget);
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
      expect(find.textContaining('RB20260831001'), findsOneWidget);

      // 卡片形态点卡片任意处（副行文本）打开详情。
      await tester.tap(find.textContaining('RB20260831001'));
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
      // 卡片形态副行是「单号 · 编号」拼接串，用包含匹配。
      expect(find.textContaining('PR20260831001'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('decision header filter sends decision to API', (tester) async {
    // 表头筛选生效冒烟：检验结果列固定枚举桶（PASS/PARTIAL/FAIL/CANCELLED），
    // 选桶 → repository.list 收到 decision 参数并回第 1 页。
    final api = _RecordApi();
    await _pumpPage(
      tester,
      api: api,
      permissions: const {Perm.procurementInspectionView},
      size: const Size(1280, 900),
    );

    final table = tester.widget<MasterDataTableView<QualityInspectionRecord>>(
      find.byKey(const Key('quality-inspection-record-table')),
    );
    expect(table.facets.keys, contains('decision'));
    expect(
      table.facets['decision']?.map((bucket) => bucket.value),
      containsAll(<String>['PASS', 'PARTIAL', 'FAIL', 'CANCELLED']),
    );

    table.onFilterChanged('decision', 'FAIL');
    await tester.pumpAndSettle();
    expect(api.listQueries.last['decision'], 'FAIL');
    expect(api.listQueries.last['page'], 1);

    final refreshed = tester
        .widget<MasterDataTableView<QualityInspectionRecord>>(
          find.byKey(const Key('quality-inspection-record-table')),
        );
    expect(refreshed.filters['decision'], 'FAIL');
    expect(tester.takeException(), isNull);
  });

  testWidgets('column header filters send sourceType/effective/disposition', (
    tester,
  ) async {
    // 表头三列（2026-09-16）：固定枚举桶随域变化——IQC 出检验类型桶不出处置桶，
    // FQC 反之；选桶 → repository.list 收到同名参数并回第 1 页。
    final api = _RecordApi();
    await _pumpPage(
      tester,
      api: api,
      permissions: const {
        Perm.procurementInspectionView,
        Perm.productionQualityInspectionView,
      },
      size: const Size(1280, 900),
    );

    final table = tester.widget<MasterDataTableView<QualityInspectionRecord>>(
      find.byKey(const Key('quality-inspection-record-table')),
    );
    expect(table.facets.keys, containsAll(<String>['sourceType', 'effective']));
    expect(table.facets.containsKey('disposition'), isFalse);
    expect(
      table.facets['sourceType']?.map((bucket) => bucket.value),
      containsAll(<String>['PURCHASE', 'SUBCONTRACT']),
    );
    expect(
      table.facets['effective']?.map((bucket) => bucket.value),
      containsAll(<String>['ACTIVE', 'EXPIRED', 'CANCELLED']),
    );

    table.onFilterChanged('sourceType', 'PURCHASE');
    await tester.pumpAndSettle();
    expect(api.listQueries.last['sourceType'], 'PURCHASE');
    expect(api.listQueries.last['page'], 1);

    var refreshed = tester.widget<MasterDataTableView<QualityInspectionRecord>>(
      find.byKey(const Key('quality-inspection-record-table')),
    );
    refreshed.onFilterChanged('effective', 'EXPIRED');
    await tester.pumpAndSettle();
    expect(api.listQueries.last['effective'], 'EXPIRED');
    expect(api.listQueries.last['sourceType'], 'PURCHASE');

    // 换 FQC 域：处置桶出现、检验类型桶消失（FQC 来源恒为生产成品）。
    await tester.tap(find.text('成品检验(FQC)'));
    await tester.pumpAndSettle();
    refreshed = tester.widget<MasterDataTableView<QualityInspectionRecord>>(
      find.byKey(const Key('quality-inspection-record-table')),
    );
    expect(refreshed.facets.containsKey('disposition'), isTrue);
    expect(refreshed.facets.containsKey('sourceType'), isFalse);
    expect(api.listQueries.last.containsKey('sourceType'), isFalse);
    refreshed.onFilterChanged('disposition', 'REWORK');
    await tester.pumpAndSettle();
    expect(api.listQueries.last['disposition'], 'REWORK');
    final afterDisposition = tester
        .widget<MasterDataTableView<QualityInspectionRecord>>(
          find.byKey(const Key('quality-inspection-record-table')),
        );
    expect(afterDisposition.filters['disposition'], 'REWORK');
    expect(tester.takeException(), isNull);
  });

  testWidgets('doc-no column filter and sort hit the server (2026-09-25)', (
    tester,
  ) async {
    // 单号列统一：来源单号列头值筛选（服务端精确匹配）与排序（白名单）下推后端；
    // facets 桶来自服务端 /facets 端点（与列表同过滤上下文）。
    final api = _RecordApi();
    await _pumpPage(
      tester,
      api: api,
      permissions: const {Perm.procurementInspectionView},
      size: const Size(1280, 900),
    );

    expect(api.facetPaths.last, '/procurement/inspection/records/facets');
    final table = tester.widget<MasterDataTableView<QualityInspectionRecord>>(
      find.byKey(const Key('quality-inspection-record-table')),
    );
    expect(table.facets.keys, containsAll(<String>['sourceNo', 'referenceNo']));
    expect(table.facets['sourceNo']?.single.value, 'PR20260831001');
    // IQC 无检查单号，桶为空表。
    expect(table.facets['sheetNo'], isEmpty);

    table.onFilterChanged('sourceNo', 'PR20260831001');
    await tester.pumpAndSettle();
    expect(api.listQueries.last['sourceNo'], 'PR20260831001');
    expect(api.listQueries.last['page'], 1);

    final filtered = tester
        .widget<MasterDataTableView<QualityInspectionRecord>>(
          find.byKey(const Key('quality-inspection-record-table')),
        );
    expect(filtered.filters['sourceNo'], 'PR20260831001');

    filtered.onSortChange?.call('sourceNo', false);
    await tester.pumpAndSettle();
    expect(api.listQueries.last['sort'], 'sourceNo');
    expect(api.listQueries.last['order'], 'desc');
    expect(tester.takeException(), isNull);
  });

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
      find.byKey(const Key('quality-inspection-record-table')),
      findsOneWidget,
    );
    expect(find.textContaining('PR20260831001'), findsOneWidget);
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
  final List<String> facetPaths = [];
  bool failNextList = false;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    // 2026-09-25 单号列统一：单号列 facets 端点（与列表同过滤参数）。
    if (path.endsWith('/facets')) {
      facetPaths.add(path);
      return {
        'sourceNo': const [
          {'value': 'PR20260831001', 'count': 1, 'label': 'PR20260831001'},
        ],
        'referenceNo': const [
          {'value': 'PO20260831001', 'count': 1, 'label': 'PO20260831001'},
        ],
        // IQC 无检查单号（服务端恒空表）；FQC 有。
        'sheetNo': path.contains('/production/')
            ? const [
                {'value': 'V510', 'count': 1, 'label': 'V510'},
              ]
            : const <Map<String, dynamic>>[],
      };
    }
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
