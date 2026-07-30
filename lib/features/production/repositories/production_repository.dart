// 生产模块仓库（生产管理 / production）。
//
// 3 个仓库 + 3 个 Provider（底部）：
//   ① ProductionPlanRepository        — 计划单 CRUD + /approve + /reverse
//   ② ProductionDailyReportRepository — 日报 CRUD + /approve + /reverse（空结构保未来）
//   ③ ProductionReportRepository      — 4 报表（明细分页 / 汇总 MV，裸数组返回）
//
// 端点（后端 @RequestMapping 全部在 /api/production/* 下，baseUrl 由 ApiClient 注入）：
//   GET    /production/plans                 列表（PageResponse<PlanListItem>）
//   GET    /production/plans/{id}            详情（PlanDetail）
//   POST   /production/plans                 新建（草稿）
//   PUT    /production/plans/{id}            编辑（仅草稿）
//   DELETE /production/plans/{id}            软删（仅草稿；已审需红冲）
//   POST   /production/plans/{id}/approve    审核 0→1
//   POST   /production/plans/{id}/reverse    红冲 1→-1
//   GET    /production/daily-reports         列表（PageResponse<DailyReportListItem>）
//   GET    /production/daily-reports/{id}    详情（DailyReportDetail）
//   POST   /production/daily-reports         新建（草稿）
//   PUT    /production/daily-reports/{id}    编辑（仅草稿）
//   DELETE /production/daily-reports/{id}    软删
//   POST   /production/daily-reports/{id}/approve
//   POST   /production/daily-reports/{id}/reverse
//   GET    /production/reports/plan/detail    List<PlanDetailRow>（分页）
//   GET    /production/reports/plan/summary   List<MonthlySummaryRow>
//   GET    /production/reports/daily/detail   List<DailyDetailRow>（分页，0 行）
//   GET    /production/reports/daily/summary  List<MonthlySummaryRow>（0 行）
//
// ⚠ 端点路径目前写死在仓库内（带 // ENDPOINT 注释），便于 grep；
//   共享接线时把它们搬到 lib/core/network/api_endpoints.dart（同 purchase 段）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/models/paged_result.dart';
import '../models/production_daily_report.dart';
import '../models/production_plan.dart';
import '../models/production_report.dart';

// ───────────────────────── 生产计划单 ─────────────────────────

/// 生产计划单过滤参数（列表 query 拼装用）。
class ProductionPlanFilter {
  const ProductionPlanFilter({
    this.keyword,
    this.departmentId,
    this.status,
    this.closed,
    this.dateFrom,
    this.dateTo,
  });

  final String? keyword; // 模糊匹配 bill_no
  final String? departmentId;
  final int? status; // 0/1/-1
  final bool? closed; // is_closed
  final String? dateFrom; // yyyy-MM-dd
  final String? dateTo;

  Map<String, dynamic> toQuery() => <String, dynamic>{
        if (keyword != null && keyword!.trim().isNotEmpty) 'keyword': keyword!.trim(),
        if (departmentId != null) 'departmentId': departmentId,
        if (status != null) 'status': status,
        if (closed != null) 'closed': closed,
        if (dateFrom != null) 'dateFrom': dateFrom,
        if (dateTo != null) 'dateTo': dateTo,
      };
}

class ProductionPlanRepository {
  ProductionPlanRepository(this.api);
  final ApiClient api;

  Future<PagedResult<ProductionPlanListItem>> list({
    int page = 1,
    int size = 20,
    ProductionPlanFilter filter = const ProductionPlanFilter(),
    String? sort,
    String? order,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      ...filter.toQuery(),
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
    };
    final json = await api.get('/production/plans', query: query); // ENDPOINT
    return PagedResult.fromJson(json, ProductionPlanListItem.fromJson);
  }

  Future<ProductionPlanDetail> detail(String id) async {
    final json = await api.get('/production/plans/$id'); // ENDPOINT
    return ProductionPlanDetail.fromJson(json);
  }

  Future<ProductionPlanDetail> create(Map<String, dynamic> body) async {
    final json = await api.post('/production/plans', body: body); // ENDPOINT
    return ProductionPlanDetail.fromJson(json);
  }

