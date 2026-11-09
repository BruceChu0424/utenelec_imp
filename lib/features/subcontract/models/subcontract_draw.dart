import '../../../shared/measurement/document_quantity.dart';
import '../../../shared/formatters/exact_decimal.dart';
// ADR-143 委外按工序领直属物料：委外任务中心「待处理」拍平表的领料行(ADR-171 修订二)、
// 任务详情与领料页的数据模型。
//
// 一行 = 一条已获财务批准、领料计划未结束、仍未领满的委外订货明细(委外任务)。
// 所有数量(已领 / 待仓库发 / 可领 / 还缺 / 本批可领)都由服务端在一处算好
// (ADR-143 §三「只在服务端算一次」)；客户端只显示，不做任何加减推算。
// 任务行保留用于分配的套数；物料按「种」分桶(2026-11-09 任务中心「物料」列)，
// 物料自己的实物数量只在任务详情/物料弹窗逐行显示，不在任务行上合成一个数。
import '../../../shared/models/paged_result.dart';
import '../../../shared/models/historical_receipt_facts.dart';
import '../../basic_data/models/master_facet.dart';

/// 「待处理」领料行状态(服务端 status)。档位注释为 ADR-169 十档
/// （实际取色见 widgets/subcontract_draw_status.dart 的 subcontractDrawCellColor）。
enum SubcontractDrawStatus {
  /// 可领 = 剩余全部(绿，就绪可动手)。
  drawable('DRAWABLE'),

  /// 部分可领(紫，部分就绪)。
  drawablePartial('DRAWABLE_PARTIAL'),

  /// 已提交领料·待仓库发料(青，等仓库)。
  drawSubmitted('DRAW_SUBMITTED'),

  /// 还缺的物料没有在途供应，等计划安排(红，锁死不能领)。
  waitingPlanning('WAITING_PLANNING'),

  /// 等待物料到货(红，料没到不能领；在途无异常但本行不能执行)。
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

/// 「待处理」领料行的一行(GET /subcontract/draw-tasks 的 page.items[])。
class SubcontractDrawTaskRow {
  final Map<String, String?> exactQuantities;
  String? quantityText(String key) => exactQuantities.containsKey(key)
      ? exactQuantities[key]
      : financeExactDecimal(switch (key) {
          'orderQty' => orderQty,
          'drawnQty' => drawnQty,
          'pendingQty' => pendingQty,
          'drawableQty' => drawableQty,
          'shortQty' => shortQty,
          _ => null,
        });

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
    this.closedKindCount = 0,
    this.sentFullKindCount = 0,
    this.drawableKindCount = 0,
    this.pendingKindCount = 0,
    this.planNo,
    this.applicationItemIds = const [],
    this.differenceQtyText,
    this.exactQuantities = const {},
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

  /// Server-authored received − returned − ordered, in [unitName].
  /// Missing facts remain unknown; draw and material quantities are independent.
  final String? differenceQtyText;

  /// 已领 = 已发齐的完整套数。
  final double drawnQty;

  /// 待仓库发 = 已提交领料、仓库尚未发出的套数。
  final double pendingQty;

  /// 可领 = 现有库存还能配齐的套数。
  final double drawableQty;

  /// 还缺 = 订货数量 − 已领 − 待仓库发 − 可领。
  final double shortQty;
  final int materialKindCount;

  /// 已备 = 还缺为 0 的物料种数(状态列「等待物料·已备 a/n 种」)。
  final int readyKindCount;

  /// 逐种分桶(2026-11-09「物料」列，与任务详情物料状态同一判定，每种物料只落一个桶)：
  /// 缺 = 无货可领也没有待发、还缺 > 0；已结束领料 / 已发齐 / 本次可领 / 待仓库发。
  final int shortKindCount;
  final int closedKindCount;
  final int sentFullKindCount;
  final int drawableKindCount;
  final int pendingKindCount;

  /// 还缺且没有在途供应(未安排)的物料种数。
  final int unplannedShortKindCount;
  final SubcontractDrawStatus status;
  final String? deliverDate;

  /// 服务端判定本行可勾选进入领料页(与账号能力 canSubmitDraw 同时成立才可勾)。
  final bool canDraw;

  /// 来源计划(WL 分析编号，为空时服务端回落订货单号)；「待处理」拍平表与申请行同列显示。
  final String? planNo;
  final List<String> applicationItemIds;

