// ADR-143 委外按工序领直属物料：委外任务中心「领料」分段、任务详情与领料页的数据模型。
//
// 一行 = 一条已获财务批准、领料计划未结束、仍未领满的委外订货明细(委外任务)。
// 所有数量(已领 / 待仓库发 / 可领 / 还缺 / 本批可领)都由服务端在一处算好
// (ADR-143 §三「只在服务端算一次」)；客户端只显示，不做任何加减推算。
// 数量单位：任务行 = 委外件的订货单位；物料行 = 各物料自己的单位。
import '../../../shared/models/paged_result.dart';

/// 「领料」分段任务行状态(服务端 status)。
enum SubcontractDrawStatus {
  /// 可领 = 剩余全部(蓝)。
  drawable('DRAWABLE'),

  /// 部分可领(紫)。
  drawablePartial('DRAWABLE_PARTIAL'),

  /// 已提交领料·待仓库发料(青)。
  drawSubmitted('DRAW_SUBMITTED'),

  /// 还缺的物料没有在途供应，等计划安排(品红)。
  waitingPlanning('WAITING_PLANNING'),

  /// 等待物料到货(灰蓝)。
  waitingMaterial('WAITING_MATERIAL'),

  /// 服务端新增而本端不认识的状态：按等待物料展示，不放行任何动作。
  unknown('');

  const SubcontractDrawStatus(this.wireName);

  final String wireName;

  bool get isDrawable => this == drawable || this == drawablePartial;

  static SubcontractDrawStatus fromWire(Object? value) {
    final text = value?.toString().trim().toUpperCase() ?? '';
    for (final status in values) {
      if (status != unknown && status.wireName == text) return status;
    }
    return unknown;
  }
}

/// 「领料」分段的一行(GET /subcontract/draw-tasks 的 page.items[])。
class SubcontractDrawTaskRow {
  const SubcontractDrawTaskRow({
    required this.orderItemId,
    required this.orderId,
    required this.orderBillNo,
    required this.lineNo,
    required this.supplierId,
    required this.supplierName,
    required this.goodsId,
    required this.goodsCode,
    required this.goodsName,
    required this.colorId,
    required this.colorName,
    required this.unitId,
    required this.unitName,
    required this.orderQty,
    required this.drawnQty,
    required this.pendingQty,
    required this.drawableQty,
    required this.shortQty,
    required this.materialKindCount,
    required this.readyKindCount,
    required this.shortKindCount,
    required this.unplannedShortKindCount,
    required this.status,
    required this.deliverDate,
    required this.canDraw,
  });

  final String orderItemId;
  final String orderId;
  final String orderBillNo;
  final int? lineNo;
  final String? supplierId;
  final String supplierName;
  final String? goodsId;
  final String goodsCode;
  final String goodsName;
  final String? colorId;
  final String colorName;
  final String? unitId;
  final String unitName;

  /// 订货数量(委外件订货单位)。
  final double orderQty;

  /// 已领 = 已发齐的完整套数。
  final double drawnQty;

  /// 待仓库发 = 已提交领料、仓库尚未发出的套数。
  final double pendingQty;

  /// 可领 = 现有库存还能配齐的套数。
  final double drawableQty;

  /// 还缺 = 订货数量 − 已领 − 待仓库发 − 可领。
  final double shortQty;
  final int materialKindCount;

  /// 已备 = 还缺为 0 的物料种数。
  final int readyKindCount;
  final int shortKindCount;

  /// 还缺且没有在途供应(未安排)的物料种数。
  final int unplannedShortKindCount;
  final SubcontractDrawStatus status;
  final String? deliverDate;

  /// 服务端判定本行可勾选进入领料页(与账号能力 canSubmitDraw 同时成立才可勾)。
  final bool canDraw;