  Future<ProductionPlanDetail> update(String id, Map<String, dynamic> body) async {
    final json = await api.put('/production/plans/$id', body: body); // ENDPOINT
    return ProductionPlanDetail.fromJson(json);
  }

  Future<void> delete(String id) async {
    await api.delete('/production/plans/$id'); // ENDPOINT
  }

  Future<ProductionPlanDetail> approve(String id) async {
    final json = await api.post('/production/plans/$id/approve'); // ENDPOINT
    return ProductionPlanDetail.fromJson(json);
  }

  Future<ProductionPlanDetail> reverse(String id) async {
    final json = await api.post('/production/plans/$id/reverse'); // ENDPOINT
    return ProductionPlanDetail.fromJson(json);
  }

  /// 生产进度看板（服务端分页）：closed=false 进行中（默认）/ true 已完成。
  /// sort=billDate|billDateDesc|deliveryDate|progress；dateFrom/dateTo 开单日期范围。
  Future<PagedResult<PlanProgressRow>> planProgress({
    bool closed = false,
    String sort = 'billDate',
    int page = 1,
    int size = 20,
    String keyword = '',
    String workshop = '',
    String? dateFrom,
    String? dateTo,
  }) async {
    final json = await api.get('/production/plans/progress', query: {
      'closed': closed,
      'sort': sort,
      'page': page,
      'size': size,
      if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
      if (workshop.isNotEmpty) 'workshop': workshop,
      'dateFrom': ?dateFrom,
      'dateTo': ?dateTo,
    }); // ENDPOINT
    return PagedResult.fromJson(json, PlanProgressRow.fromJson);
  }

  /// 进度看板汇总（同过滤、跨全部页）：{count, sumQty, sumInbound}。
  Future<Map<String, dynamic>> planProgressSummary({
    bool closed = false,
    String keyword = '',
    String workshop = '',
    String? dateFrom,
    String? dateTo,
  }) async {
    return api.get('/production/plans/progress/summary', query: {
      'closed': closed,
      if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
      if (workshop.isNotEmpty) 'workshop': workshop,
      'dateFrom': ?dateFrom,
      'dateTo': ?dateTo,
    }); // ENDPOINT
  }

  /// 进度看板车间筛选选项（去重车间名，不受当前筛选影响）。
  Future<List<String>> planProgressWorkshops({bool closed = false}) async {
    final list = await api.getList('/production/plans/progress/workshops',
        query: {'closed': closed}); // ENDPOINT
    return [
      for (final e in list)
        if (e['name'] is String) e['name'] as String,
    ];
  }

  /// 看板标记（V127）：置顶 / 重要；传 null 的字段保持不变。
  Future<void> updatePlanFlags(String id,
      {bool? pinned, bool? important}) async {
    await api.post('/production/plans/$id/flags', body: {
      'pinned': ?pinned,
      'important': ?important,
    }); // ENDPOINT
  }

  // ───────────────────────── MRP-lite（物料需求 → 采购申请） ─────────────────────────

  /// 物料需求预览：BOM 展开毛需求 − 库存 − 在途 = 净需求（自制件标记）。
  Future<List<MrpRow>> mrpPreview(String id) async {
    final list = await api.getList('/production/plans/$id/mrp'); // ENDPOINT
    return list.map(MrpRow.fromJson).toList();
  }

  /// 按净需求生成采购申请（草稿）；已生成过且单据有效时后端 409 业务错误。
  /// D3：strategy=gross 按毛需求开单（不扣库存/在途）。
  Future<MrpGenerateResult> mrpGenerate(String id, {String? strategy}) async {
    final json = await api.post(
        '/production/plans/$id/mrp/generate${strategy != null ? '?strategy=$strategy' : ''}'); // ENDPOINT
    return MrpGenerateResult.fromJson(json);
  }

  /// D3 订单物料分析：已审销售订货单直接 BOM 展开。
  Future<List<MrpRow>> mrpOrderPreview(String orderId) async {
    final list = await api.getList('/production/mrp/order-preview',
        query: {'orderId': orderId}); // ENDPOINT
    return list.map(MrpRow.fromJson).toList();
  }

