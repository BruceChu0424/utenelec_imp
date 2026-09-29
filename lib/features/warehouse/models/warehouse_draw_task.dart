// 仓库侧「待领任务」轻量读模型：履约工作台公开投影（/operations/workbench/
// warehouse）的仓库允许清单副本——只含数量/货品/仓库/日期/状态与领料单
// 深链，不复用 operations_workbench 模型（架构边界：warehouse 不依赖其它 feature）。
//
// 行粒度（2026-09-27 用户口径）：列表行=「批次 × 货品」——同批次同货品的多张单
// 合并成一行（数量相加），多货品单按行级明细拆开一行一个货品，不再显示
// 「N 种物料」归组摘要；无批次的单只在单内拆行、不跨单合并。出库/详情等
// 动作按 members 里的底层单据展开，聚合只是展示粒度。

class WarehouseDrawTask {
  const WarehouseDrawTask({
    required this.taskId,
    required this.planNo,
    required this.warehouseName,
    required this.goodsCode,
    required this.goodsName,
    required this.spec,
    required this.colorName,
    required this.unitName,
    this.requiredQty,
    this.fulfilledQty,
    this.workshopName = '',
    this.workerName = '',
    this.drawBatchNo = '',
    required this.openQty,
    required this.taskStatus,
    required this.needDate,
    required this.expectedDate,
    required this.exceptionCode,
    required this.actionDocId,
    required this.actionDocType,
    this.actionDocNo = '',
    this.actionDocStatus,
    this.goodsCount = 0,
    this.openLineCount = 0,
    this.materialsDefined = false,
    this.productionProductCode = '',
    this.productionProductName = '',
    this.materialRequestNo = '',
    this.members,
    this.lines = const [],
  });

  final String taskId;
  final String planNo;
  final String warehouseName;
  final String goodsCode;
  final String goodsName;
  final String spec;
  final String colorName;
  final String unitName;
  final num openQty;

  /// 应领数量（单货品单据才有值；归组行/申请行 null）。
  final num? requiredQty;

  /// 已出库数量（单货品单据才有值；归组行/申请行 null）。
  final num? fulfilledQty;

  /// 领料车间（DRAW 单 department → 部门名；申请行为空）。
  final String workshopName;

  /// 领料负责人（DRAW 单 worker → 员工名；申请行为空）。
  final String workerName;

  /// 领料批次号（车间任务批量领料提交时整批同值，仓库识别同批；无批为空）。
  final String drawBatchNo;
  final String taskStatus;
  final String? needDate;
  final String? expectedDate;
  final String? exceptionCode;
  final String? actionDocId;
  final String? actionDocType;
  final String actionDocNo;

  /// 领料单状态（服务端投影 action_doc_status：'0' 草稿 / '1' 已审 / '-1' 红冲）。
  final String? actionDocStatus;
  final int goodsCount;
  final int openLineCount;
  final bool materialsDefined;
  final String productionProductCode;
  final String productionProductName;
  final String materialRequestNo;

  /// 聚合/拆分行（「批次 × 货品」粒度）携带的底层单据行；普通行为 null。
  /// 出库/详情等动作都要按底层单据展开。
  final List<WarehouseDrawTask>? members;

  /// 行级明细（服务端 lines：货品×数量），拆「货品行」的数据源；申请行为空。
  final List<WarehouseDrawLine> lines;

  /// 是否为聚合/拆分出的展示行（动作要按 members 展开）。
  bool get isBatchMerged => members != null;

  /// 拆行身份键：批次（或单据）+ 货品 + 颜色。
  static String goodsRowIdentity({
    required String batchKey,
    required String goodsCode,
    required String goodsName,
    required String colorName,
  }) => '$batchKey|$goodsCode|$goodsName|$colorName';

  /// 本行的批次合并键：有批次=批次（同批跨单可合并）；无批次=单据自身（不跨单）。
  String get _mergeKey => drawBatchNo.isNotEmpty
      ? 'batch:$drawBatchNo'
      : 'doc:$taskId';

