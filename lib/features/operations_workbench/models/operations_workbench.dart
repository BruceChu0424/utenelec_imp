enum OperationsWorkbenchDepartment {
  warehouse('warehouse', '仓库任务工作台'),
  purchase('purchase', '采购任务工作台'),
  subcontract('subcontract', '委外任务工作台');

  const OperationsWorkbenchDepartment(this.apiValue, this.label);

  final String apiValue;
  final String label;
}

/// 「待完成」计数卡的 statusFilter 哨兵：后端按 open_qty > 0 过滤（与采购/委外
/// 待办角标同口径），进入任务工作台默认选中——先看还要做的事，而非全部。
const String kOperationsWorkbenchOpenStatus = 'OPEN_ANY';

class OperationsWorkbenchSummary {
  const OperationsWorkbenchSummary({
    required this.totalTasks,
    required this.overdueTasks,
    required this.openTasks,
    required this.openQty,
    required this.statusCounts,
    this.exceptionCounts = const {},
    this.pendingTasks,
  });

  final int totalTasks;
  final int overdueTasks;
  final int openTasks;
  final num openQty;
  final Map<String, int> statusCounts;
  final Map<String, int> exceptionCounts;

  /// 「待完成」卡片计数：部门×关键字全量口径的 open_qty > 0 任务数
  /// （不受当前状态/异常卡筛选影响；旧后端未返回时回退 openTasks）。
  final int? pendingTasks;

  factory OperationsWorkbenchSummary.fromJson(Map<String, dynamic> json) {
    return OperationsWorkbenchSummary(
      totalTasks: _requiredInt(json, 'totalTasks'),
      overdueTasks: _requiredInt(json, 'overdueTasks'),
      openTasks: _requiredInt(json, 'openTasks'),
      openQty: _requiredNumber(json, 'openQty'),
      statusCounts: {
        for (final entry in (json['statusCounts'] as Map? ?? const {}).entries)
          entry.key.toString(): (entry.value as num).toInt(),
      },
      exceptionCounts: {
        for (final entry
            in (json['exceptionCounts'] as Map? ?? const {}).entries)
          entry.key.toString(): (entry.value as num).toInt(),
      },
      pendingTasks: (json['pendingTasks'] as num?)?.toInt(),
    );
  }

  /// 待完成卡计数（部门全量口径；缺失时回退到当前筛选下的 openTasks）。
  int get pendingTaskCount => pendingTasks ?? openTasks;

  List<OperationsWorkbenchMetric> metricsFor(
    OperationsWorkbenchDepartment department,
  ) {
    // 三个部门统一卡序：待完成（默认视图，黄）→ 各状态卡 → 逾期/异常。
    // 「全部」卡 2026-08-17 起隐藏：点掉已选卡或用下拉「全部状态」同样回到全量视图。
    final pending = OperationsWorkbenchMetric(
      key: 'pending',
      label: '待完成',
      value: pendingTaskCount,
      tone: pendingTaskCount > 0 ? 'warning' : 'neutral',
      statusFilter: kOperationsWorkbenchOpenStatus,
    );
    final overdue = OperationsWorkbenchMetric(
      key: 'overdueTasks',
      label: '逾期 / 异常',
      value: overdueTasks,
      tone: overdueTasks > 0 ? 'danger' : 'neutral',
      exceptionFilter: 'OVERDUE_ANY',
    );
    switch (department) {
      case OperationsWorkbenchDepartment.purchase:
      case OperationsWorkbenchDepartment.subcontract:
        // 采购/委外任务台设计对齐：待完成(全部未完成,黄) + 申请待分解(黄) +
        // 等待财务审核(蓝) + 财务已通过(青) + 已完成(绿)。
        // 财务驳回(红)不单独成卡——在状态下拉里可见。
        return [
          pending,
          _statusMetric('WAITING_ORDER', '申请待分解', 'warning'),
          _statusMetric('ORDER_PENDING_APPROVAL', '等待财务审核', 'info'),
          _statusMetric('FINANCE_APPROVED', '财务已通过', 'neutral'),
          _statusMetric('COMPLETED', '已完成', 'success'),
          overdue,
        ];
      case OperationsWorkbenchDepartment.warehouse:
        // 仓库履约任务台（领料/备料域，与采购/委外不同）：保留状态卡 + 逾期/未完成数量。
        return [
          pending,
          _statusMetric('READY_TO_PICK', '待备料 / 待领取', 'warning'),
          _statusMetric('PARTIAL', '部分领取', 'info'),
          _statusMetric('DONE', '已领取', 'success'),
          overdue,
          OperationsWorkbenchMetric(
            key: 'openQty',
            label: '未完成数量',
            value: openQty,
            tone: 'warning',
          ),
        ];
    }
  }