  /// 按 BOM 毛需求生成生产领料单（草稿，需指定仓库）。
  Future<MrpGenerateResult> mrpGenerateDraw(String id, String warehouseId) async {
    final json = await api.post('/production/plans/$id/mrp/generate-draw',
        body: {'warehouseId': warehouseId}); // ENDPOINT
    return MrpGenerateResult.fromJson(json);
  }

  /// 按计划明细（排产量−已入库量）生成成品入库单（草稿，需指定仓库）。
  Future<MrpGenerateResult> mrpGenerateFinishedIn(String id, String warehouseId) async {
    final json = await api.post('/production/plans/$id/mrp/generate-finished-in',
        body: {'warehouseId': warehouseId}); // ENDPOINT
    return MrpGenerateResult.fromJson(json);
  }

  /// 自制件按净需求生成下层生产计划（草稿）；多层 BOM 可在子计划上继续生成。
  Future<MrpGenerateResult> mrpGenerateSubplan(String id) async {
    final json =
        await api.post('/production/plans/$id/mrp/generate-subplan'); // ENDPOINT
    return MrpGenerateResult.fromJson(json);
  }

  /// 已生成的自制件子计划溯源（父计划 MRP 面板展示，可跳子计划详情）。
  Future<List<MrpSubplanRef>> mrpSubplans(String id) async {
    final list =
        await api.getList('/production/plans/$id/mrp/subplans'); // ENDPOINT
    return list.map(MrpSubplanRef.fromJson).toList();
  }

  /// 按车间拆分生成子计划：自选自制件行+数量+车间，按车间分组各生成一张草稿。
  /// body items: [{goodsId, colorId?, unitId?, qty, departmentId?, workshopName?}]
  Future<List<SubplanCreated>> mrpGenerateSubplans(
      String id, List<Map<String, dynamic>> items) async {
    final list = await api.postList(
        '/production/plans/$id/mrp/generate-subplans', // ENDPOINT
        body: {'items': items});
    return list.map(SubplanCreated.fromJson).toList();
  }

  // ───────────────────────── 调度工作台（业务链 · 排产段 V90） ─────────────────────────

  /// 待排产订单行（服务端分页；交货升序，urgent=距交货 ≤3 天；dateFrom/dateTo 交货日期范围）。
  Future<PagedResult<SchedulePendingRow>> schedulePending({
    int page = 1,
    int size = 20,
    String keyword = '',
    String? dateFrom,
    String? dateTo,
  }) async {
    final json = await api.get('/production/schedule/pending', query: {
      'page': page,
      'size': size,
      if (keyword.trim().isNotEmpty) 'keyword': keyword.trim(),
      'dateFrom': ?dateFrom,
      'dateTo': ?dateTo,
    }); // ENDPOINT
    return PagedResult.fromJson(json, SchedulePendingRow.fromJson);
  }

  /// 待排产计数（生产部工作台徽标）：{'count': n, 'urgent': m, 'overdue': k}。
  Future<Map<String, int>> schedulePendingCount() async {
    final json = await api.get('/production/schedule/pending-count'); // ENDPOINT
    return {
      'count': (json['count'] as num?)?.toInt() ?? 0,
      'urgent': (json['urgent'] as num?)?.toInt() ?? 0,
      'overdue': (json['overdue'] as num?)?.toInt() ?? 0,
    };
  }

  /// 缺料待备料计数（PMC 采购管理徽标）：{'count': n}。
  Future<Map<String, int>> scheduleShortageCount() async {
    final json = await api.get('/production/schedule/shortage-count'); // ENDPOINT
    return {'count': (json['count'] as num?)?.toInt() ?? 0};
  }

  /// 已审订单明细 + 每行货品一层 BOM 零件（新建计划单「从订单带明细」用）。
  Future<List<ScheduleOrderLine>> scheduleOrderLines(String orderId) async {
    final list = await api.getList('/production/schedule/order-lines',
        query: {'orderId': orderId}); // ENDPOINT
    return list.map(ScheduleOrderLine.fromJson).toList();
  }

  /// 合并排产：勾选订单行 → 草稿计划（同货合并行 + 预建 links）；返回计划 id。
  Future<String> createMergePlan(Map<String, dynamic> body) async {
    final json = await api.post('/production/schedule/merge-plan', body: body); // ENDPOINT
    return json['planId'] as String;
  }