  /// 按行级明细把单据行拆成「货品行」（一行=本单的一个货品，数量取该货品行）。
  /// 申请行/未填写材料行/无明细的行原样返回（拆不开就不拆）。
  List<WarehouseDrawTask> expandToGoodsRows() {
    if (isMaterialDiscovery || needsMaterialEntry || lines.isEmpty) {
      return [this];
    }
    return [
      for (final line in lines)
        WarehouseDrawTask(
          taskId: goodsRowIdentity(
            batchKey: _mergeKey,
            goodsCode: line.goodsCode,
            goodsName: line.goodsName,
            colorName: line.colorName,
          ),
          planNo: planNo,
          warehouseName: warehouseName,
          goodsCode: line.goodsCode,
          goodsName: line.goodsName,
          spec: '',
          colorName: line.colorName,
          unitName: line.unitName,
          requiredQty: line.requiredQty,
          fulfilledQty: line.fulfilledQty,
          workshopName: workshopName,
          workerName: workerName,
          drawBatchNo: drawBatchNo,
          openQty: line.openQty,
          taskStatus: taskStatus,
          needDate: needDate,
          expectedDate: expectedDate,
          exceptionCode: exceptionCode,
          actionDocId: null,
          actionDocType: null,
          actionDocStatus: actionDocStatus,
          goodsCount: 1,
          openLineCount: 1,
          productionProductCode: productionProductCode,
          productionProductName: productionProductName,
          materialRequestNo: materialRequestNo,
          members: [this],
        ),
    ];
  }

  /// 「货品行」视图：同批次同货品跨单合并数量；无批次行不跨单。
  static List<WarehouseDrawTask> mergeGoodsRows(List<WarehouseDrawTask> rows) {
    String keyOf(WarehouseDrawTask row) => row.drawBatchNo.isEmpty
        ? ''
        : goodsRowIdentity(
            batchKey: 'batch:${row.drawBatchNo}',
            goodsCode: row.goodsCode,
            goodsName: row.goodsName,
            colorName: row.colorName,
          );
    final byKey = <String, List<WarehouseDrawTask>>{};
    for (final row in rows) {
      final key = keyOf(row);
      if (key.isEmpty) continue;
      byKey.putIfAbsent(key, () => []).add(row);
    }
    final result = <WarehouseDrawTask>[];
    final seen = <String>{};
    for (final row in rows) {
      final key = keyOf(row);
      if (key.isEmpty) {
        result.add(row);
        continue;
      }
      if (!seen.add(key)) continue;
      final group = byKey[key]!;
      result.add(
        group.length == 1 ? group.single : WarehouseDrawTask.mergedBatch(group),
      );
    }
    return result;
  }