  OperationsWorkbenchMetric _statusMetric(
    String status,
    String label,
    String tone,
  ) {
    return OperationsWorkbenchMetric(
      key: status,
      label: label,
      value: statusCounts[status] ?? 0,
      tone: tone,
      statusFilter: status,
    );
  }
}

class OperationsWorkbenchMetric {
  const OperationsWorkbenchMetric({
    required this.key,
    required this.label,
    required this.value,
    this.tone = 'neutral',
    this.statusFilter,
    this.exceptionFilter,
  });

  final String key;
  final String label;
  final num value;
  final String tone;
  final String? statusFilter;
  final String? exceptionFilter;
}

class OperationsWorkbenchFilterOption {
  const OperationsWorkbenchFilterOption({
    required this.value,
    required this.label,
  });

  final String value;
  final String label;
}

class OperationsActionDocument {
  const OperationsActionDocument({
    required this.id,
    required this.docType,
    required this.number,
    required this.path,
    required this.canView,
    required this.canEdit,
    this.status,
  });

  final String id;
  final String docType;
  final String number;
  final String path;
  final bool canView;
  final bool canEdit;
  final String? status;

  bool get isApprovedPurchaseRequest =>
      _isType('PURCHASE_REQUEST', 'REQUEST') && status == '1';

  bool get isIssuedSubcontractApplication =>
      _isType('SUBCONTRACT_APPLICATION', 'APPLICATION') && status == '1';

  String? get purchaseStageLabel => switch (docType.toUpperCase()) {
    'PURCHASE_REQUEST' || 'REQUEST' => switch (status) {
      '0' => '计划申请尚未下达',
      '1' => '计划申请已下达，待分解',
      _ => '采购申请处理中',
    },
    'PURCHASE_ORDER' || 'ORDER' => switch (status) {
      '0' => '采购订货单等待财务审核',
      '1' => '采购订货单财务已通过 / 在途',
      _ => '采购订单处理中',
    },
    'PURCHASE_RECEIPT' || 'RECEIPT' => switch (status) {
      '0' => '收货待审核',
      '1' => '已收货',
      _ => '收货处理中',
    },
    _ => null,
  };

  String get label => _actionDocumentLabel(this);

  static OperationsActionDocument? fromTaskJson(
    Map<String, dynamic> json,
    OperationsWorkbenchDepartment department,
  ) {
    final id = _optionalString(json, 'actionDocId');
    final docType = _optionalString(json, 'actionDocType');
    final canView = json['actionDocCanView'] == true;
    if (!canView || id == null || docType == null) return null;
    final path = _derivePath(department, docType, id);
    if (path == null) return null;
    return OperationsActionDocument(
      id: id,
      docType: docType,
      number: _optionalString(json, 'actionDocNo') ?? '',
      path: path,
      canView: true,
      canEdit: json['actionDocCanEdit'] == true,
      status: _optionalString(json, 'actionDocStatus'),
    );
  }

  static String? _derivePath(
    OperationsWorkbenchDepartment department,
    String rawType,
    String id,
  ) {
    final type = rawType.trim();
    if (type.isEmpty || id.trim().isEmpty) return null;
    return switch (department) {
      OperationsWorkbenchDepartment.warehouse =>
        type.toUpperCase() == 'DRAW' ? '/warehouse/DRAW/$id' : null,
      OperationsWorkbenchDepartment.purchase => switch (type.toUpperCase()) {
        'PURCHASE_REQUEST' || 'REQUEST' => '/purchase/requests/$id',
        'PURCHASE_ORDER' || 'ORDER' => '/purchase/orders/$id',
        'PURCHASE_RECEIPT' || 'RECEIPT' => '/purchase/receipts/$id',
        'PURCHASE_RETURN' || 'RETURN' => '/purchase/returns/$id',
        _ => null,
      },
      OperationsWorkbenchDepartment.subcontract => switch (type.toUpperCase()) {
        'SUBCONTRACT_INQUIRY' || 'INQUIRY' => '/subcontract/inquiries/$id',
        'SUBCONTRACT_APPLICATION' ||
        'APPLICATION' => '/subcontract/applications/$id',
        'SUBCONTRACT_ORDER' || 'ORDER' => '/subcontract/orders/$id',
        'SUBCONTRACT_RECEIPT' || 'RECEIPT' => '/subcontract/receipts/$id',
        'SUBCONTRACT_MATERIAL_ISSUE' ||
        'MATERIAL_ISSUE' => '/subcontract/material-issues/$id',
        'SUBCONTRACT_RETURN' || 'RETURN' => '/subcontract/returns/$id',
        'SUBCONTRACT_MATERIAL_RETURN' ||
        'MATERIAL_RETURN' => '/subcontract/material-returns/$id',
        'SUBCONTRACT_WASTE' || 'WASTE' => '/subcontract/wastes/$id',
        _ => null,
      },
    };
  }