  /// D2 建议完工日期（历史日均完工×BOM 层级缓冲）。
  Future<Map<String, dynamic>> suggestFinish(Map<String, dynamic> body) async {
    final json = await api.post('/production/schedule/suggest-finish', body: body); // ENDPOINT
    return Map<String, dynamic>.from(json as Map);
  }
}

/// 调度工作台待排产行（对应后端 PendingPlanRow）。
class SchedulePendingRow {
  const SchedulePendingRow({
    required this.orderItemId,
    required this.orderId,
    this.orderBillNo,
    this.clientName,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorName,
    this.unitName,
    this.qty,
    this.reservedQty,
    this.plannedQty,
    this.needQty,
    this.deliverDate,
    this.chainStatus,
    this.urgent = false,
  });
  final String orderItemId;
  final String orderId;
  final String? orderBillNo;
  final String? clientName;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorName;
  final String? unitName;
  final double? qty;
  final double? reservedQty;
  final double? plannedQty;
  final double? needQty;
  final String? deliverDate;
  final int? chainStatus;
  final bool urgent;

  factory SchedulePendingRow.fromJson(Map<String, dynamic> j) =>
      SchedulePendingRow(
        orderItemId: j['orderItemId'] as String,
        orderId: j['orderId'] as String,
        orderBillNo: j['orderBillNo'] as String?,
        clientName: j['clientName'] as String?,
        goodsId: j['goodsId'] as String?,
        goodsCode: j['goodsCode'] as String?,
        goodsName: j['goodsName'] as String?,
        spec: j['spec'] as String?,
        colorName: j['colorName'] as String?,
        unitName: j['unitName'] as String?,
        qty: (j['qty'] as num?)?.toDouble(),
        reservedQty: (j['reservedQty'] as num?)?.toDouble(),
        plannedQty: (j['plannedQty'] as num?)?.toDouble(),
        needQty: (j['needQty'] as num?)?.toDouble(),
        deliverDate: j['deliverDate'] as String?,
        chainStatus: (j['chainStatus'] as num?)?.toInt(),
        urgent: j['urgent'] == true,
      );
}

/// 已审订单明细行（含一层 BOM 零件），对应后端 ScheduleOrderLine。
class ScheduleOrderLine {
  const ScheduleOrderLine({
    required this.orderItemId,
    this.lineNo,
    this.goodsId,
    this.goodsCode,
    this.goodsName,
    this.spec,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.qty,
    this.plannedQty,
    this.needQty,
    this.unitRate,
    this.deliverDate,
    this.orderBillNo,
    this.clientName,
    this.bom = const [],
  });
  final String orderItemId;
  final int? lineNo;
  final String? goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final double? qty;
  final double? plannedQty;
  final double? needQty;
  final double? unitRate;
  final String? deliverDate;
  final String? orderBillNo;
  final String? clientName;
  final List<ScheduleBomComponent> bom;

  factory ScheduleOrderLine.fromJson(Map<String, dynamic> j) =>
      ScheduleOrderLine(
        orderItemId: j['orderItemId'] as String,
        lineNo: (j['lineNo'] as num?)?.toInt(),
        goodsId: j['goodsId'] as String?,
        goodsCode: j['goodsCode'] as String?,
        goodsName: j['goodsName'] as String?,
        spec: j['spec'] as String?,
        colorId: j['colorId'] as String?,
        colorName: j['colorName'] as String?,
        unitId: j['unitId'] as String?,
        unitName: j['unitName'] as String?,
        qty: (j['qty'] as num?)?.toDouble(),
        plannedQty: (j['plannedQty'] as num?)?.toDouble(),
        needQty: (j['needQty'] as num?)?.toDouble(),
        unitRate: (j['unitRate'] as num?)?.toDouble(),
        deliverDate: j['deliverDate'] as String?,
        orderBillNo: j['orderBillNo'] as String?,
        clientName: j['clientName'] as String?,
        bom: [
          for (final b in (j['bom'] as List? ?? const []))
            ScheduleBomComponent.fromJson(b as Map<String, dynamic>),
        ],
      );
}

