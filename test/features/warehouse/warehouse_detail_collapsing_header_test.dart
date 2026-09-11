// 仓库三张详情页（仓库单据 / 实物历史 / 销售出库作业）2026-09-11 折叠头改版回归：
// 「先滚页面收头部、再滚表格内部」+ 三视口（含短视口 844x390）叠 textScale 1.5 不溢出。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/warehouse/config/warehouse_document_history_config.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_document_history.dart';
import 'package:uten_imp/features/warehouse/models/warehouse_sales_outbound.dart';
import 'package:uten_imp/features/warehouse/pages/stock_doc_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_document_history_detail_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_sales_outbound_detail_page.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_document_history_repository.dart';
import 'package:uten_imp/features/warehouse/repositories/warehouse_sales_outbound_repository.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/business_attachment_section.dart';
import 'package:uten_imp/shared/auth/document_scope_capability.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../support/collapsing_header_harness.dart';

class _AllowAllScope implements DocumentScopeCapabilityRepository {
  const _AllowAllScope();

  @override
  Future<DocumentScopeCapability> current(DocumentDataScope scope) async =>
      DocumentScopeCapability(
        scope: scope.apiValue,
        writeAll: true,
        writableOwnerIds: const <String>{},
      );
}

/// 仓库单据详情用的假后端：明细多行（撑出可内滚的表体）。
class _StockDocApi extends ApiClient {
  _StockDocApi() : super(Dio());

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => <String, dynamic>{
    'id': 'in-1',
    'docType': 'OTHER_IN',
    'billNo': 'QTIN-2026-001',
    'billDate': '2026-09-11',
    'status': 1,
    'warehouseId': 'main',
    'remark': '折叠头回归用单据',
    'canEdit': false,
    'canDelete': false,
    'items': <Map<String, dynamic>>[
      for (var i = 0; i < 24; i++)
        <String, dynamic>{
          'id': 'item-$i',
          'lineNo': i + 1,
          'qty': i + 1,
          'unitRate': 1,
        },
    ],
  };
}