  /// 同批次同货品聚合行：数量合计、涉及单据随 members 携带；状态取整批口径
  /// （全部同态取该态，待备料+部分领取混合=部分领取）。入参是「货品行」。
  factory WarehouseDrawTask.mergedBatch(List<WarehouseDrawTask> rows) {
    final first = rows.first;
    final docs = <String, WarehouseDrawTask>{
      for (final row in rows)
        for (final doc in row.members ?? <WarehouseDrawTask>[row])
          doc.taskId: doc,
    }.values.toList();
    final statuses = docs.map((d) => d.taskStatus.toUpperCase()).toSet();
    final String taskStatus;
    if (statuses.length == 1) {
      taskStatus = docs.first.taskStatus;
    } else if (statuses.contains('PARTIAL') || statuses.contains('DONE')) {
      taskStatus = 'PARTIAL';
    } else {
      taskStatus = docs.first.taskStatus;
    }
    final warehouses = docs
        .map((d) => d.warehouseName)
        .where((w) => w.isNotEmpty)
        .toSet();
    final workshops = docs
        .map((d) => d.workshopName)
        .where((w) => w.isNotEmpty)
        .toSet();
    final workers = docs
        .map((d) => d.workerName)
        .where((w) => w.isNotEmpty)
        .toSet();
    String joinOrDash(Set<String> values) => values.isEmpty
        ? '—'
        : values.length == 1
        ? values.single
        : '${values.length} 个';
    String? earliest(Iterable<String?> dates) {
      final nonNull = dates.whereType<String>().toList();
      if (nonNull.isEmpty) return null;
      return nonNull.reduce((a, b) => a.compareTo(b) <= 0 ? a : b);
    }

    return WarehouseDrawTask(
      taskId: first.taskId,
      planNo: joinOrDash(
        docs.map((d) => d.planNo).where((p) => p != '—').toSet(),
      ),
      warehouseName: joinOrDash(warehouses),
      goodsCode: first.goodsCode,
      goodsName: first.goodsName,
      spec: first.spec,
      colorName: first.colorName,
      unitName: first.unitName,
      requiredQty: rows.fold<num>(0, (acc, r) => acc + (r.requiredQty ?? 0)),
      fulfilledQty: rows.fold<num>(0, (acc, r) => acc + (r.fulfilledQty ?? 0)),
      workshopName: joinOrDash(workshops),
      workerName: joinOrDash(workers),
      drawBatchNo: first.drawBatchNo,
      openQty: rows.fold<num>(0, (acc, r) => acc + r.openQty),
      taskStatus: taskStatus,
      needDate: earliest(docs.map((d) => d.needDate)),
      expectedDate: earliest(docs.map((d) => d.expectedDate)),
      exceptionCode: docs
          .map((d) => d.exceptionCode)
          .firstWhere((c) => c != null, orElse: () => null),
      actionDocId: null,
      actionDocType: null,
      actionDocStatus: docs.any((d) => d.isDraftDoc)
          ? '0'
          : first.actionDocStatus,
      goodsCount: 1,
      openLineCount: docs.length,
      materialsDefined: true,
      productionProductCode: first.productionProductCode,
      productionProductName: first.productionProductName,
      materialRequestNo: first.materialRequestNo,
      members: docs,
    );
  }

  bool get isMaterialDiscovery =>
      actionDocType == 'MATERIAL_DISCOVERY' && actionDocId != null;
  bool get needsMaterialEntry => isMaterialDiscovery && !materialsDefined;
  String get productionPurpose => [
    productionProductName,
    productionProductCode,
  ].where((value) => value.isNotEmpty).join(' · ');
  String get materialLabel => isBatchMerged
      ? goodsName
      : needsMaterialEntry
      ? '需要填写'
      : isMaterialDiscovery
      ? goodsName
      : isDocumentGrouped
      ? goodsLabel
      : goodsName;
  bool get canOpen => isMaterialDiscovery || drawDocPath != null;

  /// 归组行（一张领料单多行物料）：货品身份列改显示规模摘要。
  /// 拆分/聚合行恒为单货品（goodsCount=1），不走归组摘要。
  bool get isDocumentGrouped =>
      !isBatchMerged && (goodsCount > 1 || openLineCount > 1);

  /// 草稿领料单：批量出库时走「出库即审核」，需要同时具备审核权限。
  bool get isDraftDoc => actionDocStatus?.trim() == '0';

  /// 已知材料的申请可在批量详情补齐数量和实际仓，再与 DRAW 一起确认。
  /// 聚合行（同批次同货品）可出库性=全部底层单可出库。
  bool get canBatchIssue => isBatchMerged
      ? members!.every((d) => d.canBatchIssue)
      : (drawDocPath != null || (isMaterialDiscovery && materialsDefined)) &&
          !const {
            'DONE',
            'COMPLETED',
            'CANCELLED',
            'REVERSED',
          }.contains(taskStatus.toUpperCase());

  bool get batchRequiresApproval =>
      isBatchMerged
          ? members!.any((d) => d.batchRequiresApproval)
          : isDraftDoc || isMaterialDiscovery;