/// 货品一层 BOM 零件（单件用量 × 待排产缺口 = 需求小计）。
class ScheduleBomComponent {
  const ScheduleBomComponent({
    required this.goodsId,
    this.code,
    this.name,
    this.spec,
    this.perQty,
    this.needQty,
    this.onhand,
    this.selfMade = false,
  });
  final String goodsId;
  final String? code;
  final String? name;
  final String? spec;
  final double? perQty;
  final double? needQty;
  final double? onhand;
  final bool selfMade;

  factory ScheduleBomComponent.fromJson(Map<String, dynamic> j) =>
      ScheduleBomComponent(
        goodsId: j['goodsId'] as String,
        code: j['code'] as String?,
        name: j['name'] as String?,
        spec: j['spec'] as String?,
        perQty: (j['perQty'] as num?)?.toDouble(),
        needQty: (j['needQty'] as num?)?.toDouble(),
        onhand: (j['onhand'] as num?)?.toDouble(),
        selfMade: j['selfMade'] == true,
      );
}

/// 生产进度看板行（对应后端 PlanProgressRow）。
class PlanProgressRow {
  const PlanProgressRow({
    required this.planId,
    this.billNo,
    this.billDate,
    this.deliveryDate,
    this.workshopName,
    this.departmentId,
    this.lineCount = 0,
    this.totalQty,
    this.inboundQty,
    this.planBeginDate,
    this.planEndDate,
    this.percent = 0,
    this.closed = false,
    this.urgent = false,
    this.overdue = false,
    this.pinned = false,
    this.important = false,
    this.todayQty,
    this.subplans = const [],
  });
  final String planId;
  final String? billNo;
  final String? billDate;
  final String? deliveryDate;
  final String? workshopName;
  final String? departmentId;
  final int lineCount;
  final double? totalQty;
  final double? inboundQty;
  final String? planBeginDate;
  final String? planEndDate;
  final double percent;
  final bool closed;
  final bool urgent;
  final bool overdue;
  final bool pinned;
  final bool important;
  final double? todayQty;
  final List<SubPlanProgress> subplans;

  factory PlanProgressRow.fromJson(Map<String, dynamic> j) => PlanProgressRow(
        planId: j['planId'] as String,
        billNo: j['billNo'] as String?,
        billDate: j['billDate'] as String?,
        deliveryDate: j['deliveryDate'] as String?,
        workshopName: j['workshopName'] as String?,
        departmentId: j['departmentId'] as String?,
        lineCount: (j['lineCount'] as num?)?.toInt() ?? 0,
        totalQty: (j['totalQty'] as num?)?.toDouble(),
        inboundQty: (j['inboundQty'] as num?)?.toDouble(),
        planBeginDate: j['planBeginDate'] as String?,
        planEndDate: j['planEndDate'] as String?,
        percent: (j['percent'] as num?)?.toDouble() ?? 0,
        closed: j['closed'] == true,
        urgent: j['urgent'] == true,
        overdue: j['overdue'] == true,
        pinned: j['pinned'] == true,
        important: j['important'] == true,
        todayQty: (j['todayQty'] as num?)?.toDouble(),
        subplans: [
          for (final s in (j['subplans'] as List? ?? const []))
            SubPlanProgress.fromJson(s as Map<String, dynamic>),
        ],
      );

  /// 看板标记本地乐观更新用（置顶/重要）。
  PlanProgressRow copyWith({bool? pinned, bool? important}) => PlanProgressRow(
        planId: planId,
        billNo: billNo,
        billDate: billDate,
        deliveryDate: deliveryDate,
        workshopName: workshopName,
        departmentId: departmentId,
        lineCount: lineCount,
        totalQty: totalQty,
        inboundQty: inboundQty,
        planBeginDate: planBeginDate,
        planEndDate: planEndDate,
        percent: percent,
        closed: closed,
        urgent: urgent,
        overdue: overdue,
        pinned: pinned ?? this.pinned,
        important: important ?? this.important,
        todayQty: todayQty,
        subplans: subplans,
      );
}