  bool _isType(String canonical, String alias) {
    return docType.toUpperCase() == canonical || docType.toUpperCase() == alias;
  }
}

class OperationsWorkbenchTask {
  const OperationsWorkbenchTask({
    required this.taskId,
    required this.packageId,
    required this.planId,
    required this.planNo,
    required this.warehouseName,
    required this.goodsCode,
    required this.goodsName,
    required this.spec,
    required this.colorName,
    required this.unitName,
    required this.supplyRoute,
    required this.requiredQty,
    required this.allocatedQty,
    required this.fulfilledQty,
    required this.supplyPeggedQty,
    required this.openQty,
    required this.taskStatus,
    required this.needDate,
    required this.expectedDate,
    required this.exceptionCode,
    required this.updatedAt,
    required this.actionDocument,
    required this.actionDocItemId,
    required this.actionDocumentRestricted,
  });

  final String taskId;
  final String? packageId;
  final String? planId;
  final String planNo;
  final String warehouseName;
  final String goodsCode;
  final String goodsName;
  final String spec;
  final String colorName;
  final String unitName;
  final String supplyRoute;
  final num requiredQty;
  final num allocatedQty;
  final num fulfilledQty;
  final num supplyPeggedQty;
  final num openQty;
  final String taskStatus;
  final String? needDate;
  final String? expectedDate;
  final String? exceptionCode;
  final String? updatedAt;
  final OperationsActionDocument? actionDocument;
  final String? actionDocItemId;
  final bool actionDocumentRestricted;

  String get id => taskId;
  String get taskNo => taskId;
  String get title => goodsName;
  String get sourceNo => planNo;
  String get statusLabel {
    // 订单级阶段（等待财务审核/财务已通过/财务驳回/已完成）优先用任务状态标签，
    // 否则会被采购单据标签覆盖，无法区分各阶段。
    if (taskStatus == 'ORDER_PENDING_APPROVAL' ||
        taskStatus == 'FINANCE_APPROVED' ||
        taskStatus == 'FINANCE_REJECTED' ||
        taskStatus == 'COMPLETED') {
      return operationsWorkbenchStatusLabel(taskStatus);
    }
    return actionDocument?.purchaseStageLabel ??
        operationsWorkbenchStatusLabel(taskStatus);
  }

  String get exceptionLabel => exceptionCode == null
      ? '正常'
      : operationsWorkbenchExceptionLabel(exceptionCode!);
  String get counterparty => warehouseName.isEmpty ? '—' : warehouseName;
  String get dueDate => needDate ?? expectedDate ?? '—';
  String get quantityText => '${_displayNumber(openQty)} $unitName'.trim();
  bool get hasException => exceptionCode != null;