  /// 领料单深链：服务端投影 actionDocCanView=true 时才有（对象范围裁剪）。
  String? get drawDocPath {
    final id = actionDocId;
    if (id == null || id.isEmpty) return null;
    if (actionDocType?.trim().toUpperCase() != 'DRAW') return null;
    return '/warehouse/DRAW/$id';
  }

  /// 单货品单据显示完整货品身份；多货品归组行显示「N 种物料 · N 行待领」。
  String get goodsLabel => isDocumentGrouped
      ? '$goodsCount 种物料${openLineCount > 0 ? ' · $openLineCount 行待领' : ''}'
      : [
          goodsCode,
          goodsName,
          if (spec.isNotEmpty) spec,
          if (colorName.isNotEmpty) colorName,
        ].join(' ');

  String get drawBillLabel {
    // 聚合行没有单一单号：显示张数摘要（批次号在「领料批次」列）。
    if (isBatchMerged) return '${members!.length} 张单';
    // A request owns its number; a workshop ZX code is never a draw number.
    final number = isMaterialDiscovery ? materialRequestNo : actionDocNo;
    return number.trim().isEmpty ? '—' : number;
  }

  String get dueDate => needDate ?? expectedDate ?? '—';

  /// 单货品纯数字文本（不带单位，单位有独立列——与批量出库明细表同款口径）。
  static String plainQty(num? value) {
    if (value == null) return '—';
    return value
        .toDouble()
        .toStringAsFixed(4)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }

  /// 应领数量文本：单货品单据显示纯数字；归组/申请行「—」。
  String get requiredQtyText => isBatchMerged
      ? plainQty(requiredQty)
      : isMaterialDiscovery || isDocumentGrouped
      ? '—'
      : plainQty(requiredQty);

  /// 已出库数量文本：单货品单据显示纯数字；归组/申请行「—」。
  String get fulfilledQtyText => isBatchMerged
      ? plainQty(fulfilledQty)
      : isMaterialDiscovery || isDocumentGrouped
      ? '—'
      : plainQty(fulfilledQty);

  /// 待出库数量文本：保留申请/归组行的规模口径（「N 行材料」「需要填写」）。
  String get remainingQtyText {
    if (isBatchMerged) return plainQty(openQty);
    if (isMaterialDiscovery) {
      if (!materialsDefined) return '—';
      if (openLineCount > 1) return '$openLineCount 行材料';
      if (openQty <= 0) return '需要填写数量';
    }
    if (isDocumentGrouped) {
      return openLineCount > 0 ? '$openLineCount 行' : '—';
    }
    return plainQty(openQty);
  }

  String get statusLabel => switch (taskStatus.toUpperCase()) {
    'READY_TO_PICK' => '待备料 / 待领取',
    'PARTIAL' => '部分领取',
    'DONE' || 'COMPLETED' => '已完成',
    'OPEN_ANY' => '待完成',
    'BLOCKED' => '已阻塞',
    'MATERIALS_TO_DEFINE' => materialsDefined ? '待核对领料' : '需要填写',
    _ => taskStatus,
  };

  /// 异常文案：仓库只关心正常/逾期/异常事实，完整异常字典在履约工作台。
  String get exceptionLabel => switch (exceptionCode?.toUpperCase()) {
    null || '' => '正常',
    'OVERDUE_ANY' => '全部逾期',
    'OVERDUE' => '已逾期',
    _ => exceptionCode!,
  };