/// 子计划嵌套进度（对应后端 PlanProgressRow.SubProgress）。
class SubPlanProgress {
  const SubPlanProgress({
    required this.planId,
    this.billNo,
    this.workshopName,
    this.status,
    this.closed = false,
    this.totalQty,
    this.inboundQty,
    this.percent = 0,
  });
  final String planId;
  final String? billNo;
  final String? workshopName;
  final int? status;
  final bool closed;
  final double? totalQty;
  final double? inboundQty;
  final double percent;

  factory SubPlanProgress.fromJson(Map<String, dynamic> j) => SubPlanProgress(
        planId: j['planId'] as String,
        billNo: j['billNo'] as String?,
        workshopName: j['workshopName'] as String?,
        status: (j['status'] as num?)?.toInt(),
        closed: j['closed'] == true,
        totalQty: (j['totalQty'] as num?)?.toDouble(),
        inboundQty: (j['inboundQty'] as num?)?.toDouble(),
        percent: (j['percent'] as num?)?.toDouble() ?? 0,
      );
}

/// MRP 预览行。
class MrpRow {  const MrpRow({
    required this.goodsId, this.goodsCode, this.goodsName, this.spec,
    this.colorId, this.gross, this.onhand, this.openPo, this.net,
    required this.selfMade, this.unitId,
  });
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? spec;
  final String? colorId;
  final double? gross;
  final double? onhand;
  final double? openPo;
  final double? net;
  final bool selfMade;
  final String? unitId;

  factory MrpRow.fromJson(Map<String, dynamic> j) => MrpRow(
        goodsId: j['goodsId'] as String,
        goodsCode: j['goodsCode'] as String?,
        goodsName: j['goodsName'] as String?,
        spec: j['spec'] as String?,
        colorId: j['colorId'] as String?,
        gross: (j['gross'] as num?)?.toDouble(),
        onhand: (j['onhand'] as num?)?.toDouble(),
        openPo: (j['openPo'] as num?)?.toDouble(),
        net: (j['net'] as num?)?.toDouble(),
        selfMade: j['selfMade'] == true,
        unitId: j['unitId'] as String?,
      );
}

/// MRP 生成结果。
class MrpGenerateResult {
  const MrpGenerateResult({required this.requestId, required this.requestBillNo, required this.lineCount});
  final String requestId;
  final String requestBillNo;
  final int lineCount;

  factory MrpGenerateResult.fromJson(Map<String, dynamic> j) => MrpGenerateResult(
        requestId: j['requestId'] as String,
        requestBillNo: j['requestBillNo'] as String,
        lineCount: (j['lineCount'] as num).toInt(),
      );
}

/// 拆分生成的一张子计划结果（对应后端 GenerateSubplansRequest.Created）。
class SubplanCreated {
  const SubplanCreated({
    required this.planId,
    this.billNo,
    this.lineCount = 0,
    this.workshopName,
  });
  final String planId;
  final String? billNo;
  final int lineCount;
  final String? workshopName;

  factory SubplanCreated.fromJson(Map<String, dynamic> j) => SubplanCreated(
        planId: j['planId'] as String,
        billNo: j['billNo'] as String?,
        lineCount: (j['lineCount'] as num?)?.toInt() ?? 0,
        workshopName: j['workshopName'] as String?,
      );
}

/// 自制件子计划溯源行（父计划 MRP 面板/详情页进度区展示用，含完工进度）。
class MrpSubplanRef {
  const MrpSubplanRef({
    required this.planId,
    this.billNo,
    this.status,
    this.closed = false,
    this.billDate,
    this.deliveryDate,
    this.totalQty,
    this.inboundQty,
    this.percent = 0,
  });
  final String planId;
  final String? billNo;
  final int? status; // 0草稿 1已审 -1红冲
  final bool closed;
  final String? billDate;
  final String? deliveryDate;
  final double? totalQty;
  final double? inboundQty;
  final double percent;

  factory MrpSubplanRef.fromJson(Map<String, dynamic> j) => MrpSubplanRef(
        planId: j['planId'] as String,
        billNo: j['billNo'] as String?,
        status: (j['status'] as num?)?.toInt(),
        closed: j['closed'] == true,
        billDate: j['billDate'] as String?,
        deliveryDate: j['deliveryDate'] as String?,
        totalQty: (j['totalQty'] as num?)?.toDouble(),
        inboundQty: (j['inboundQty'] as num?)?.toDouble(),
        percent: (j['percent'] as num?)?.toDouble() ?? 0,
      );
}

