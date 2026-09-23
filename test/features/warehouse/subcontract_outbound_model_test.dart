import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/warehouse/models/subcontract_outbound.dart';

void main() {
  test('计划行解析并回传服务端权威颜色和单位 UUID', () {
    final line = OutboundPlanLine.fromJson({
      'planItemId': 'plan-item-1',
      'orderItemId': 'order-item-1',
      'parentGoodsId': 'parent-goods-1',
      'parentColorId': 'parent-color-1',
      'parentGoodsCode': 'P001',
      'parentGoodsName': '父件',
      'goodsId': 'goods-1',
      'goodsCode': 'G001',
      'goodsName': '子件',
      'goodsStockPlace': 'A-01',
      'colorId': 'color-1',
      'colorName': '黑色',
      'unitId': 'unit-1',
      'unitName': '个',
      'bomUnitQty': 2,
      'plannedQty': 20,
      'issuedQty': 4,
      'draftQty': 6,
    });

    expect(line.colorId, 'color-1');
    expect(line.unitId, 'unit-1');
    expect(line.toMaterialIssueItemPayload(qty: 5), {
      'goodsId': 'goods-1',
      'colorId': 'color-1',
      'unitId': 'unit-1',
      'qty': 5,
      'unitRate': 1,
      'orderItemId': 'order-item-1',
      'planItemId': 'plan-item-1',
      'parentGoodsId': 'parent-goods-1',
      'parentColorId': 'parent-color-1',
    });
  });

  test('无颜色和单位的计划行也显式回传空 UUID', () {
    final line = OutboundPlanLine.fromJson({
      'planItemId': 'plan-item-2',
      'orderItemId': 'order-item-2',
      'goodsId': 'goods-2',
    });

    expect(
      line.toMaterialIssueItemPayload(qty: 3),
      containsPair('colorId', null),
    );
    expect(
      line.toMaterialIssueItemPayload(qty: 3),
      containsPair('unitId', null),
    );
  });

  group('COMPONENT_OUTBOUND 发子件给委外商 (ADR-085 / ADR-101)', () {
    // 这条流向此前**根本不在枚举里**：服务端原样下发 COMPONENT_OUTBOUND，客户端落
    // unknown 并把可出量 fail-closed 成 0，于是同一行同时显示「已备齐 1000」和
    // 「本次最多 0」，填任何数字都报超量——与子件有没有货毫无关系，有货也发不出去。
    Map<String, dynamic> componentLine({
      required double readyOutboundQty,
      required double draftReservedQty,
      double? issuableQty,
      double? stockAvailableQty,
    }) => {
      'planItemId': 'component-line',
      'orderItemId': 'component-order-line',
      'parentGoodsId': 'subcontract-goods',
      'parentGoodsCode': 'SC001',
      'parentGoodsName': '委外件',
      'goodsId': 'component-goods',
      'goodsCode': 'C001',
      'goodsName': '采购子件',
      'flowMode': 'COMPONENT_OUTBOUND',
      'preparationStatus': 'READY_OUTBOUND',
      'plannedQty': 1000,
      'preparedQty': 1000,
      'issuedQty': 0,
      'readyOutboundQty': readyOutboundQty,
      'draftReservedQty': draftReservedQty,
      'remainingQty': 1000,
      // null 表示旧服务端没下发这两个字段；fromJson 对「键不存在」与「值是 null」
      // 的处理相同，都会回落到纯计划口径。
      'issuableQty': issuableQty,
      'stockAvailableQty': stockAvailableQty,
      'stockWarehouseId': 'leaf-warehouse',
      'stockWarehouseName': '成品仓',
      'allowedActions': ['HANDLE_OUTBOUND'],
    };

    test('流向被识别，父件身份保留，不再被 fail closed 成零', () {
      final line = OutboundPlanLine.fromJson(
        componentLine(readyOutboundQty: 1000, draftReservedQty: 0),
      );

      expect(line.flowMode, SubcontractOutboundFlowMode.componentOutbound);
      expect(line.readyOutboundQty, 1000);
      expect(line.parentGoodsName, '委外件');
      expect(line.goodsName, '采购子件');
    });

    test('子件一件都没有时可发数量是 0，不回落成计划余量', () {
      final line = OutboundPlanLine.fromJson(
        componentLine(
          readyOutboundQty: 1000,
          draftReservedQty: 0,
          issuableQty: 0,
          stockAvailableQty: 0,
        ),
      );

      expect(line.freeIssuableQty, 0);
      expect(line.maxEditableQty, 0);
      expect(line.stockWarehouseName, '成品仓');
    });

    test('子件到了 300 就先发 300：上限按可发量而不是计划余量', () {
      final line = OutboundPlanLine.fromJson(
        componentLine(
          readyOutboundQty: 1000,
          draftReservedQty: 0,
          issuableQty: 300,
          stockAvailableQty: 300,
        ),
      );

      expect(line.freeIssuableQty, 300);
      expect(line.maxEditableQty, 300);
    });

    test('已有草稿占住的量算自己的额度，子件续到可以把同一张草稿直接改大', () {
      // 草稿已占 300(这 300 在 v_stock_available 里已被预留扣掉)，仓里又到了 200。
      final line = OutboundPlanLine.fromJson(
        componentLine(
          readyOutboundQty: 700,
          draftReservedQty: 300,
          issuableQty: 200,
          stockAvailableQty: 200,
        ),
      );

      expect(line.freeIssuableQty, 200);
      expect(line.maxEditableQty, 500);
    });

    test('服务端没下发可发量时回落纯计划口径，旧服务端行为不变', () {
      final line = OutboundPlanLine.fromJson(
        componentLine(readyOutboundQty: 1000, draftReservedQty: 0),
      );

      expect(line.issuableQty, isNull);
      expect(line.freeIssuableQty, 1000);
      expect(line.maxEditableQty, 1000);
    });
  });

  test('未知新流模式 fail closed，不得按历史发料行放行', () {
    final line = OutboundPlanLine.fromJson({
      'planItemId': 'plan-item-future',
      'orderItemId': 'order-item-future',
      'goodsId': 'goods-future',
      'flowMode': 'FUTURE_UNRECOGNIZED_MODE',
      'preparationStatus': 'READY_OUTBOUND',
      'plannedQty': 10,
      'readyOutboundQty': 10,
      'draftReservedQty': 2,
    });

    expect(line.flowMode, SubcontractOutboundFlowMode.unknown);
    expect(line.readyOutboundQty, 0);
    expect(line.maxEditableQty, 0);
  });

  test('PREPARED_OUTBOUND 实收入库后复用原草稿占用，不把可新增量零当作不可出库', () {
    // Reproduces the V5 prepared-output contract: all 10000 received units
    // already belong to the existing pending EC draft; none are free for a
    // second draft. Recognising the flow restores handling of the original EC.
    final line = OutboundPlanLine.fromJson({
      'planItemId': 'prepared-v5-line',
      'orderItemId': 'prepared-v5-order-line',
      'goodsId': 'prepared-v5-goods',
      'flowMode': 'PREPARED_OUTBOUND',
      'preparationStatus': 'READY_OUTBOUND',
      'plannedQty': 10000,
      'preparedQty': 10000,
      'issuedQty': 0,
      'readyOutboundQty': 0,
      'draftReservedQty': 10000,
      'remainingQty': 10000,
      'allowedActions': ['HANDLE_OUTBOUND'],
    });
    expect(line.flowMode, SubcontractOutboundFlowMode.preparedOutbound);
    expect(line.readyOutboundQty, 0);
    expect(line.maxEditableQty, 10000);
    expect(line.allows('HANDLE_OUTBOUND'), isTrue);
  });

  test('PREPARED_OUTBOUND 无草稿时仅服务端放行数量可用于新出库', () {
    final line = OutboundPlanLine.fromJson({
      'planItemId': 'prepared-line',
      'orderItemId': 'prepared-order-line',
      'goodsId': 'prepared-goods',
      'flowMode': 'PREPARED_OUTBOUND',
      'preparationStatus': 'READY_OUTBOUND',
      'plannedQty': 10000,
      'preparedQty': 10000,
      'readyOutboundQty': 10000,
      'draftReservedQty': 0,
    });
    expect(line.readyOutboundQty, 10000);
    expect(line.maxEditableQty, 10000);
  });

  test('PREPARED_OUTBOUND 遇到未知准备状态仍然禁止执行', () {
    final line = OutboundPlanLine.fromJson({
      'planItemId': 'prepared-line',
      'orderItemId': 'prepared-order-line',
      'goodsId': 'prepared-goods',
      'flowMode': 'PREPARED_OUTBOUND',
      'preparationStatus': 'FUTURE_STATUS',
      'plannedQty': 10000,
      'readyOutboundQty': 10000,
      'draftReservedQty': 10000,
    });
    expect(line.readyOutboundQty, 0);
    expect(line.maxEditableQty, 0);
  });

  group('OutboundTask 列表行阶段 (ADR-103 §2.4)', () {
    Map<String, dynamic> task({
      String? draftId,
      double? issuableTotal,
      int waitingComponentLineCount = 0,
      double readyOutboundQty = 0,
      int readyLineCount = 0,
    }) => {
      'planId': 'plan-1',
      'orderId': 'order-1',
      'orderBillNo': 'WW-1',
      'supplierName': '委外商',
      'deliverDate': '2026-09-30',
      'lineCount': 1,
      'plannedQty': 5000,
      'issuedQty': 0,
      'remainingQty': 5000,
      'draftId': draftId,
      'draftBillNo': draftId == null ? null : 'EC-1',
      'readyOutboundQty': readyOutboundQty,
      'readyLineCount': readyLineCount,
      'issuableTotal': issuableTotal,
      'waitingComponentLineCount': waitingComponentLineCount,
    };

    test('新字段解析: 可发合计与等子件行数', () {
      final row = OutboundTask.fromJson(
        task(issuableTotal: 300, waitingComponentLineCount: 2),
      );
      expect(row.issuableTotal, 300);
      expect(row.waitingComponentLineCount, 2);
    });

    test('有草稿一律是待拣货, 不看可发量', () {
      final row = OutboundTask.fromJson(
        task(
          draftId: 'draft-1',
          issuableTotal: 0,
          waitingComponentLineCount: 1,
        ),
      );
      expect(row.stage, OutboundTaskStage.draftPicking);
      expect(row.selectable, isTrue);
    });

    test('无草稿且可发 > 0 → 已备齐待出仓, 可勾选', () {
      final row = OutboundTask.fromJson(
        task(issuableTotal: 300, readyOutboundQty: 5000),
      );
      expect(row.stage, OutboundTaskStage.readyOutbound);
      expect(row.selectable, isTrue);
    });

    test('无草稿、可发 0 且有行在等子件 → 等子件到货, 不可勾选', () {
      // 此前这一行显示「目标件已备齐，待出仓」(readyOutboundQty=计划余量 5000 > 0)，
      // 勾进批量页只会撞 409。
      final row = OutboundTask.fromJson(
        task(
          issuableTotal: 0,
          waitingComponentLineCount: 1,
          readyOutboundQty: 5000,
        ),
      );
      expect(row.stage, OutboundTaskStage.waitingComponent);
      expect(row.selectable, isFalse);
    });

    test('老服务端没下发 issuableTotal 时回落纯计划口径', () {
      final legacy = OutboundTask.fromJson(
        task(readyOutboundQty: 5000, readyLineCount: 1),
      );
      expect(legacy.issuableTotal, isNull);
      expect(legacy.stage, OutboundTaskStage.readyOutbound);
      expect(legacy.selectable, isTrue);

      final nothing = OutboundTask.fromJson(task());
      expect(nothing.stage, OutboundTaskStage.pendingDraft);
      expect(nothing.selectable, isFalse);
    });
  });
}