  factory SubcontractDrawTaskRow.fromJson(Map<String, dynamic> json) =>
      SubcontractDrawTaskRow(
        orderItemId: _requiredString(json, 'orderItemId'),
        orderId: _string(json, 'orderId') ?? '',
        orderBillNo: _string(json, 'orderBillNo') ?? '',
        lineNo: _int(json, 'lineNo'),
        supplierId: _string(json, 'supplierId'),
        supplierName: _string(json, 'supplierName') ?? '',
        goodsId: _string(json, 'goodsId'),
        goodsCode: _string(json, 'goodsCode') ?? '',
        goodsName: _string(json, 'goodsName') ?? '',
        colorId: _string(json, 'colorId'),
        colorName: _string(json, 'colorName') ?? '',
        unitId: _string(json, 'unitId'),
        unitName: _string(json, 'unitName') ?? '',
        orderQty: _double(json, 'orderQty'),
        drawnQty: _double(json, 'drawnQty'),
        pendingQty: _double(json, 'pendingQty'),
        drawableQty: _double(json, 'drawableQty'),
        shortQty: _double(json, 'shortQty'),
        materialKindCount: _int(json, 'materialKindCount') ?? 0,
        readyKindCount: _int(json, 'readyKindCount') ?? 0,
        shortKindCount: _int(json, 'shortKindCount') ?? 0,
        unplannedShortKindCount: _int(json, 'unplannedShortKindCount') ?? 0,
        status: SubcontractDrawStatus.fromWire(json['status']),
        deliverDate: _string(json, 'deliverDate'),
        canDraw: json['canDraw'] == true,
      );
}

/// GET /subcontract/draw-tasks 的完整响应：分页行 + 状态计数 + 账号能力。
class SubcontractDrawTaskList {
  const SubcontractDrawTaskList({
    required this.page,
    required this.statusCounts,
    required this.canSubmitDraw,
  });

  final PagedResult<SubcontractDrawTaskRow> page;

  /// DRAWABLE / DRAW_SUBMITTED / WAITING_PLANNING / WAITING_MATERIAL / ALL。
  final Map<String, int> statusCounts;

  /// 账号能否提交领料(服务端按 subcontract_order:draw 与对象范围给出)。
  final bool canSubmitDraw;

  factory SubcontractDrawTaskList.fromJson(Map<String, dynamic> json) {
    final page = json['page'];
    if (page is! Map) {
      throw const FormatException('委外领料任务列表数据不完整，请刷新重试');
    }
    return SubcontractDrawTaskList(
      page: PagedResult.fromJson(
        page.cast<String, dynamic>(),
        SubcontractDrawTaskRow.fromJson,
      ),
      statusCounts: {
        for (final entry in (json['statusCounts'] as Map? ?? const {}).entries)
          if (entry.value is num)
            entry.key.toString(): (entry.value as num).toInt(),
      },
      canSubmitDraw: (json['capabilities'] as Map?)?['canSubmitDraw'] == true,
    );
  }
}

/// 物料在途供应来源(任务详情「供应来源」列)。
class SubcontractDrawSupplySource {
  const SubcontractDrawSupplySource({
    required this.kind,
    required this.docId,
    required this.docNo,
    required this.openQty,
  });

  /// PURCHASE / PRODUCTION / SUBCONTRACT。
  final String kind;
  final String? docId;
  final String docNo;
  final double openQty;

  factory SubcontractDrawSupplySource.fromJson(Map<String, dynamic> json) =>
      SubcontractDrawSupplySource(
        kind: _string(json, 'kind')?.toUpperCase() ?? '',
        docId: _string(json, 'docId'),
        docNo: _string(json, 'docNo') ?? '',
        openQty: _double(json, 'openQty'),
      );
}

/// 任务详情的一种直属物料(冻结计划行)。
class SubcontractDrawMaterial {
  const SubcontractDrawMaterial({
    required this.planItemId,
    required this.lineNo,
    required this.goodsId,
    required this.goodsCode,
    required this.goodsName,
    required this.colorId,
    required this.colorName,
    required this.unitId,
    required this.unitName,
    required this.perUnitQty,
    required this.requiredQty,
    required this.sentQty,
    required this.pendingQty,
    required this.availableQty,
    required this.drawableQty,
    required this.shortQty,
    required this.state,
    required this.supplySources,
  });