// ───────────────────────── 生产日报（空结构保未来） ─────────────────────────

class ProductionDailyReportFilter {
  const ProductionDailyReportFilter({
    this.keyword,
    this.warehouseId,
    this.departmentId,
    this.workerId,
    this.status,
    this.dateFrom,
    this.dateTo,
  });

  final String? keyword;
  final String? warehouseId;
  final String? departmentId;
  final String? workerId;
  final int? status;
  final String? dateFrom;
  final String? dateTo;

  Map<String, dynamic> toQuery() => <String, dynamic>{
        if (keyword != null && keyword!.trim().isNotEmpty) 'keyword': keyword!.trim(),
        if (warehouseId != null) 'warehouseId': warehouseId,
        if (departmentId != null) 'departmentId': departmentId,
        if (workerId != null) 'workerId': workerId,
        if (status != null) 'status': status,
        if (dateFrom != null) 'dateFrom': dateFrom,
        if (dateTo != null) 'dateTo': dateTo,
      };
}

class ProductionDailyReportRepository {
  ProductionDailyReportRepository(this.api);
  final ApiClient api;

  Future<PagedResult<ProductionDailyReportListItem>> list({
    int page = 1,
    int size = 20,
    ProductionDailyReportFilter filter = const ProductionDailyReportFilter(),
    String? sort,
    String? order,
  }) async {
    final query = <String, dynamic>{
      'page': page,
      'size': size,
      ...filter.toQuery(),
      if (sort != null && sort.isNotEmpty) 'sort': sort,
      if (order != null && order.isNotEmpty) 'order': order,
    };
    final json = await api.get('/production/daily-reports', query: query); // ENDPOINT
    return PagedResult.fromJson(json, ProductionDailyReportListItem.fromJson);
  }

  Future<ProductionDailyReportDetail> detail(String id) async {
    final json = await api.get('/production/daily-reports/$id'); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }

  Future<ProductionDailyReportDetail> create(Map<String, dynamic> body) async {
    final json = await api.post('/production/daily-reports', body: body); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }

  Future<ProductionDailyReportDetail> update(String id, Map<String, dynamic> body) async {
    final json = await api.put('/production/daily-reports/$id', body: body); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }

  Future<void> delete(String id) async {
    await api.delete('/production/daily-reports/$id'); // ENDPOINT
  }

  Future<ProductionDailyReportDetail> approve(String id) async {
    final json = await api.post('/production/daily-reports/$id/approve'); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }

  Future<ProductionDailyReportDetail> reverse(String id) async {
    final json = await api.post('/production/daily-reports/$id/reverse'); // ENDPOINT
    return ProductionDailyReportDetail.fromJson(json);
  }
}

// ───────────────────────── 生产报表（4 入口） ─────────────────────────

/// 报表通用过滤（明细带分页 + 单号/状态；汇总仅日期 + limit）。
class ProductionReportFilter {
  const ProductionReportFilter({
    this.dateFrom,
    this.dateTo,
    this.goodsId,
    this.status,
    this.billNo,
    this.page = 1,
    this.size = 50,
    this.limit = 200,
  });

  final String? dateFrom;
  final String? dateTo;
  final String? goodsId;
  final int? status; // 明细：plan/daily 头 status
  final String? billNo; // 明细：精确匹配
  final int page;
  final int size;
  final int limit;

  Map<String, dynamic> toDetailQuery() => <String, dynamic>{
        if (dateFrom != null) 'dateFrom': dateFrom,
        if (dateTo != null) 'dateTo': dateTo,
        if (goodsId != null) 'goodsId': goodsId,
        if (status != null) 'status': status,
        if (billNo != null && billNo!.trim().isNotEmpty) 'billNo': billNo!.trim(),
        'page': page,
        'size': size,
      };

  Map<String, dynamic> toSummaryQuery() => <String, dynamic>{
        if (dateFrom != null) 'dateFrom': dateFrom,
        if (dateTo != null) 'dateTo': dateTo,
        'limit': limit,
      };
}