  factory OperationsWorkbenchTask.fromJson(
    Map<String, dynamic> json,
    OperationsWorkbenchDepartment department,
  ) {
    return OperationsWorkbenchTask(
      taskId: _requiredString(json, 'taskId'),
      packageId: _optionalString(json, 'packageId'),
      planId: _optionalString(json, 'planId'),
      planNo: _optionalString(json, 'planNo') ?? '—',
      warehouseName: _optionalString(json, 'warehouseName') ?? '',
      goodsCode: _requiredString(json, 'goodsCode'),
      goodsName: _requiredString(json, 'goodsName'),
      spec: _optionalString(json, 'spec') ?? '',
      colorName: _optionalString(json, 'colorName') ?? '',
      unitName: _optionalString(json, 'unitName') ?? '',
      supplyRoute: _requiredString(json, 'supplyRoute'),
      requiredQty: _requiredNumber(json, 'requiredQty'),
      allocatedQty: _requiredNumber(json, 'allocatedQty'),
      fulfilledQty: _requiredNumber(json, 'fulfilledQty'),
      supplyPeggedQty: _requiredNumber(json, 'supplyPeggedQty'),
      openQty: _requiredNumber(json, 'openQty'),
      taskStatus: _requiredString(json, 'taskStatus'),
      needDate: _optionalString(json, 'needDate'),
      expectedDate: _optionalString(json, 'expectedDate'),
      exceptionCode: _optionalString(json, 'exceptionCode'),
      updatedAt: _optionalString(json, 'updatedAt'),
      actionDocument: OperationsActionDocument.fromTaskJson(json, department),
      actionDocItemId: _optionalString(json, 'actionDocItemId'),
      actionDocumentRestricted: json['actionDocRestricted'] == true,
    );
  }
}

class OperationsWorkbenchCapabilities {
  const OperationsWorkbenchCapabilities({
    this.canCreatePurchaseOrder = false,
    this.canCreateSubcontractOrder = false,
  });

  final bool canCreatePurchaseOrder;
  final bool canCreateSubcontractOrder;

  factory OperationsWorkbenchCapabilities.fromJson(Map<String, dynamic>? json) {
    return OperationsWorkbenchCapabilities(
      canCreatePurchaseOrder: json?['canCreatePurchaseOrder'] == true,
      canCreateSubcontractOrder: json?['canCreateSubcontractOrder'] == true,
    );
  }
}

class OperationsWorkbenchData {
  const OperationsWorkbenchData({
    required this.department,
    required this.summary,
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
    required this.capabilities,
  });

  final OperationsWorkbenchDepartment department;
  final OperationsWorkbenchSummary summary;
  final List<OperationsWorkbenchTask> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;
  final OperationsWorkbenchCapabilities capabilities;

  List<OperationsWorkbenchMetric> get metrics => summary.metricsFor(department);

  List<OperationsWorkbenchFilterOption> get statusOptions => _options(<String>[
    ...summary.statusCounts.keys,
    ...metrics.map((metric) => metric.statusFilter).whereType<String>(),
  ], operationsWorkbenchStatusLabel);

  List<OperationsWorkbenchFilterOption> get exceptionOptions =>
      _options(<String>[
        ...summary.exceptionCounts.keys,
        ...metrics.map((metric) => metric.exceptionFilter).whereType<String>(),
      ], operationsWorkbenchExceptionLabel);

  factory OperationsWorkbenchData.fromJson(
    Map<String, dynamic> json,
    OperationsWorkbenchDepartment department,
  ) {
    final rawItems = json['items'];
    final rawSummary = json['summary'];
    if (rawItems is! List || rawSummary is! Map) {
      throw const FormatException('履约工作台响应缺少 items 或 summary');
    }
    return OperationsWorkbenchData(
      department: department,
      summary: OperationsWorkbenchSummary.fromJson(
        rawSummary.cast<String, dynamic>(),
      ),
      items: rawItems
          .map(
            (item) => OperationsWorkbenchTask.fromJson(
              (item as Map).cast<String, dynamic>(),
              department,
            ),
          )
          .toList(growable: false),
      page: _requiredInt(json, 'page'),
      size: _requiredInt(json, 'size'),
      total: _requiredInt(json, 'total'),
      totalPages: _requiredInt(json, 'totalPages'),
      capabilities: OperationsWorkbenchCapabilities.fromJson(
        (json['capabilities'] as Map?)?.cast<String, dynamic>(),
      ),
    );
  }
}

List<OperationsWorkbenchFilterOption> _options(
  Iterable<String> values,
  String Function(String) label,
) {
  final unique = values.where((value) => value.isNotEmpty).toSet().toList()
    ..sort();
  return unique
      .map(
        (value) =>
            OperationsWorkbenchFilterOption(value: value, label: label(value)),
      )
      .toList(growable: false);
}