  final String planItemId;
  final int? lineNo;
  final String? goodsId;
  final String goodsCode;
  final String goodsName;
  final String? colorId;
  final String colorName;
  final String? unitId;
  final String unitName;

  /// 每套用量(批准时冻结)。
  final double perUnitQty;
  final double requiredQty;
  final double sentQty;
  final double pendingQty;
  final double availableQty;
  final double drawableQty;
  final double shortQty;

  /// SENT_FULL / PENDING / DRAWABLE / SHORT / CLOSED。
  final String state;
  final List<SubcontractDrawSupplySource> supplySources;

  factory SubcontractDrawMaterial.fromJson(Map<String, dynamic> json) =>
      SubcontractDrawMaterial(
        planItemId: _requiredString(json, 'planItemId'),
        lineNo: _int(json, 'lineNo'),
        goodsId: _string(json, 'goodsId'),
        goodsCode: _string(json, 'goodsCode') ?? '',
        goodsName: _string(json, 'goodsName') ?? '',
        colorId: _string(json, 'colorId'),
        colorName: _string(json, 'colorName') ?? '',
        unitId: _string(json, 'unitId'),
        unitName: _string(json, 'unitName') ?? '',
        perUnitQty: _double(json, 'perUnitQty'),
        requiredQty: _double(json, 'requiredQty'),
        sentQty: _double(json, 'sentQty'),
        pendingQty: _double(json, 'pendingQty'),
        availableQty: _double(json, 'availableQty'),
        drawableQty: _double(json, 'drawableQty'),
        shortQty: _double(json, 'shortQty'),
        state: _string(json, 'state')?.toUpperCase() ?? '',
        supplySources: _list(
          json['supplySources'],
          SubcontractDrawSupplySource.fromJson,
        ),
      );
}

/// 已提交、仓库尚未发出的领料出仓草稿。
class SubcontractDrawPendingDraft {
  const SubcontractDrawPendingDraft({
    required this.issueId,
    required this.billNo,
    required this.warehouseId,
    required this.warehouseName,
    required this.lineCount,
    required this.submittedAt,
    required this.submittedByName,
    this.edited = false,
  });

  final String issueId;
  final String billNo;
  final String? warehouseId;
  final String warehouseName;
  final int lineCount;
  final String? submittedAt;
  final String submittedByName;

  /// 仓库拣货时已改过这张领料单(改了数量或删了行)：委外这边不能再撤回，
  /// 要不发请仓库在拣货页「退回委外(不发)」。
  final bool edited;

  factory SubcontractDrawPendingDraft.fromJson(Map<String, dynamic> json) =>
      SubcontractDrawPendingDraft(
        issueId: _requiredString(json, 'issueId'),
        billNo: _string(json, 'billNo') ?? '',
        warehouseId: _string(json, 'warehouseId'),
        warehouseName: _string(json, 'warehouseName') ?? '',
        lineCount: _int(json, 'lineCount') ?? 0,
        submittedAt: _string(json, 'submittedAt'),
        submittedByName: _string(json, 'submittedByName') ?? '',
        edited: json['edited'] == true,
      );
}

/// GET /subcontract/draw-tasks/{orderItemId}/materials。
class SubcontractDrawTaskDetail {
  const SubcontractDrawTaskDetail({
    required this.task,
    required this.materials,
    required this.pendingDrafts,
    required this.allowedActions,
  });

  static const withdrawAction = 'WITHDRAW';
  static const closeAction = 'CLOSE';

  final SubcontractDrawTaskRow task;
  final List<SubcontractDrawMaterial> materials;
  final List<SubcontractDrawPendingDraft> pendingDrafts;

  /// 服务端放行的动作：WITHDRAW(撤回未发领料) / CLOSE(结束领料)。
  final Set<String> allowedActions;

  bool allows(String action) => allowedActions.contains(action);