class ProductionReportRepository {
  ProductionReportRepository(this.api);
  final ApiClient api;

  /// 计划明细报表（分页，裸数组）。
  Future<List<ProductionPlanDetailReportRow>> planDetail({
    ProductionReportFilter filter = const ProductionReportFilter(),
  }) async {
    final list = await api.getList('/production/reports/plan/detail', query: filter.toDetailQuery()); // ENDPOINT
    return list.map(ProductionPlanDetailReportRow.fromJson).toList();
  }

  /// 计划汇总报表（MV doc_type='PLAN'）。
  Future<List<ProductionMonthlySummaryRow>> planSummary({
    ProductionReportFilter filter = const ProductionReportFilter(),
  }) async {
    final list = await api.getList('/production/reports/plan/summary', query: filter.toSummaryQuery()); // ENDPOINT
    return list.map(ProductionMonthlySummaryRow.fromJson).toList();
  }

  /// 日报明细报表（分页，0 行）。
  Future<List<ProductionDailyDetailReportRow>> dailyDetail({
    ProductionReportFilter filter = const ProductionReportFilter(),
  }) async {
    final list = await api.getList('/production/reports/daily/detail', query: filter.toDetailQuery()); // ENDPOINT
    return list.map(ProductionDailyDetailReportRow.fromJson).toList();
  }

  /// 日报汇总报表（MV doc_type='DAILY'，0 行）。
  Future<List<ProductionMonthlySummaryRow>> dailySummary({
    ProductionReportFilter filter = const ProductionReportFilter(),
  }) async {
    final list = await api.getList('/production/reports/daily/summary', query: filter.toSummaryQuery()); // ENDPOINT
    return list.map(ProductionMonthlySummaryRow.fromJson).toList();
  }
}

// ───────────────────────── Providers ─────────────────────────
// 3 个 plain Provider（无 family 参数，区别于 purchase 的 .family(docType)）。
// 命名带 Production 前缀避免与占位 mock 的 productionRepositoryProvider 冲突。

final productionPlanRepositoryProvider = Provider<ProductionPlanRepository>(
  (ref) => ProductionPlanRepository(ref.watch(apiClientProvider)),
);

final productionDailyReportRepositoryProvider =
    Provider<ProductionDailyReportRepository>(
  (ref) => ProductionDailyReportRepository(ref.watch(apiClientProvider)),
);

final productionReportRepositoryProvider = Provider<ProductionReportRepository>(
  (ref) => ProductionReportRepository(ref.watch(apiClientProvider)),
);

/// 报表数据联合体（明细/汇总统一承载；页面按 reportType 分支取用）。
sealed class ProductionReportData {}

class ProductionReportDetailData extends ProductionReportData {
  ProductionReportDetailData(this.planRows, this.dailyRows);
  final List<ProductionPlanDetailReportRow> planRows;
  final List<ProductionDailyDetailReportRow> dailyRows;
}

class ProductionReportSummaryData extends ProductionReportData {
  ProductionReportSummaryData(this.rows);
  final List<ProductionMonthlySummaryRow> rows;
}

/// 通用加载入口（按 reportType 路由到具体端点；供 report page 调用）。
Future<ProductionReportData> loadProductionReport(
  ProductionReportType type,
  ProductionReportRepository repo,
  ProductionReportFilter filter,
) async {
  switch (type) {
    case ProductionReportType.planDetail:
      return ProductionReportDetailData(await repo.planDetail(filter: filter), const []);
    case ProductionReportType.dailyDetail:
      return ProductionReportDetailData(const [], await repo.dailyDetail(filter: filter));
    case ProductionReportType.planSummary:
      return ProductionReportSummaryData(await repo.planSummary(filter: filter));
    case ProductionReportType.dailySummary:
      return ProductionReportSummaryData(await repo.dailySummary(filter: filter));
  }
}

/// 沿用 purchase 的错误文案策略（ApiException 取 message，其余给中性提示）。
String productionErrorMessage(Object e, {String fallback = '操作失败，请稍后重试'}) =>
    e is ApiException ? e.message : fallback;
