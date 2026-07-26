// 生产计划成本 / BOM 展开行 model（生产管理 · 只读）。
//
// 对应后端 server/src/main/java/com/uten/imp/features/production/plancost/：
//   GET /production/plan-costs（分页）→ PlanCostRow
//   GET /production/plan-costs/{id} → PlanCostRow
//   GET /production/plan-costs/aggregate → List<PlanCostAggregation>（裸数组）
//
// ⚠ 本期严格只读：F_PlanCostItem 136 万行是"读多写少 + 重算昂贵"的快照表，
//   不做 BOM 展开 / 数量级联重算 / MRP 需购量（归未来成本/MRP 模块，见
//   docs/数据迁移/24 §四、§九）。UI 仅提供查询，标注"只读历史数据"。
//
// 外键陷阱：bill_item_id → production_plan_items.id（不是 plans.id！见 24 §3.3/§五）。
// 分区键：bill_date（按年 RANGE 分区 2018–2030 + DEFAULT）。
//
// JSON：camelCase；16 数量族 NUMERIC(18,4)；sourceDocNo 多值前缀合并
//   'PO:..|PI:..|PW:..|PD:..|OW:..|EO:..|EI:..|EW:..|PA:..'（见 24 §7.3）。

int? _asInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double? _asDouble(dynamic v) {
  if (v == null) return null;
  if (v is double) return v;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

/// BOM 展开行（PlanCostRow，38 字段含 16 数量族 + 单价/金额）。
class ProductionPlanCostRow {
  const ProductionPlanCostRow({
    required this.id,
    this.legacyId,
    this.billItemId,
    this.billNo,
    this.billDate,
    this.parentId,
    this.parentLegacyId,
    this.level,
    this.nodeClass,
    this.goodsId,
    this.colorId,
    this.masterGoodsId,
    this.masterColorId,
    this.salesOrderCostItemId,
    this.qty,
    this.dqty,
    this.pqty,
    this.lqty,
    this.slqty,
    this.rqty,
    this.orderQty,
    this.inQty,
    this.pdrawQty,
    this.owdrawQty,
    this.pwdrawQty,
    this.eoQty,
    this.eiQty,
    this.ewQty,
    this.mqty,
    this.paQty,
    this.price,
    this.total,
    this.supplierId,
    this.assTeamLegacyId,
    this.sourceDocNo,
    this.lstatus,
    this.summary,
  });

  final String id;
  final int? legacyId;
  final String? billItemId; // → production_plan_items.id（不是 plans.id）
  final String? billNo;
  final String? billDate; // 分区键
  final String? parentId; // 自引用（null=顶层）
  final int? parentLegacyId; // 0=顶层
  final int? level; // BOM 层级（≤30）
  final int? nodeClass; // 0=物料 / ≠0=工序费用
  final String? goodsId;
  final String? colorId;
  final String? masterGoodsId; // 顶层成品（冗余便于按成品汇总）
  final String? masterColorId;
  final String? salesOrderCostItemId;

  /// 数量族（16 个，NUMERIC(18,4)；本期不重算，原样保留触发器累计量）。
  final double? qty; // 总需量（成品量×单支用量）
  final double? dqty; // 单套用量（BOM 单耗）
  final double? pqty; // 计划数量（带损耗投产量）
  final double? lqty; // 排产占用
  final double? slqty; // 本次用量（计算列）
  final double? rqty; // 入库数量
  final double? orderQty; // 已订货（采购回写）
  final double? inQty; // 已收货（采购回写）
  final double? pdrawQty; // 已领料（仓库回写）
  final double? owdrawQty; // 已退料（仓库回写）
  final double? pwdrawQty; // 采购退货量
  final double? eoQty; // 委外订货
  final double? eiQty; // 委外缴回
  final double? ewQty; // 委外退回
  final double? mqty; // 多订量（手工调整）
  final double? paQty; // 已排产量

  final double? price;
  final double? total; // = qty × price
  final String? supplierId; // 建议供应
  final int? assTeamLegacyId;
  final String? sourceDocNo; // 多值前缀合并文本
  final int? lstatus;
  final String? summary;

  /// nodeClass 文案：0=物料 / ≠0=工序·费用。
  String get nodeClassLabel {
    switch (nodeClass) {
      case 0:
      case null:
        return '物料';
      default:
        return '工序·费用';
    }
  }

  factory ProductionPlanCostRow.fromJson(Map<String, dynamic> json) =>
      ProductionPlanCostRow(
        id: json['id'] as String,
        legacyId: _asInt(json['legacyId']),
        billItemId: json['billItemId'] as String?,
        billNo: json['billNo'] as String?,
        billDate: json['billDate'] as String?,
        parentId: json['parentId'] as String?,
        parentLegacyId: _asInt(json['parentLegacyId']),
        level: _asInt(json['level']),
        nodeClass: _asInt(json['nodeClass']),
        goodsId: json['goodsId'] as String?,
        colorId: json['colorId'] as String?,
        masterGoodsId: json['masterGoodsId'] as String?,
        masterColorId: json['masterColorId'] as String?,
        salesOrderCostItemId: json['salesOrderCostItemId'] as String?,
        qty: _asDouble(json['qty']),
        dqty: _asDouble(json['dqty']),
        pqty: _asDouble(json['pqty']),
        lqty: _asDouble(json['lqty']),
        slqty: _asDouble(json['slqty']),
        rqty: _asDouble(json['rqty']),
        orderQty: _asDouble(json['orderQty']),
        inQty: _asDouble(json['inQty']),
        pdrawQty: _asDouble(json['pdrawQty']),
        owdrawQty: _asDouble(json['owdrawQty']),
        pwdrawQty: _asDouble(json['pwdrawQty']),
        eoQty: _asDouble(json['eoQty']),
        eiQty: _asDouble(json['eiQty']),
        ewQty: _asDouble(json['ewQty']),
        mqty: _asDouble(json['mqty']),
        paQty: _asDouble(json['paQty']),
        price: _asDouble(json['price']),
        total: _asDouble(json['total']),
        supplierId: json['supplierId'] as String?,
        assTeamLegacyId: _asInt(json['assTeamLegacyId']),
        sourceDocNo: json['sourceDocNo'] as String?,
        lstatus: _asInt(json['lstatus']),
        summary: json['summary'] as String?,
      );
}

/// BOM 成本汇总行（按顶层成品 / 节点货品上卷；GET .../aggregate 裸数组）。
class ProductionPlanCostAggregation {
  const ProductionPlanCostAggregation({
    this.masterGoodsId,
    this.goodsId,
    this.qtySum,
    this.pqtySum,
    this.totalSum,
    this.lineCnt,
  });

  final String? masterGoodsId;
  final String? goodsId;
  final double? qtySum;
  final double? pqtySum;
  final double? totalSum;
  final int? lineCnt;

  factory ProductionPlanCostAggregation.fromJson(Map<String, dynamic> json) =>
      ProductionPlanCostAggregation(
        masterGoodsId: json['masterGoodsId'] as String?,
        goodsId: json['goodsId'] as String?,
        qtySum: _asDouble(json['qtySum']),
        pqtySum: _asDouble(json['pqtySum']),
        totalSum: _asDouble(json['totalSum']),
        lineCnt: _asInt(json['lineCnt']),
      );
}