  factory WarehouseDrawTask.fromJson(Map<String, dynamic> json) {
    return WarehouseDrawTask(
      taskId: (json['taskId'] ?? '') as String,
      planNo: (json['planNo'] ?? '—') as String,
      warehouseName: (json['warehouseName'] ?? '') as String,
      goodsCode: (json['goodsCode'] ?? '') as String,
      goodsName: (json['goodsName'] ?? '') as String,
      spec: (json['spec'] ?? '') as String,
      colorName: (json['colorName'] ?? '') as String,
      unitName: (json['unitName'] ?? '') as String,
      requiredQty: json['requiredQty'] as num?,
      fulfilledQty: json['fulfilledQty'] as num?,
      workshopName: (json['workshopName'] as String? ?? '').trim(),
      workerName: (json['workerName'] as String? ?? '').trim(),
      drawBatchNo: (json['drawBatchNo'] as String? ?? '').trim(),
      openQty: (json['openQty'] as num?) ?? 0,
      taskStatus: (json['taskStatus'] ?? '') as String,
      needDate: json['needDate'] as String?,
      expectedDate: json['expectedDate'] as String?,
      exceptionCode: json['exceptionCode'] as String?,
      actionDocId: json['actionDocId'] as String?,
      actionDocType: json['actionDocType'] as String?,
      actionDocNo: (json['actionDocNo'] ?? '') as String,
      actionDocStatus: json['actionDocStatus']?.toString(),
      goodsCount: (json['goodsCount'] as num?)?.toInt() ?? 0,
      openLineCount: (json['openLineCount'] as num?)?.toInt() ?? 0,
      materialsDefined: json['materialsDefined'] == true,
      productionProductCode: json['productionProductCode'] as String? ?? '',
      productionProductName: json['productionProductName'] as String? ?? '',
      materialRequestNo: json['materialRequestNo'] as String? ?? '',
      lines: [
        for (final line in json['lines'] as List<dynamic>? ?? const <dynamic>[])
          WarehouseDrawLine.fromJson(line as Map<String, dynamic>),
      ],
    );
  }
}

/// 待领任务行级明细（服务端投影 lines）：货品身份 × 数量。
class WarehouseDrawLine {
  const WarehouseDrawLine({
    this.goodsCode = '',
    this.goodsName = '',
    this.colorName = '',
    this.unitName = '',
    this.requiredQty,
    this.fulfilledQty,
    this.openQty = 0,
  });

  final String goodsCode;
  final String goodsName;
  final String colorName;
  final String unitName;
  final num? requiredQty;
  final num? fulfilledQty;
  final num openQty;

  factory WarehouseDrawLine.fromJson(Map<String, dynamic> json) =>
      WarehouseDrawLine(
        goodsCode: (json['goodsCode'] as String? ?? '').trim(),
        goodsName: (json['goodsName'] as String? ?? '').trim(),
        colorName: (json['colorName'] as String? ?? '').trim(),
        unitName: (json['unitName'] as String? ?? '').trim(),
        requiredQty: json['requiredQty'] as num?,
        fulfilledQty: json['fulfilledQty'] as num?,
        openQty: (json['openQty'] as num?) ?? 0,
      );
}

/// 批量出库结果（POST /stock/docs/issue-batch，对应后端 StockDocIssueBatchResponse）。
class WarehouseDrawBatchIssueResult {
  const WarehouseDrawBatchIssueResult({
    required this.issuedCount,
    required this.skippedCount,
    required this.replayedCount,
    required this.replayed,
    required this.issuedDocNos,
  });

  /// 本次新出库张数。
  final int issuedCount;

  /// 提交前已出完、不属于本批幂等键的单（自动跳过）。
  final int skippedCount;

  /// 已在本批（同操作人同幂等键）此前完成、按子幂等键识别为重放的单。
  final int replayedCount;

  /// 本批此前已全部完成：没有新增出库且至少一张按本批子键重放。
  final bool replayed;
  final List<String> issuedDocNos;

  factory WarehouseDrawBatchIssueResult.fromJson(Map<String, dynamic> json) =>
      WarehouseDrawBatchIssueResult(
        issuedCount: (json['issuedCount'] as num?)?.toInt() ?? 0,
        skippedCount: (json['skippedCount'] as num?)?.toInt() ?? 0,
        replayedCount: (json['replayedCount'] as num?)?.toInt() ?? 0,
        replayed: json['replayed'] == true,
        issuedDocNos: (json['issuedDocNos'] as List<dynamic>? ?? const [])
            .map((e) => e.toString())
            .toList(),
      );
}
