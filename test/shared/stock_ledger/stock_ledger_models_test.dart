// 单货品库存面板模型契约 (ADR-135 §7.1/§7.4): 流水行/汇总/表头桶解析、查询参数、
// 类型文案与重量来历只认服务端、按服务端 sourceDocCode 回源单、KPI 条文案。
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/shared/measurement/weight_predictor.dart';
import 'package:uten_imp/shared/stock_ledger/stock_ledger_models.dart';
import 'package:uten_imp/shared/stock_ledger/widgets/goods_stock_kpi_strip.dart';
import 'package:uten_imp/shared/stock_ledger/widgets/goods_stock_ledger_view.dart';

void main() {
  group('StockLedgerQuery', () {
    test('sends scope, dates, types and caps the page size', () {
      final q = StockLedgerQuery(
        warehouseId: 'w1',
        colorId: 'c1',
        dateFrom: DateTime(2026, 6, 30),
        dateTo: DateTime(2026, 9, 28),
        movementTypes: const ['5', '6'],
        includeWeightAdjustments: true,
        page: 2,
        size: 500,
      ).toQueryParameters();
      expect(q, {
        'warehouseId': 'w1',
        'colorId': 'c1',
        'dateFrom': '2026-06-30',
        'dateTo': '2026-09-28',
        'movementTypes': '5,6',
        'includeWeightAdjustments': true,
        'page': 2,
        'size': 100,
      });
    });

    test('colorNull replaces colorId and defaults stay out of the query', () {
      final q = const StockLedgerQuery(
        warehouseId: 'w1',
        colorId: 'ignored',
        colorNull: true,
      ).toQueryParameters();
      expect(q['colorNull'], isTrue);
      expect(q.containsKey('colorId'), isFalse);
      expect(q.containsKey('includeWeightAdjustments'), isFalse);
      expect(q.containsKey('direction'), isFalse);
      expect(q['size'], 50);
    });
  });

  group('StockLedgerPage.fromJson', () {
    test('parses rows, summary and keeps the server facet buckets', () {
      final page = StockLedgerPage.fromJson({
        'items': [
          {
            'rowKind': 'M',
            'id': 'm1',
            'transactionDate': '2026-09-20T00:00:00+08:00',
            'movementType': 3,
            'typeLabel': '销售出库(红冲)',
            'direction': 1,
            'sourceDocType': 'SALES_SHIPMENT',
            'sourceDocId': 's1',
            'billNo': 'SS-001',
            'counterpartMasked': true,
            'qtySigned': '12.5',
            'unitName': '个',
            'weightKgSigned': 0.5,
            'weightSource': 'AVERAGE',
            'balanceQtyAfter': 112.5,
            'balanceWeightKgAfter': null,
          },
          {
            'rowKind': 'W',
            'id': 'a1',
            'typeLabel': '人工核重',
            'adjustmentKind': 'MANUAL',
            'qtySigned': null,
            'weightKgSigned': -0.25,
            'balanceQtyAfter': 112.5,
            'balanceWeightKgAfter': 4.5,
          },
        ],
        'page': 1,
        'size': 50,
        'total': 2,
        'totalPages': 1,
        'summary': {
          'openingQty': 100,
          'closingQty': 112.5,
          'inQty': 12.5,
          'outQty': 0,
          'openingWeightKg': null,
          'inWeightUnknownRows': 2,
          'residualKg': -0.01,
        },
        'facets': {
          'movementType': [
            {'value': '3', 'label': '销售出库', 'count': 1},
          ],
          'color': [
            {'value': 'c1', 'label': '红', 'count': 3},
            {'value': '__null__', 'label': '无颜色', 'count': 2},
          ],
        },
      });
      expect(page.items, hasLength(2));
      final m = page.items.first;
      expect(m.isWeightAdjustment, isFalse);
      expect(m.qtySigned, 12.5);
      expect(m.isInbound, isTrue);
      expect(m.displayType, '销售出库(红冲)');
      expect(m.counterpartMasked, isTrue);
      expect(m.weightSource, 'AVERAGE');
      expect(m.balanceWeightKgAfter, isNull);

      final w = page.items.last;
      expect(w.isWeightAdjustment, isTrue);
      expect(w.qtySigned, isNull, reason: '重量调整行不动数量');
      expect(w.displayType, '人工核重');
      expect(w.isInbound, isFalse, reason: '重量调整按重量增减归入收/发列');

      expect(page.summary.openingQty, 100);
      expect(page.summary.openingWeightKg, isNull);
      expect(page.summary.inWeightUnknownRows, 2);
      expect(page.summary.residualKg, -0.01);

      // 「无颜色」桶原样保留, 值即表格的空值哨兵 (选它 = colorNull)。
      expect(page.facets['color']!.map((b) => b.value), [
        'c1',
        kMasterFilterNullValue,
      ]);
      expect(page.facets['color']!.last.display, '无颜色');
      expect(page.facets['movementType']!.single.display, '销售出库');
      expect(page.facets['warehouse'], isEmpty);
    });

    test('outbound rows read their direction from the signed quantity', () {
      final row = StockLedgerRow.fromJson({
        'rowKind': 'M',
        'id': 'm2',
        'typeLabel': '领料出库',
        'qtySigned': -3,
        'weightKgSigned': -1.2,
        'weightSource': 'MEASURED',
      });
      expect(row.weightSource, 'MEASURED');
      expect(row.isInbound, isFalse);
      expect(
        StockLedgerRow.fromJson({'rowKind': 'M', 'id': 'm3'}).displayType,
        '—',
      );
    });
  });

  test('source jumps use the server sourceDocCode for stock documents', () {
    String? path(String type, {String? code}) => stockSourceDocPath(
      sourceDocType: type,
      sourceDocId: 'id1',
      sourceDocCode: code,
    );
    expect(path('PURCHASE_RECEIPT'), '/purchase/receipts/id1');
    expect(path('SALES_OTHER_SHIPMENT'), '/sales/other-shipments/id1');
    expect(
      path('SUBCONTRACT_MATERIAL_RETURN'),
      '/subcontract/material-returns/id1',
    );
    // WASTE 单过账的是「其它出」类型, 旧版按 movement_type 会错跳到其它出库单。
    expect(path('STOCK_DOC', code: 'waste'), '/warehouse/WASTE/id1');
    expect(path('STOCK_DOC', code: 'WDRAW'), '/warehouse/WDRAW/id1');
    expect(path('STOCK_DOC'), isNull);
    expect(path('WORKSHOP_MATERIAL_COUNT'), isNull);
    expect(
      stockSourceDocPath(sourceDocType: 'PURCHASE_RECEIPT', sourceDocId: null),
      isNull,
    );
  });

  test('ledger summary entries: opening, in, out, closing with weight', () {
    final entries = stockLedgerSummaryEntries(
      const StockLedgerSummary(
        openingQty: 1000,
        closingQty: 1200,
        inQty: 500,
        outQty: 300,
        internalTransferQty: 40,
        closingWeightKg: 2.5,
        inWeightKg: 1.2,
        inWeightUnknownRows: 2,
        outWeightUnknownRows: 1,
        residualKg: 0.01,
      ),
      unitName: '个',
    );
    final byLabel = {for (final e in entries) e.label: e.value};
    expect(byLabel['期初结存'], '1,000 个 · 重量未知');
    expect(byLabel['本期收入'], '500 个 · 1.2 kg (另有 2 行未称)');
    expect(byLabel['本期发出'], '300 个 · 1 行未称');
    expect(byLabel['期末结存'], '1,200 个 · 2.5 kg');
    expect(byLabel['范围内调拨'], '40 个');
    expect(byLabel['重量尾差调整'], '+10 g');
  });

  test('KPI strip parts follow the product wording', () {
    final insight = GoodsStockInsight.fromJson({
      'qty': 12500,
      'weightKg': 28.9,
      'weightEstimated': true,
      'unitWeightKg': 0.002312,
      'tier': 'YELLOW',
      'relHalfWidth': 0.018,
      'lastInAt': '2026-09-20T08:00:00+08:00',
      'lastOutAt': '2026-09-26T10:00:00+08:00',
      'avgDailyOut90': 420,
      'daysOfCover': 29.8,
      'abc': 'A',
      'agePct0_30': 60,
    });
    expect(insight.tier, WeightTier.yellow);
    final parts = goodsStockKpiParts(
      insight,
      unitName: '个',
      weightText: '≈28.9 kg',
    );
    expect(parts, [
      '库存 12,500个 · ≈28.9 kg',
      '单重 2.312 g (可参考 ±1.8%)',
      '最后入库 09-20 · 最后出库 09-26',
      '90天日均出库 420个 · 约可用 30 天',
      'ABC: A',
      '库龄: 30天内 60%',
    ]);
    expect(
      goodsStockKpiParts(
        GoodsStockInsight.fromJson(const {'qty': 0, 'abc': 'N'}),
        weightText: '—',
      ),
      ['库存 0 · —', 'ABC: 近90天无出库'],
    );
  });
}