  factory SubcontractDrawTaskRow.fromJson(Map<String, dynamic> json) =>
      SubcontractDrawTaskRow(
        exactQuantities: recordedDecimalFields(json, [
          'orderQty',
          'drawnQty',
          'pendingQty',
          'drawableQty',
          'shortQty',
        ]),
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
        differenceQtyText: receiptRecordedDecimal(json, 'differenceQty'),
        drawnQty: _double(json, 'drawnQty'),
        pendingQty: _double(json, 'pendingQty'),
        drawableQty: _double(json, 'drawableQty'),
        shortQty: _double(json, 'shortQty'),
        materialKindCount: _int(json, 'materialKindCount') ?? 0,
        readyKindCount: _int(json, 'readyKindCount') ?? 0,
        shortKindCount: _int(json, 'shortKindCount') ?? 0,
        unplannedShortKindCount: _int(json, 'unplannedShortKindCount') ?? 0,
        closedKindCount: _int(json, 'closedKindCount') ?? 0,
        sentFullKindCount: _int(json, 'sentFullKindCount') ?? 0,
        drawableKindCount: _int(json, 'drawableKindCount') ?? 0,
        pendingKindCount: _int(json, 'pendingKindCount') ?? 0,
        status: SubcontractDrawStatus.fromWire(json['status']),
        deliverDate: _string(json, 'deliverDate'),
        canDraw: json['canDraw'] == true,
        planNo: _string(json, 'planNo'),
        applicationItemIds: (json['applicationItemIds'] as List? ?? const [])
            .map((id) => id.toString())
            .toList(growable: false),
      );
}

/// GET /subcontract/draw-tasks 的完整响应：分页行 + 状态计数 + 账号能力。
class SubcontractDrawTaskList {
  const SubcontractDrawTaskList({
    required this.page,
    required this.statusCounts,
    required this.canSubmitDraw,
    this.facets = const {},
    this.nullCounts = const {},
  });

  final PagedResult<SubcontractDrawTaskRow> page;

  /// DRAWABLE / DRAW_SUBMITTED / WAITING_PLANNING / WAITING_MATERIAL / ALL。
  final Map<String, int> statusCounts;

  /// 账号能否提交领料(服务端按 subcontract_order:draw 与对象范围给出)。
  final bool canSubmitDraw;
  final Map<String, List<MasterFacetBucket>> facets;
  final Map<String, int> nullCounts;

  SubcontractDrawTaskList withPage(
    PagedResult<SubcontractDrawTaskRow> combined,
  ) => SubcontractDrawTaskList(
    page: combined,
    statusCounts: statusCounts,
    canSubmitDraw: canSubmitDraw,
    facets: facets,
    nullCounts: nullCounts,
  );

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
      facets: {
        for (final key in (json['facets'] as Map? ?? const {}).keys)
          key.toString(): parseFacetBuckets(json['facets'], key.toString()),
      },
      nullCounts: {
        for (final entry in (json['nullCounts'] as Map? ?? const {}).entries)
          if (entry.value is num)
            entry.key.toString(): (entry.value as num).toInt(),
      },
    );
  }
}

/// 物料在途供应来源(任务详情「供应来源」列)。
class SubcontractDrawSupplySource {
  final Map<String, String?> exactQuantities;
  String? quantityText(String key) => exactQuantities.containsKey(key)
      ? exactQuantities[key]
      : financeExactDecimal(switch (key) {
          'openQty' => openQty,
          _ => null,
        });

  const SubcontractDrawSupplySource({
    required this.kind,
    required this.docId,
    required this.docNo,
    required this.openQty,
    this.exactQuantities = const {},
  });

  /// PURCHASE / PRODUCTION / SUBCONTRACT。
  final String kind;
  final String? docId;
  final String docNo;
  final double openQty;

  factory SubcontractDrawSupplySource.fromJson(Map<String, dynamic> json) =>
      SubcontractDrawSupplySource(
        exactQuantities: recordedDecimalFields(json, ['openQty']),
        kind: _string(json, 'kind')?.toUpperCase() ?? '',
        docId: _string(json, 'docId'),
        docNo: _string(json, 'docNo') ?? '',
        openQty: _double(json, 'openQty'),
      );
}