  factory SubcontractDrawTaskDetail.fromJson(Map<String, dynamic> json) {
    final task = json['task'];
    if (task is! Map) {
      throw const FormatException('委外领料任务详情数据不完整，请刷新重试');
    }
    return SubcontractDrawTaskDetail(
      task: SubcontractDrawTaskRow.fromJson(task.cast<String, dynamic>()),
      materials: _list(json['materials'], SubcontractDrawMaterial.fromJson),
      pendingDrafts: _list(
        json['pendingDrafts'],
        SubcontractDrawPendingDraft.fromJson,
      ),
      allowedActions: {
        for (final action in (json['allowedActions'] as List? ?? const []))
          action.toString().trim().toUpperCase(),
      },
    );
  }
}

/// 领料页提交/预览的一项：委外订货明细 + 本次领料数量(null = 服务端默认本批可领)。
class SubcontractDrawRequestItem {
  const SubcontractDrawRequestItem({required this.orderItemId, this.qty});

  final String orderItemId;
  final num? qty;

  Map<String, dynamic> toJson() => {'orderItemId': orderItemId, 'qty': qty};
}

/// 领料页任务表一行(POST /preview 的 tasks[])。
class SubcontractDrawPreviewTask {
  const SubcontractDrawPreviewTask({
    required this.orderItemId,
    required this.orderId,
    required this.orderBillNo,
    required this.lineNo,
    required this.supplierName,
    required this.goodsId,
    required this.goodsCode,
    required this.goodsName,
    required this.colorName,
    required this.unitName,
    required this.orderQty,
    required this.drawnQty,
    required this.drawableQty,
    required this.batchDrawableQty,
    required this.qty,
  });

  final String orderItemId;
  final String orderId;
  final String orderBillNo;
  final int? lineNo;
  final String supplierName;
  final String? goodsId;
  final String goodsCode;
  final String goodsName;
  final String colorName;
  final String unitName;
  final double orderQty;
  final double drawnQty;
  final double drawableQty;

  /// 本批可领：同一批量领料按「交期、订货单号、行号」联合分配共享物料后的可领量。
  final double batchDrawableQty;

  /// 本次领料数量(请求未指定时 = 本批可领)。
  final double qty;

  factory SubcontractDrawPreviewTask.fromJson(Map<String, dynamic> json) =>
      SubcontractDrawPreviewTask(
        orderItemId: _requiredString(json, 'orderItemId'),
        orderId: _string(json, 'orderId') ?? '',
        orderBillNo: _string(json, 'orderBillNo') ?? '',
        lineNo: _int(json, 'lineNo'),
        supplierName: _string(json, 'supplierName') ?? '',
        goodsId: _string(json, 'goodsId'),
        goodsCode: _string(json, 'goodsCode') ?? '',
        goodsName: _string(json, 'goodsName') ?? '',
        colorName: _string(json, 'colorName') ?? '',
        unitName: _string(json, 'unitName') ?? '',
        orderQty: _double(json, 'orderQty'),
        drawnQty: _double(json, 'drawnQty'),
        drawableQty: _double(json, 'drawableQty'),
        batchDrawableQty: _double(json, 'batchDrawableQty'),
        qty: _double(json, 'qty'),
      );
}

/// 领料页物料表一行(POST /preview 的 lines[])：某仓库本次要发出的某种物料。
class SubcontractDrawPreviewLine {
  const SubcontractDrawPreviewLine({
    required this.orderItemId,
    required this.planItemId,
    required this.warehouseId,
    required this.warehouseName,
    required this.goodsId,
    required this.goodsCode,
    required this.goodsName,
    required this.colorId,
    required this.colorName,
    required this.unitId,
    required this.unitName,
    required this.qty,
    required this.warehouseAvailableQty,
  });

  final String orderItemId;
  final String planItemId;
  final String? warehouseId;
  final String warehouseName;
  final String? goodsId;
  final String goodsCode;
  final String goodsName;
  final String? colorId;
  final String colorName;
  final String? unitId;
  final String unitName;
  final double qty;
  final double warehouseAvailableQty;

  /// 表格行身份(同一明细同一计划行可能从多个仓库出)。
  String get identity => '$orderItemId|$planItemId|${warehouseId ?? ''}';

  /// 物料身份(货品 + 颜色)，用于统计「M 种物料」。
  String get materialIdentity => '${goodsId ?? goodsCode}|${colorId ?? ''}';