Future<void> _pumpStockDoc(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
}) async {
  useUtenViewport(tester, size);
  final api = _StockDocApi();
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(const {
          Perm.stockDocView,
          Perm.attachmentView,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
        stockDocRepositoryProvider(
          StockDocType.otherIn,
        ).overrideWithValue(StockDocRepository(api, StockDocType.otherIn)),
        documentScopeCapabilityRepositoryProvider.overrideWithValue(
          const _AllowAllScope(),
        ),
        businessAttachmentsProvider.overrideWith(
          (ref, owner) async => const <Attachment>[],
        ),
      ],
      child: MaterialApp(
        builder: utenTextScaleBuilder(textScale),
        home: const StockDocDetailPage(
          docType: StockDocType.otherIn,
          id: 'in-1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _HistoryGateway implements WarehouseDocumentHistoryGateway {
  @override
  Future<PagedResult<WarehouseDocumentHistorySummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? dateFrom,
    String? dateTo,
  }) async => PagedResult<WarehouseDocumentHistorySummary>(
    items: <WarehouseDocumentHistorySummary>[_historyDetail.header],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<WarehouseDocumentHistoryDetail> detail(String id) async =>
      _historyDetail;
}

final WarehouseDocumentHistoryDetail _historyDetail =
    WarehouseDocumentHistoryDetail.fromJson(
      WarehouseDocumentHistoryType.purchaseReceipt,
      <String, dynamic>{
        'id': 'history-1',
        'billNo': 'PR-001',
        'billDate': '2026-08-31',
        'supplierName': '示例供应商',
        'warehouseName': '一号仓',
        'status': 1,
        'closed': false,
        'sourceDocumentNo': 'PO-001',
        'lineCount': 20,
        'makerName': '仓管甲',
        'approverName': '仓管乙',
        'remark': '外箱完好',
        'createdAt': '2026-08-31T08:30:00+08:00',
        'lines': <Map<String, dynamic>>[
          for (var i = 0; i < 20; i++)
            <String, dynamic>{
              'id': 'line-$i',
              'lineNumber': i + 1,
              'goodsCode': 'G-00$i',
              'goodsName': '实物产品$i',
              'stockPlace': 'A01-0$i',
              'unitName': '件',
              'quantity': '10.0000',
            },
        ],
      },
    );

Future<void> _pumpHistoryDetail(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
}) async {
  useUtenViewport(tester, size);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        warehouseDocumentHistoryRepositoryProvider(
          WarehouseDocumentHistoryType.purchaseReceipt,
        ).overrideWithValue(_HistoryGateway()),
      ],
      child: MaterialApp(
        builder: utenTextScaleBuilder(textScale),
        home: const WarehouseDocumentHistoryDetailPage(
          type: WarehouseDocumentHistoryType.purchaseReceipt,
          id: 'history-1',
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _outboundJson = <String, dynamic>{
  'id': 'shipment-1',
  'billNo': 'SO-OUT-001',
  'billDate': '2026-08-31',
  'clientName': '客户甲',
  'warehouseName': '一号仓',
  'warehouseWorkStatus': 'PENDING_PICK',
  'allowedWarehouseTargets': <String>['PICKING', 'EXCEPTION'],
  'shipAddress': '交接地址',
  'contactPhone': '13800000000',
  'logisticsNo': 'LOG-001',
  'lines': <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'line-1',
      'lineNumber': 1,
      'goodsCode': 'G-001',
      'goodsName': '货品甲',
      'currentStockPlaceHint': 'A01-01',
      'colorName': '本色',
      'unitName': '件',
      'quantity': '10.0000',
      'weight': '20.0000',
    },
    <String, dynamic>{
      'id': 'line-2',
      'lineNumber': 2,
      'goodsCode': 'G-002',
      'goodsName': '货品乙',
      'currentStockPlaceHint': 'A01-02',
      'colorName': '本色',
      'unitName': '件',
      'quantity': '4.0000',
      'weight': '8.0000',
    },
  ],
};

class _OutboundGateway implements WarehouseSalesOutboundGateway {
  _OutboundGateway(this.summary, this.value);

  final WarehouseSalesOutboundSummary summary;
  final WarehouseSalesOutboundDetail value;

  @override
  Future<int> pendingCount() async => 0;

  @override
  Future<PagedResult<WarehouseSalesOutboundSummary>> list({
    int page = 1,
    int size = 20,
    String? keyword,
    String? warehouseWorkStatus,
    String? dateFrom,
    String? dateTo,
  }) async => PagedResult(
    items: [summary],
    page: page,
    size: size,
    total: 1,
    totalPages: 1,
  );

  @override
  Future<WarehouseSalesOutboundDetail> detail(String id) async => value;

  @override
  Future<WarehouseSalesOutboundDetail> transition(
    String id, {
    required String targetStatus,
    String? reason,
  }) async => value;
}

Future<void> _pumpOutboundDetail(
  WidgetTester tester, {
  required Size size,
  double textScale = 1.0,
}) async {
  useUtenViewport(tester, size);
  final gateway = _OutboundGateway(
    WarehouseSalesOutboundSummary.fromJson(_outboundJson),
    WarehouseSalesOutboundDetail.fromJson(_outboundJson),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        warehouseSalesOutboundRepositoryProvider.overrideWithValue(gateway),
      ],
      child: MaterialApp(
        builder: utenTextScaleBuilder(textScale),
        home: const WarehouseSalesOutboundDetailPage(id: 'shipment-1'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('仓库单据详情：上滚先收表头卡，明细表接着内滚', (tester) async {
    await _pumpStockDoc(tester, size: const Size(1280, 900));

    expect(find.byType(UtenCollapsingHeaderScrollView), findsOneWidget);
    await expectUtenHeaderCollapses(
      tester,
      headerAnchor: find.text('单据号'),
      bodyAnchor: find.byType(MasterDataTableView<StockDocItem>),
    );
    expect(tester.takeException(), isNull);
  });

  for (final viewport in utenCollapsingViewports) {
    testWidgets('仓库单据详情 ${viewport.label} · textScale 1.5 不溢出', (tester) async {
      await _pumpStockDoc(tester, size: viewport.size, textScale: 1.5);
      await expectUtenBodyReachable(
        tester,
        bodyAnchor: find.byType(MasterDataTableView<StockDocItem>),
      );
    });
  }

  testWidgets('实物历史详情：上滚先收事实卡，实物明细表接着内滚', (tester) async {
    await _pumpHistoryDetail(tester, size: const Size(1280, 900));

    expect(find.byType(UtenCollapsingHeaderScrollView), findsOneWidget);
    await expectUtenHeaderCollapses(
      tester,
      headerAnchor: find.text('单据号'),
      bodyAnchor: find.byKey(
        const Key('warehouse-history-detail-table-purchase-receipts'),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  for (final viewport in utenCollapsingViewports) {
    testWidgets('实物历史详情 ${viewport.label} · textScale 1.5 不溢出', (tester) async {
      await _pumpHistoryDetail(tester, size: viewport.size, textScale: 1.5);
      await expectUtenBodyReachable(
        tester,
        bodyAnchor: find.byKey(
          const Key('warehouse-history-detail-table-purchase-receipts'),
        ),
      );
    });
  }

  testWidgets('销售出库作业详情：上滚先收状态横幅/事实卡，拣货明细接着内滚', (tester) async {
    await _pumpOutboundDetail(tester, size: const Size(1280, 900));

    expect(find.byType(UtenCollapsingHeaderScrollView), findsOneWidget);
    await expectUtenHeaderCollapses(
      tester,
      headerAnchor: find.text('出货单号'),
      bodyAnchor: find.byKey(
        const Key('warehouse-sales-outbound-detail-table'),
      ),
    );
    expect(tester.takeException(), isNull);
  });

  for (final viewport in utenCollapsingViewports) {
    testWidgets('销售出库作业详情 ${viewport.label} · textScale 1.5 不溢出', (
      tester,
    ) async {
      await _pumpOutboundDetail(tester, size: viewport.size, textScale: 1.5);
      await expectUtenBodyReachable(
        tester,
        bodyAnchor: find.byKey(
          const Key('warehouse-sales-outbound-detail-table'),
        ),
      );
    });
  }
}