/// 任务详情的一种直属物料(冻结计划行)。
class SubcontractDrawMaterial {
  final Map<String, String?> exactQuantities;
  String? quantityText(String key) => exactQuantities.containsKey(key)
      ? exactQuantities[key]
      : financeExactDecimal(switch (key) {
          'perUnitQty' => perUnitQty,
          'requiredQty' => requiredQty,
          'sentQty' => sentQty,
          'pendingQty' => pendingQty,
          'availableQty' => availableQty,
          'drawableQty' => drawableQty,
          'shortQty' => shortQty,
          _ => null,
        });

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
    this.exactQuantities = const {},
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
        exactQuantities: recordedDecimalFields(json, [
          'perUnitQty',
          'requiredQty',
          'baseRequiredQty',
          'lossRequiredQty',
          'sentQty',
          'pendingQty',
          'availableQty',
          'drawableQty',
          'shortQty',
        ]),
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
    this.baseMaterialCoverageQtyText,
  });

  static const withdrawAction = 'WITHDRAW';
  static const closeAction = 'CLOSE';

  /// 本账号能为这条明细按物料领料(任务中心「物料」弹窗的勾选门，服务端给出)。
  static const drawAction = 'DRAW';

  final SubcontractDrawTaskRow task;
  final List<SubcontractDrawMaterial> materials;
  final List<SubcontractDrawPendingDraft> pendingDrafts;
  final String? baseMaterialCoverageQtyText;

  /// 服务端放行的动作：DRAW(按物料领料) / WITHDRAW(撤回未发领料) / CLOSE(结束领料)。
  final Set<String> allowedActions;

  bool allows(String action) => allowedActions.contains(action);

  factory SubcontractDrawTaskDetail.fromJson(Map<String, dynamic> json) {
    final task = json['task'];
    if (task is! Map) {
      throw const FormatException('委外领料任务详情数据不完整，请刷新重试');
    }
    return SubcontractDrawTaskDetail(
      task: SubcontractDrawTaskRow.fromJson(task.cast<String, dynamic>()),
      baseMaterialCoverageQtyText: receiptRecordedDecimal(
        json,
        'baseMaterialCoverageQty',
      ),
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
/// [lines] 非空 = 2026-11-09 按行领料：数量逐(计划行, 仓)给出，qty/materialQty 必须为空；
/// 空行集合表示该任务本次不领(仍参与预览，服务端回候选行)。
/// [planItemIds] 非空 = 2026-11-09 按物料领料(任务中心「物料」弹窗选中的物料，只用于预览)：
/// 服务端只为这些物料出候选行，默认量 = 每种物料自己的可领上限；提交仍逐行给 [lines]。
class SubcontractDrawRequestItem {
  const SubcontractDrawRequestItem({
    required this.orderItemId,
    this.qty,
    this.materialQty,
    this.materialPlanItemId,
    this.lines,
    this.planItemIds,
  }) : assert(qty == null || materialQty == null),
       assert((materialQty == null) == (materialPlanItemId == null)),
       assert(lines == null || (qty == null && materialQty == null)),
       assert(
         planItemIds == null ||
             (qty == null && materialQty == null && lines == null),
       );

  final String orderItemId;
  final Object? qty;
  final String? materialQty;
  final String? materialPlanItemId;
  final List<SubcontractDrawRequestLine>? lines;
  final List<String>? planItemIds;

  Map<String, dynamic> toJson() => {
    'orderItemId': orderItemId,
    'qty': qty,
    'materialQty': ?materialQty,
    'materialPlanItemId': ?materialPlanItemId,
    'lines': ?lines?.map((line) => line.toJson()).toList(),
    'planItemIds': ?planItemIds,
  };
}

/// 按行领料的一条输入：该仓本次要领出的实物量。
class SubcontractDrawRequestLine {
  const SubcontractDrawRequestLine({
    required this.planItemId,
    required this.warehouseId,
    required this.qty,
  });

  final String planItemId;
  final String warehouseId;
  final Object? qty;

  Map<String, dynamic> toJson() => {
    'planItemId': planItemId,
    'warehouseId': warehouseId,
    'qty': qty,
  };
}

/// 领料页任务表一行(POST /preview 的 tasks[])。
class SubcontractDrawPreviewTask {
  final String? commandQtyText;
  final Map<String, String?> exactQuantities;
  String? quantityText(String key) => exactQuantities.containsKey(key)
      ? exactQuantities[key]
      : financeExactDecimal(switch (key) {
          'orderQty' => orderQty,
          'drawnQty' => drawnQty,
          'drawableQty' => drawableQty,
          'batchDrawableQty' => batchDrawableQty,
          'qty' => qty,
          _ => null,
        });

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
    this.exactQuantities = const {},
    this.commandQtyText,
    this.materialQtyText,
    this.materialBatchDrawableQtyText,
    this.materialUnitName = '',
    this.materialPlanItemId,
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

  final String? materialQtyText;
  final String? materialBatchDrawableQtyText;
  final String materialUnitName;
  final String? materialPlanItemId;

  bool get usesMaterialQuantity => materialPlanItemId != null;
  String? get defaultInputQtyText =>
      usesMaterialQuantity ? materialQtyText : commandQtyText;
  String? get batchInputMaxText => usesMaterialQuantity
      ? materialBatchDrawableQtyText
      : quantityText('batchDrawableQty');

  factory SubcontractDrawPreviewTask.fromJson(Map<String, dynamic> json) =>
      SubcontractDrawPreviewTask(
        commandQtyText: recordedDocumentDecimal(json, 'qty'),
        materialQtyText: recordedDocumentDecimal(json, 'materialQty'),
        materialBatchDrawableQtyText: recordedDocumentDecimal(
          json,
          'materialBatchDrawableQty',
        ),
        materialUnitName: _string(json, 'materialUnitName') ?? '',
        materialPlanItemId: _string(json, 'materialPlanItemId'),
        exactQuantities: recordedDecimalFields(json, [
          'orderQty',
          'drawnQty',
          'drawableQty',
          'batchDrawableQty',
          'qty',
        ]),
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
  final Map<String, String?> exactQuantities;
  String? quantityText(String key) => exactQuantities.containsKey(key)
      ? exactQuantities[key]
      : financeExactDecimal(switch (key) {
          'qty' => qty,
          'warehouseAvailableQty' => warehouseAvailableQty,
          _ => null,
        });

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
    this.exactQuantities = const {},
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
        exactQuantities: recordedDecimalFields(json, [
          'qty',
          'warehouseAvailableQty',
        ]),
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