String operationsWorkbenchStatusLabel(String code) =>
    switch (code.toUpperCase()) {
      'OPEN_ANY' => '待完成',
      'OPEN' => '待处理',
      'READY_TO_PICK' => '待备料 / 待发料',
      'UNPEGGED' => '待生成供给单',
      'WAITING' => '等待中',
      'WAITING_SUPPLY' => '采购 / 委外执行中',
      'APPLICATION_PENDING_APPROVAL' => '计划申请尚未下达',
      'WAITING_ORDER' => '计划申请已下达 / 待分解',
      'FINANCE_APPROVED' => '财务已通过',
      'FINANCE_REJECTED' => '财务驳回',
      'ORDER_PENDING_APPROVAL' => '订单等待财务审核',
      'WAITING_RETURN' => '委外中 / 待回厂',
      'RECEIPT_PENDING_APPROVAL' => '回厂单待审核',
      'IN_PROGRESS' => '处理中',
      'PARTIAL' => '部分发料 / 部分完成',
      'COVERED' => '供给已覆盖',
      'DONE' || 'COMPLETED' => '已完成',
      'BLOCKED' => '已阻塞',
      _ => code,
    };

/// 供给方式（supplyRoute）码 → 中文标签：BUY=采购、MAKE=自制、SUBCONTRACT=委外。
/// 与生产侧口径一致（production_material_analysis.dart 的 SupplyRoute 枚举、
/// execution_segment_planning_sheet.dart / production_execution_card_print_preview.dart）。
String operationsWorkbenchSupplyRouteLabel(String code) =>
    switch (code.toUpperCase()) {
      'BUY' => '采购',
      'MAKE' => '自制',
      'SUBCONTRACT' => '委外',
      _ => code,
    };

String operationsWorkbenchExceptionLabel(String code) =>
    switch (code.toUpperCase()) {
      'OVERDUE_ANY' => '全部逾期',
      'OVERDUE' => '已逾期',
      'OVERDUE_SHORTAGE' => '逾期缺料',
      'SHORTAGE' => '缺料',
      'LATE_SUPPLY' => '供给延期',
      'SUPPLY_PEG_REQUIRED' => '待生成采购 / 委外单',
      'UNLINKED' => '待挂接',
      _ => code,
    };

String _actionDocumentLabel(OperationsActionDocument document) {
  final suffix = document.number.isEmpty ? '' : ' ${document.number}';
  final status = document.status;
  return switch (document.docType.toUpperCase()) {
    'PURCHASE_REQUEST' || 'REQUEST' => switch (status) {
      '0' => '计划申请未下达$suffix',
      '1' => '计划下达申请$suffix',
      _ => '采购申请$suffix',
    },
    'PURCHASE_ORDER' || 'ORDER' => switch (status) {
      '0' => '采购订货单等待财务审核$suffix',
      '1' => '财务已通过采购订货单$suffix',
      _ => '采购订单$suffix',
    },
    'PURCHASE_RECEIPT' || 'RECEIPT' => switch (status) {
      '0' => '收货单草稿$suffix',
      '1' => '已收货$suffix',
      _ => '收货单$suffix',
    },
    'SUBCONTRACT_APPLICATION' || 'APPLICATION' => switch (status) {
      '0' => '计划委外申请尚未下达$suffix',
      '1' => '计划下达委外申请$suffix',
      _ => '委外申请$suffix',
    },
    'SUBCONTRACT_ORDER' => switch (status) {
      '0' => '委外订单待财务审核$suffix',
      '1' => '委外执行中$suffix',
      _ => '委外订单$suffix',
    },
    'SUBCONTRACT_RECEIPT' => switch (status) {
      '0' => '回厂单待审$suffix',
      '1' => '已审核回厂$suffix',
      _ => '委外回厂单$suffix',
    },
    'PURCHASE_RETURN' || 'RETURN' => '采购退货单$suffix',
    'DRAW' => status == '1' ? '已发料$suffix' : '领料单$suffix',
    _ => document.number.isEmpty ? '查看单据' : '查看 ${document.number}',
  };
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = _optionalString(json, key);
  if (value == null) throw FormatException('履约工作台字段 $key 缺失');
  return value;
}

String? _optionalString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! String || value.trim().isEmpty) return null;
  return value.trim();
}

num _requiredNumber(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is num) return value;
  if (value is String) {
    final parsed = num.tryParse(value);
    if (parsed != null) return parsed;
  }
  throw FormatException('履约工作台数值字段 $key 缺失或格式错误');
}

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = _requiredNumber(json, key);
  return value.toInt();
}

String _displayNumber(num value) => value == value.roundToDouble()
    ? value.toInt().toString()
    : value.toString();