  factory SubcontractDrawPreviewLine.fromJson(Map<String, dynamic> json) =>
      SubcontractDrawPreviewLine(
        orderItemId: _requiredString(json, 'orderItemId'),
        planItemId: _string(json, 'planItemId') ?? '',
        warehouseId: _string(json, 'warehouseId'),
        warehouseName: _string(json, 'warehouseName') ?? '',
        goodsId: _string(json, 'goodsId'),
        goodsCode: _string(json, 'goodsCode') ?? '',
        goodsName: _string(json, 'goodsName') ?? '',
        colorId: _string(json, 'colorId'),
        colorName: _string(json, 'colorName') ?? '',
        unitId: _string(json, 'unitId'),
        unitName: _string(json, 'unitName') ?? '',
        qty: _double(json, 'qty'),
        warehouseAvailableQty: _double(json, 'warehouseAvailableQty'),
      );
}

/// POST /subcontract/draw-tasks/preview。
class SubcontractDrawPreview {
  const SubcontractDrawPreview({
    required this.tasks,
    required this.lines,
    required this.documentCount,
  });

  final List<SubcontractDrawPreviewTask> tasks;
  final List<SubcontractDrawPreviewLine> lines;

  /// 预计生成的出仓单张数(订货单 × 仓库)。
  final int documentCount;

  int get materialKindCount =>
      lines.map((line) => line.materialIdentity).toSet().length;

  SubcontractDrawPreviewTask? taskFor(String orderItemId) =>
      tasks.where((task) => task.orderItemId == orderItemId).firstOrNull;

  factory SubcontractDrawPreview.fromJson(Map<String, dynamic> json) =>
      SubcontractDrawPreview(
        tasks: _list(json['tasks'], SubcontractDrawPreviewTask.fromJson),
        lines: _list(json['lines'], SubcontractDrawPreviewLine.fromJson),
        documentCount: _int(json, 'documentCount') ?? 0,
      );
}

/// POST /subcontract/draw-tasks/submit。
class SubcontractDrawSubmitResult {
  const SubcontractDrawSubmitResult({
    required this.issueIds,
    required this.issueBillNos,
    required this.documentCount,
    required this.replayed,
  });

  final List<String> issueIds;
  final List<String> issueBillNos;
  final int documentCount;

  /// 同一幂等键的重复提交：返回第一次的结果，没有再建单。
  final bool replayed;

  factory SubcontractDrawSubmitResult.fromJson(Map<String, dynamic> json) =>
      SubcontractDrawSubmitResult(
        issueIds: _strings(json['issueIds']),
        issueBillNos: _strings(json['issueBillNos']),
        documentCount: _int(json, 'documentCount') ?? 0,
        replayed: json['replayed'] == true,
      );
}

/// POST /subcontract/draw-tasks/withdraw。
class SubcontractDrawWithdrawResult {
  const SubcontractDrawWithdrawResult({
    required this.withdrawnIssueIds,
    required this.removedLineCount,
  });

  final List<String> withdrawnIssueIds;
  final int removedLineCount;

  factory SubcontractDrawWithdrawResult.fromJson(Map<String, dynamic> json) =>
      SubcontractDrawWithdrawResult(
        withdrawnIssueIds: _strings(json['withdrawnIssueIds']),
        removedLineCount: _int(json, 'removedLineCount') ?? 0,
      );
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = _string(json, key);
  if (value == null) throw FormatException('委外领料字段 $key 缺失');
  return value;
}

String? _string(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  final text = value.toString().trim();
  return text.isEmpty ? null : text;
}

int? _int(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double _double(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? 0;
  return 0;
}

List<String> _strings(Object? raw) => [
  for (final value in (raw as List? ?? const []))
    if (value != null && value.toString().trim().isNotEmpty)
      value.toString().trim(),
];

List<T> _list<T>(Object? raw, T Function(Map<String, dynamic>) fromJson) => [
  for (final row in (raw as List? ?? const []))
    if (row is Map) fromJson(row.cast<String, dynamic>()),
];
