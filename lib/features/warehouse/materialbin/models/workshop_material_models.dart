// 车间内料仓 (ADR-131) 客户端模型: 设置、机台与容器、领料单、期间、盘点、
// 内料仓现存、自动结算状态、上线准备。
//
// 字段名按实现规格 §2.3 (REST 接口, 前缀 /api/workshop-material) 的 camelCase 写;
// 数字一律 (x as num).toDouble()/toInt() 解析, 服务端给字符串小数时也兼容。
// 页面按钮只看服务端随数据下发的 allowedActions (不在页面里拼权限)。

double _d(Object? v) => _dn(v) ?? 0;

double? _dn(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

int _i(Object? v) => _in(v) ?? 0;

int? _in(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

String? _s(Object? v) {
  if (v == null) return null;
  final text = v.toString();
  return text.isEmpty ? null : text;
}

bool _b(Object? v) => v == true || v == 'true';

List<String> _strings(Object? v) => v is List
    ? [
        for (final item in v)
          if (item != null) item.toString(),
      ]
    : const <String>[];

List<Map<String, dynamic>> _maps(Object? v) => v is List
    ? [
        for (final item in v)
          if (item is Map) item.cast<String, dynamic>(),
      ]
    : const <Map<String, dynamic>>[];

Map<String, dynamic>? _map(Object? v) =>
    v is Map ? v.cast<String, dynamic>() : null;

/// 货品 + 颜色的组合键 (颜色为空时用空串), 行去重与下拉取值用。
String wmMaterialKey(String goodsId, String? colorId) =>
    '$goodsId|${colorId ?? ''}';

/// 服务端下发的动作码 (与服务端 allowedActions 逐字一致)。
abstract final class WmAction {
  static const request = 'REQUEST';
  static const returnMaterial = 'RETURN';
  static const otherIssue = 'OTHER_ISSUE';
  static const fulfil = 'FULFIL';
  static const cancel = 'CANCEL';
  static const startCount = 'START_COUNT';
  static const editCount = 'EDIT_COUNT';
  static const submitCount = 'SUBMIT_COUNT';
  static const correctCount = 'CORRECT_COUNT';
  static const withdrawCount = 'WITHDRAW_COUNT';
  static const closeRetry = 'CLOSE_RETRY';
  static const reopen = 'REOPEN';
  static const setup = 'SETUP';
}

/// 期间状态 (开着 → 盘点中 → 已盘点 → 已结算)。
abstract final class WmPeriodStatus {
  static const open = 'OPEN';
  static const counting = 'COUNTING';
  static const counted = 'COUNTED';
  static const closed = 'CLOSED';
}

/// 自动结算状态。
abstract final class WmCloseState {
  static const none = 'NONE';
  static const queued = 'QUEUED';
  static const blocked = 'BLOCKED';
  static const held = 'HELD';
  static const failed = 'FAILED';
}

/// 一期 (内料仓账期)。设置里的 currentPeriod 只带 id/no/startDate/status。
class WmPeriod {
  const WmPeriod({
    required this.id,
    required this.periodNo,
    required this.startDate,
    required this.status,
    this.endDate,
    this.closeState = WmCloseState.none,
    this.rowVersion = 0,
    this.binWarehouseId,
    this.workshopDepartmentId,
    this.currentCountId,
    this.currentCountStatus,
    this.allowedActions = const [],
  });

  final String id;
  final int periodNo;
  final String startDate;
  final String? endDate;
  final String status;
  final String closeState;
  final int rowVersion;
  final String? binWarehouseId;
  final String? workshopDepartmentId;

  /// 本期当前的盘点单 (有草稿给草稿, 否则给已提交那张); 还没开始盘点为空。
  final String? currentCountId;
  final String? currentCountStatus;
  final List<String> allowedActions;

  bool can(String action) => allowedActions.contains(action);

  factory WmPeriod.fromJson(Map<String, dynamic> json) => WmPeriod(
    id: json['id'] as String,
    periodNo: _i(json['periodNo'] ?? json['no']),
    startDate: _s(json['startDate']) ?? '',
    endDate: _s(json['endDate']),
    status: _s(json['status']) ?? WmPeriodStatus.open,
    closeState: _s(json['closeState']) ?? WmCloseState.none,
    rowVersion: _i(json['rowVersion']),
    binWarehouseId: _s(json['binWarehouseId']),
    workshopDepartmentId: _s(json['workshopDepartmentId']),
    currentCountId: _s(
      json['currentCountId'] ??
          json['draftCountId'] ??
          json['submittedCountId'],
    ),
    currentCountStatus:
        _s(json['currentCountStatus']) ??
        (json['draftCountId'] != null
            ? 'DRAFT'
            : json['submittedCountId'] != null
            ? 'SUBMITTED'
            : null),
    allowedActions: _strings(json['allowedActions']),
  );
}

/// 一个车间的整批领料设置 (GET /settings 每车间一条)。
class WmSetting {
  const WmSetting({
    required this.workshopDepartmentId,
    required this.workshopName,
    required this.periodicEnabled,
    this.binWarehouseId,
    this.binWarehouseName,
    this.mainWarehouseId,
    this.mainWarehouseName,
    this.goLiveDate,
    this.rowVersion = 0,
    this.currentPeriod,
    this.allowedActions = const [],
  });

  final String workshopDepartmentId;
  final String workshopName;
  final bool periodicEnabled;
  final String? binWarehouseId;
  final String? binWarehouseName;
  final String? mainWarehouseId;
  final String? mainWarehouseName;
  final String? goLiveDate;
  final int rowVersion;
  final WmPeriod? currentPeriod;
  final List<String> allowedActions;

  bool can(String action) => allowedActions.contains(action);

  factory WmSetting.fromJson(Map<String, dynamic> json) {
    final period = _map(json['currentPeriod']);
    return WmSetting(
      workshopDepartmentId: json['workshopDepartmentId'] as String,
      workshopName: _s(json['workshopName']) ?? '',
      periodicEnabled: _b(json['periodicEnabled']),
      binWarehouseId: _s(json['binWarehouseId']),
      binWarehouseName: _s(json['binWarehouseName']),
      mainWarehouseId: _s(json['mainWarehouseId']),
      mainWarehouseName: _s(json['mainWarehouseName']),
      goLiveDate: _s(json['goLiveDate']),
      rowVersion: _i(json['rowVersion']),
      currentPeriod: period == null || period['id'] == null
          ? null
          : WmPeriod.fromJson(period),
      allowedActions: _strings(json['allowedActions']),
    );
  }
}

/// 结算被拦住的一项: 差什么、几条、责任人种类、前几个样例名称。
class WmBlocker {
  const WmBlocker({
    required this.kind,
    required this.count,
    this.responsible,
    this.samples = const [],
  });

  final String kind;
  final int count;
  final String? responsible;
  final List<String> samples;

  factory WmBlocker.fromJson(Map<String, dynamic> json) => WmBlocker(
    kind: _s(json['kind']) ?? '',
    count: _i(json['count']),
    responsible: _s(json['responsible']),
    samples: _strings(json['samples']),
  );

  static List<WmBlocker> listOf(Object? raw) =>
      _maps(raw).map(WmBlocker.fromJson).toList(growable: false);
}

/// 最近一次结算。
class WmLastClose {
  const WmLastClose({required this.closeNo, this.closedAt, this.closedByName});

  final int closeNo;
  final String? closedAt;
  final String? closedByName;

  factory WmLastClose.fromJson(Map<String, dynamic> json) => WmLastClose(
    closeNo: _i(json['closeNo']),
    closedAt: _s(json['closedAt']),
    closedByName: _s(json['closedByName']),
  );
}

/// 一期的自动结算状态 (GET /periods/{id}/close-status; 页面每 2 秒轮询)。
class WmCloseStatus {
  const WmCloseStatus({
    required this.status,
    required this.closeState,
    this.attempts = 0,
    this.failures = 0,
    this.attemptedAt,
    this.lastErrorMessage,
    this.blockers = const [],
    this.heldUntil,
    this.lastClose,
    this.allowedActions = const [],
  });

  final String status;
  final String closeState;
  final int attempts;
  final int failures;
  final String? attemptedAt;
  final String? lastErrorMessage;
  final List<WmBlocker> blockers;
  final String? heldUntil;
  final WmLastClose? lastClose;
  final List<String> allowedActions;

  bool can(String action) => allowedActions.contains(action);

  /// 还在等后台结算 (轮询继续)。
  bool get settling =>
      status == WmPeriodStatus.counted && closeState == WmCloseState.queued;

  factory WmCloseStatus.fromJson(Map<String, dynamic> json) {
    final last = _map(json['lastClose']);
    return WmCloseStatus(
      status: _s(json['status']) ?? WmPeriodStatus.open,
      closeState: _s(json['closeState']) ?? WmCloseState.none,
      attempts: _i(json['attempts']),
      failures: _i(json['failures']),
      attemptedAt: _s(json['attemptedAt']),
      lastErrorMessage: _s(json['lastErrorMessage']),
      blockers: WmBlocker.listOf(json['blockers']),
      heldUntil: _s(json['heldUntil']),
      lastClose: last == null ? null : WmLastClose.fromJson(last),
      allowedActions: _strings(json['allowedActions']),
    );
  }
}

/// 内料仓现存一行 (一种料)。
class WmPositionRow {
  const WmPositionRow({
    required this.goodsId,
    this.colorId,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.unitName,
    this.bulkPackageQty,
    this.bookQty = 0,
    this.lastCountQty,
    this.lastCountDate,
    this.periodInQty = 0,
    this.periodReturnQty = 0,
    this.periodOtherQty = 0,
    this.estimatedUsedQty = 0,
    this.estimatedRemainingQty = 0,
    this.warehouseAvailableQty = 0,
    this.missingWeightProducts = 0,
    this.draftReportCount = 0,
  });

  final String goodsId;
  final String? colorId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final String? unitName;
  final double? bulkPackageQty;
  final double bookQty;
  final double? lastCountQty;
  final String? lastCountDate;
  final double periodInQty;
  final double periodReturnQty;
  final double periodOtherQty;
  final double estimatedUsedQty;
  final double estimatedRemainingQty;
  final double warehouseAvailableQty;
  final int missingWeightProducts;
  final int draftReportCount;

  String get key => wmMaterialKey(goodsId, colorId);

  factory WmPositionRow.fromJson(Map<String, dynamic> json) => WmPositionRow(
    goodsId: json['goodsId'] as String,
    colorId: _s(json['colorId']),
    goodsCode: _s(json['goodsCode']),
    goodsName: _s(json['goodsName']),
    colorName: _s(json['colorName']),
    unitName: _s(json['unitName']),
    bulkPackageQty: _dn(json['bulkPackageQty']),
    bookQty: _d(json['bookQty']),
    lastCountQty: _dn(json['lastCountQty']),
    lastCountDate: _s(json['lastCountDate']),
    periodInQty: _d(json['periodInQty']),
    periodReturnQty: _d(json['periodReturnQty']),
    periodOtherQty: _d(json['periodOtherQty']),
    estimatedUsedQty: _d(json['estimatedUsedQty']),
    estimatedRemainingQty: _d(json['estimatedRemainingQty']),
    warehouseAvailableQty: _d(json['warehouseAvailableQty']),
    missingWeightProducts: _i(json['missingWeightProducts']),
    draftReportCount: _i(json['draftReportCount']),
  );
}

/// 内料仓页数据 (GET /bins/{binId}/position): 现存行 + 顶部盘点/结算状态。
class WmPosition {
  const WmPosition({
    required this.rows,
    this.periodId,
    this.periodStatus,
    this.closeState = WmCloseState.none,
    this.blockers = const [],
    this.heldUntil,
    this.allowedActions = const [],
  });

  final List<WmPositionRow> rows;

  /// 顶部状态所指的那一期 (盘点中或已盘点未结算的那一期; 没有时为空)。
  final String? periodId;
  final String? periodStatus;
  final String closeState;
  final List<WmBlocker> blockers;
  final String? heldUntil;
  final List<String> allowedActions;

  bool can(String action) => allowedActions.contains(action);

  factory WmPosition.fromJson(Map<String, dynamic> json) => WmPosition(
    rows: _maps(
      json['rows'] ?? json['items'],
    ).map(WmPositionRow.fromJson).toList(growable: false),
    periodId: _s(json['periodId']) ?? _s(_map(json['pendingPeriod'])?['id']),
    periodStatus: _s(json['periodStatus']),
    closeState: _s(json['closeState']) ?? WmCloseState.none,
    blockers: WmBlocker.listOf(json['blockers']),
    heldUntil: _s(json['heldUntil']),
    allowedActions: _strings(json['allowedActions']),
  );
}

/// 某个叶仓里这种料还能发多少。
class WmLeafStock {
  const WmLeafStock({
    required this.warehouseId,
    required this.warehouseName,
    this.availableQty = 0,
  });

  final String warehouseId;
  final String warehouseName;
  final double availableQty;

  factory WmLeafStock.fromJson(Map<String, dynamic> json) => WmLeafStock(
    warehouseId: json['warehouseId'] as String,
    warehouseName: _s(json['warehouseName']) ?? '',
    availableQty: _d(json['availableQty']),
  );
}

/// 可发到内料仓的一种料 (只列整批领料的料)。
class WmMaterialOption {
  const WmMaterialOption({
    required this.goodsId,
    required this.goodsName,
    this.goodsCode,
    this.colorId,
    this.colorName,
    this.unitName,
    this.bulkPackageQty,
    this.costBasis,
    this.defaultLeafWarehouseId,
    this.defaultLeafWarehouseName,
    this.warehouseAvailableQty = 0,
    this.leafWarehouses = const [],
  });

  final String goodsId;
  final String goodsName;
  final String? goodsCode;
  final String? colorId;
  final String? colorName;
  final String? unitName;

  /// 每袋净重 (公斤); 没设时袋数不能自动换算公斤。
  final double? bulkPackageQty;

  /// 分摊方式快照: OWN 主料 / SHARED 辅料 / EXPENSE 记车间费用。
  final String? costBasis;
  final String? defaultLeafWarehouseId;
  final String? defaultLeafWarehouseName;
  final double warehouseAvailableQty;
  final List<WmLeafStock> leafWarehouses;

  String get key => wmMaterialKey(goodsId, colorId);

  String get displayName => [
    goodsName,
    if (colorName != null && colorName!.isNotEmpty) colorName!,
  ].join(' ');

  factory WmMaterialOption.fromJson(Map<String, dynamic> json) =>
      WmMaterialOption(
        goodsId: json['goodsId'] as String,
        goodsName: _s(json['goodsName']) ?? '',
        goodsCode: _s(json['goodsCode']),
        colorId: _s(json['colorId']),
        colorName: _s(json['colorName']),
        unitName: _s(json['unitName']),
        bulkPackageQty: _dn(json['bulkPackageQty']),
        costBasis: _s(json['costBasis'] ?? json['periodicCostBasis']),
        defaultLeafWarehouseId: _s(json['defaultLeafWarehouseId']),
        defaultLeafWarehouseName: _s(json['defaultLeafWarehouseName']),
        warehouseAvailableQty: _d(json['warehouseAvailableQty']),
        leafWarehouses: _maps(
          json['leafWarehouses'],
        ).map(WmLeafStock.fromJson).toList(growable: false),
      );
}

/// 领料单一行。
class WmRequisitionLine {
  const WmRequisitionLine({
    required this.id,
    required this.goodsId,
    this.lineNo = 0,
    this.goodsCode,
    this.goodsName,
    this.colorId,
    this.colorName,
    this.unitName,
    this.requestedQty = 0,
    this.requestedBags,
    this.bulkPackageQty,
    this.suggestedLeafWarehouseId,
    this.suggestedLeafWarehouseName,
    this.fulfilledQty = 0,
  });

  final String id;
  final int lineNo;
  final String goodsId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorId;
  final String? colorName;
  final String? unitName;
  final double requestedQty;
  final double? requestedBags;
  final double? bulkPackageQty;
  final String? suggestedLeafWarehouseId;
  final String? suggestedLeafWarehouseName;
  final double fulfilledQty;

  String get key => wmMaterialKey(goodsId, colorId);

  String get displayName => [
    goodsName ?? '',
    if (colorName != null && colorName!.isNotEmpty) colorName!,
  ].join(' ');

  factory WmRequisitionLine.fromJson(Map<String, dynamic> json) =>
      WmRequisitionLine(
        id: json['id'] as String,
        lineNo: _i(json['lineNo']),
        goodsId: json['goodsId'] as String,
        goodsCode: _s(json['goodsCode']),
        goodsName: _s(json['goodsName']),
        colorId: _s(json['colorId']),
        colorName: _s(json['colorName']),
        unitName: _s(json['unitName']),
        requestedQty: _d(json['requestedQty']),
        requestedBags: _dn(json['requestedBags']),
        bulkPackageQty: _dn(json['bulkPackageQty']),
        suggestedLeafWarehouseId: _s(json['suggestedLeafWarehouseId']),
        suggestedLeafWarehouseName: _s(json['suggestedLeafWarehouseName']),
        fulfilledQty: _d(json['fulfilledQty']),
      );
}

/// 领料单 / 退回单 (车间申请或仓库直接发料)。人名由服务端随单解析返回。
class WmRequisition {
  const WmRequisition({
    required this.id,
    required this.requestNo,
    required this.kind,
    required this.status,
    this.origin,
    this.workshopDepartmentId,
    this.workshopName,
    this.binWarehouseId,
    this.binWarehouseName,
    this.receiverEmployeeId,
    this.receiverName,
    this.requestedByName,
    this.requestedAt,
    this.doneByName,
    this.doneAt,
    this.cancelledByName,
    this.cancelledAt,
    this.cancelReason,
    this.remark,
    this.rowVersion = 0,
    this.lines = const [],
    this._materialSummary,
    this._totalQty,
    this.allowedActions = const [],
  });

  final String id;
  final String requestNo;

  /// ISSUE 领料 / RETURN 退回。
  final String kind;

  /// PENDING / DONE / CANCELLED。
  final String status;

  /// WORKSHOP_REQUEST 车间申请 / WAREHOUSE_DIRECT 仓库直接发料。
  final String? origin;
  final String? workshopDepartmentId;
  final String? workshopName;
  final String? binWarehouseId;
  final String? binWarehouseName;
  final String? receiverEmployeeId;
  final String? receiverName;
  final String? requestedByName;
  final String? requestedAt;
  final String? doneByName;
  final String? doneAt;
  final String? cancelledByName;
  final String? cancelledAt;
  final String? cancelReason;
  final String? remark;
  final int rowVersion;
  final List<WmRequisitionLine> lines;
  final String? _materialSummary;
  final double? _totalQty;
  final List<String> allowedActions;

  bool can(String action) => allowedActions.contains(action);
  bool get isReturn => kind == 'RETURN';
  bool get isPending => status == 'PENDING';

  /// 料名摘要 (列表行; 服务端没给时由明细拼)。
  String get materialSummary {
    final summary = _materialSummary;
    if (summary != null && summary.isNotEmpty) return summary;
    if (lines.isEmpty) return '';
    final first = lines.first.displayName;
    return lines.length == 1 ? first : '$first 等 ${lines.length} 种';
  }

  /// 合计公斤 (列表行; 服务端没给时由明细加)。
  double get totalQty =>
      _totalQty ?? lines.fold<double>(0, (sum, l) => sum + l.requestedQty);

  factory WmRequisition.fromJson(Map<String, dynamic> json) => WmRequisition(
    id: json['id'] as String,
    requestNo: _s(json['requestNo']) ?? '',
    kind: _s(json['kind']) ?? 'ISSUE',
    status: _s(json['status']) ?? 'PENDING',
    origin: _s(json['origin']),
    workshopDepartmentId: _s(json['workshopDepartmentId']),
    workshopName: _s(json['workshopName']),
    binWarehouseId: _s(json['binWarehouseId']),
    binWarehouseName: _s(json['binWarehouseName']),
    receiverEmployeeId: _s(json['receiverEmployeeId']),
    receiverName: _s(json['receiverName']),
    requestedByName: _s(json['requestedByName']),
    requestedAt: _s(json['requestedAt']),
    doneByName: _s(json['doneByName']),
    doneAt: _s(json['doneAt']),
    cancelledByName: _s(json['cancelledByName']),
    cancelledAt: _s(json['cancelledAt']),
    cancelReason: _s(json['cancelReason']),
    remark: _s(json['remark']),
    rowVersion: _i(json['rowVersion']),
    lines: _maps(
      json['lines'],
    ).map(WmRequisitionLine.fromJson).toList(growable: false),
    materialSummary: _s(json['materialSummary']),
    totalQty: _dn(json['totalQty']),
    allowedActions: _strings(json['allowedActions']),
  );
}

/// 发料 / 收退回完成后建出的一张调拨单。
class WmIssuedDocument {
  const WmIssuedDocument({this.docId, this.docNo, this.warehouseName});

  final String? docId;
  final String? docNo;
  final String? warehouseName;

  factory WmIssuedDocument.fromJson(Map<String, dynamic> json) =>
      WmIssuedDocument(
        docId: _s(json['docId'] ?? json['documentId'] ?? json['id']),
        docNo: _s(json['docNo'] ?? json['billNo']),
        warehouseName: _s(json['warehouseName'] ?? json['leafWarehouseName']),
      );
}

/// 发料结果: 领料单号、每张调拨单号、记进了哪一期。
class WmIssueResult {
  const WmIssueResult({
    this.requisitionId,
    this.requestNo,
    this.documents = const [],
    this.period,
  });

  final String? requisitionId;
  final String? requestNo;
  final List<WmIssuedDocument> documents;
  final WmPeriod? period;

  factory WmIssueResult.fromJson(Map<String, dynamic> json) {
    final period = _map(json['period']);
    return WmIssueResult(
      requisitionId: _s(json['requisitionId'] ?? json['id']),
      requestNo: _s(json['requestNo']),
      documents: _maps(
        json['documents'] ?? json['transfers'],
      ).map(WmIssuedDocument.fromJson).toList(growable: false),
      period: period == null || period['id'] == null
          ? null
          : WmPeriod.fromJson(period),
    );
  }
}

/// 直接发料默认值: 该车间上一次的领料人 (姓名由服务端随带)。
class WmDirectIssueDefaults {
  const WmDirectIssueDefaults({
    this.receiverEmployeeId,
    this.receiverName,
    this.receiverCode,
  });

  final String? receiverEmployeeId;
  final String? receiverName;
  final String? receiverCode;

  factory WmDirectIssueDefaults.fromJson(Map<String, dynamic> json) =>
      WmDirectIssueDefaults(
        receiverEmployeeId: _s(json['receiverEmployeeId']),
        receiverName: _s(json['receiverName']),
        receiverCode: _s(json['receiverCode']),
      );
}

/// 机台上的一个容器 (如干燥机料斗 50 公斤、储料桶 100 公斤)。
class WmContainer {
  const WmContainer({
    required this.id,
    required this.machineId,
    required this.name,
    required this.capacityQty,
    this.enabled = true,
    this.sortOrder = 0,
    this.rowVersion = 0,
  });

  final String id;
  final String machineId;
  final String name;
  final double capacityQty;
  final bool enabled;
  final int sortOrder;
  final int rowVersion;

  factory WmContainer.fromJson(Map<String, dynamic> json) => WmContainer(
    id: json['id'] as String,
    machineId: _s(json['machineId']) ?? '',
    name: _s(json['name']) ?? '',
    capacityQty: _d(json['capacityQty']),
    enabled: json['enabled'] == null ? true : _b(json['enabled']),
    sortOrder: _i(json['sortOrder']),
    rowVersion: _i(json['rowVersion']),
  );
}

/// 一台机 (含容器)。
class WmMachine {
  const WmMachine({
    required this.id,
    required this.code,
    required this.name,
    this.workshopDepartmentId,
    this.model,
    this.tonnage,
    this.enabled = true,
    this.sortOrder = 0,
    this.remark,
    this.rowVersion = 0,
    this.containers = const [],
  });

  final String id;
  final String code;
  final String name;
  final String? workshopDepartmentId;
  final String? model;
  final double? tonnage;
  final bool enabled;
  final int sortOrder;
  final String? remark;
  final int rowVersion;
  final List<WmContainer> containers;

  factory WmMachine.fromJson(Map<String, dynamic> json) => WmMachine(
    id: json['id'] as String,
    code: _s(json['code']) ?? '',
    name: _s(json['name']) ?? '',
    workshopDepartmentId: _s(json['workshopDepartmentId']),
    model: _s(json['model']),
    tonnage: _dn(json['tonnage']),
    enabled: json['enabled'] == null ? true : _b(json['enabled']),
    sortOrder: _i(json['sortOrder']),
    remark: _s(json['remark']),
    rowVersion: _i(json['rowVersion']),
    containers: _maps(
      json['containers'],
    ).map(WmContainer.fromJson).toList(growable: false),
  );
}

/// 料的引用 (认料用: 货品 + 颜色 + 显示名)。
class WmMaterialRef {
  const WmMaterialRef({
    required this.goodsId,
    this.colorId,
    this.goodsName,
    this.goodsCode,
    this.colorName,
  });

  final String goodsId;
  final String? colorId;
  final String? goodsName;
  final String? goodsCode;
  final String? colorName;

  String get key => wmMaterialKey(goodsId, colorId);

  String get displayName => [
    goodsName ?? goodsCode ?? '',
    if (colorName != null && colorName!.isNotEmpty) colorName!,
  ].join(' ');

  Map<String, dynamic> toJson() => {'goodsId': goodsId, 'colorId': colorId};

  factory WmMaterialRef.fromJson(Map<String, dynamic> json) => WmMaterialRef(
    goodsId: json['goodsId'] as String,
    colorId: _s(json['colorId']),
    goodsName: _s(json['goodsName'] ?? json['name']),
    goodsCode: _s(json['goodsCode']),
    colorName: _s(json['colorName']),
  );
}

/// 开启整批领料前本车间在产、还没认料的一个产品 (含预填)。
class WmPendingProductChoice {
  const WmPendingProductChoice({
    required this.productGoodsId,
    this.productCode,
    this.productName,
    this.productColorName,
    this.taskCount = 0,
    this.prefillMaterials = const [],
    this.prefillSource,
    this.materialOptions = const [],
    this.unitWeightGrams,
    this.canAlsoOrderMaterials = false,
  });

  final String productGoodsId;
  final String? productCode;
  final String? productName;
  final String? productColorName;
  final int taskCount;
  final List<WmMaterialRef> prefillMaterials;

  /// 预填来源: LEGACY_MATERIAL_TEXT = 老库材质唯一命中。
  final String? prefillSource;
  final List<WmMaterialRef> materialOptions;
  final double? unitWeightGrams;

  /// 能不能勾"还要按工单领别的料" (= 产品没有任何 BOM)。
  final bool canAlsoOrderMaterials;

  /// 2026-09-29 用户口径：名称只显名称（颜色不再拼进名称串，见
  /// [productSubline]——需要颜色的地方走副行）。
  String get productDisplay => productName ?? productCode ?? '';

  /// 副行属性（颜色）；为空返回 null。
  String? get productSubline =>
      (productColorName == null || productColorName!.isEmpty)
      ? null
      : productColorName;

  /// 服务端形状 = WorkshopMaterialChoicePort.PendingChoice: prefill 只带
  /// {goodsId, colorId}, 显示名从 options 里补; 单个重量取 bomWeights 第一条。
  factory WmPendingProductChoice.fromJson(Map<String, dynamic> json) {
    final options = _maps(
      json['materialOptions'] ?? json['options'],
    ).map(WmMaterialRef.fromJson).toList(growable: false);
    WmMaterialRef named(WmMaterialRef ref) {
      if (ref.goodsName != null || ref.goodsCode != null) return ref;
      for (final option in options) {
        if (option.key == ref.key) return option;
      }
      return ref;
    }

    final weights = _maps(json['bomWeights']);
    return WmPendingProductChoice(
      productGoodsId: json['productGoodsId'] as String,
      productCode: _s(json['productCode']),
      productName: _s(json['productName']),
      productColorName: _s(json['productColorName']),
      taskCount: _i(json['taskCount']),
      prefillMaterials: _maps(
        json['prefillMaterials'] ?? json['prefill'],
      ).map(WmMaterialRef.fromJson).map(named).toList(growable: false),
      prefillSource: _s(json['prefillSource']),
      materialOptions: options,
      unitWeightGrams:
          _dn(json['unitWeightGrams']) ??
          (weights.isEmpty ? null : _dn(weights.first['unitWeightGrams'])),
      canAlsoOrderMaterials: _b(
        json['canAlsoOrderMaterials'] ?? json['alsoOrderMaterialsAllowed'],
      ),
    );
  }
}

/// 开启时对一个在产产品的认料 (MATERIAL 用这些料 / NONE 不用内料仓的料)。
class WmProductChoiceInput {
  const WmProductChoiceInput({
    required this.productGoodsId,
    required this.kind,
    this.materials = const [],
    this.alsoOrderMaterials = false,
    this.prefillSource,
  });

  final String productGoodsId;
  final String kind;
  final List<WmMaterialRef> materials;
  final bool alsoOrderMaterials;
  final String? prefillSource;

  Map<String, dynamic> toJson() => {
    'productGoodsId': productGoodsId,
    'kind': kind,
    'materials': [for (final m in materials) m.toJson()],
    'alsoOrderMaterials': alsoOrderMaterials,
    if (prefillSource != null) 'prefillSource': prefillSource,
  };
}

/// 盘点单里一个容器。
class WmCountContainer {
  const WmCountContainer({
    required this.containerId,
    required this.name,
    required this.capacityQty,
    this.sortOrder = 0,
    this.clientLineKey,
  });

  final String containerId;
  final String name;
  final double capacityQty;
  final int sortOrder;

  /// 服务端建议的行键 (已录时就是那一行的行键); 新录这个容器时沿用它。
  final String? clientLineKey;

  factory WmCountContainer.fromJson(Map<String, dynamic> json) =>
      WmCountContainer(
        containerId: _s(json['containerId'] ?? json['id']) ?? '',
        name: _s(json['name']) ?? '',
        capacityQty: _d(json['capacityQty']),
        sortOrder: _i(json['sortOrder']),
        clientLineKey: _s(json['clientLineKey']),
      );
}

/// 盘点单里一台机 (卡片分组): 容器 + 上次在用的料。
class WmCountMachine {
  const WmCountMachine({
    required this.machineId,
    required this.name,
    this.code,
    this.sortOrder = 0,
    this.lastGoodsId,
    this.lastColorId,
    this.containers = const [],
  });

  final String machineId;
  final String name;
  final String? code;
  final int sortOrder;
  final String? lastGoodsId;
  final String? lastColorId;
  final List<WmCountContainer> containers;

  String get title => name.isNotEmpty ? name : (code ?? '');

  factory WmCountMachine.fromJson(Map<String, dynamic> json) => WmCountMachine(
    machineId: _s(json['machineId'] ?? json['id']) ?? '',
    name: _s(json['name']) ?? '',
    code: _s(json['code']),
    sortOrder: _i(json['sortOrder']),
    lastGoodsId: _s(json['lastGoodsId']),
    lastColorId: _s(json['lastColorId']),
    containers: _maps(
      json['containers'],
    ).map(WmCountContainer.fromJson).toList(growable: false),
  );
}

/// 这一期要盘的一种料 (有账或有进出)。
class WmCountMaterial {
  const WmCountMaterial({
    required this.goodsId,
    this.colorId,
    this.goodsCode,
    this.goodsName,
    this.colorName,
    this.bulkPackageQty,
    this.clientLineKey,
  });

  final String goodsId;
  final String? colorId;
  final String? goodsCode;
  final String? goodsName;
  final String? colorName;
  final double? bulkPackageQty;

  /// 服务端建议的整袋行行键; 新录这种料的整袋数时沿用它。
  final String? clientLineKey;

  String get key => wmMaterialKey(goodsId, colorId);

  String get displayName => [
    goodsName ?? goodsCode ?? '',
    if (colorName != null && colorName!.isNotEmpty) colorName!,
  ].join(' ');

  factory WmCountMaterial.fromJson(Map<String, dynamic> json) =>
      WmCountMaterial(
        goodsId: json['goodsId'] as String,
        colorId: _s(json['colorId']),
        goodsCode: _s(json['goodsCode']),
        goodsName: _s(json['goodsName']),
        colorName: _s(json['colorName']),
        bulkPackageQty: _dn(json['bulkPackageQty'] ?? json['bagNetQty']),
        clientLineKey: _s(json['clientLineKey']),
      );
}

/// 盘点行种类。
abstract final class WmLineKind {
  static const fullBags = 'FULL_BAGS';
  static const container = 'CONTAINER';
  static const weighed = 'WEIGHED';
}

/// 容器档位。
abstract final class WmFillLevel {
  static const full = 'FULL';
  static const half = 'HALF';
  static const empty = 'EMPTY';
  static const weighed = 'WEIGHED';
}

/// 过秤行的分组标注 (只用于显示)。
abstract final class WmWeighNote {
  static const openBag = 'OPEN_BAG';
  static const mixed = 'MIXED';
  static const loose = 'LOOSE';
}

/// 盘点单一行 (逐行保存, 行版本乐观锁)。
class WmCountLine {
  const WmCountLine({
    required this.clientLineKey,
    required this.lineKind,
    this.id,
    this.weighNote,
    this.goodsId,
    this.colorId,
    this.goodsName,
    this.colorName,
    this.bagCount,
    this.bagNetQty,
    this.weighedQty,
    this.machineId,
    this.containerId,
    this.capacityQtySnapshot,
    this.fillLevel,
    this.qtyBase,
    this.rowVersion,
  });

  final String? id;
  final String clientLineKey;
  final String lineKind;
  final String? weighNote;
  final String? goodsId;
  final String? colorId;
  final String? goodsName;
  final String? colorName;
  final double? bagCount;
  final double? bagNetQty;
  final double? weighedQty;
  final String? machineId;
  final String? containerId;
  final double? capacityQtySnapshot;
  final String? fillLevel;
  final double? qtyBase;

  /// 行版本; 还没落库的新行为空。
  final int? rowVersion;

  factory WmCountLine.fromJson(Map<String, dynamic> json) => WmCountLine(
    id: _s(json['id']),
    clientLineKey: _s(json['clientLineKey']) ?? '',
    lineKind: _s(json['lineKind']) ?? WmLineKind.weighed,
    weighNote: _s(json['weighNote']),
    goodsId: _s(json['goodsId']),
    colorId: _s(json['colorId']),
    goodsName: _s(json['goodsName']),
    colorName: _s(json['colorName']),
    bagCount: _dn(json['bagCount']),
    bagNetQty: _dn(json['bagNetQty']),
    weighedQty: _dn(json['weighedQty']),
    machineId: _s(json['machineId']),
    containerId: _s(json['containerId']),
    capacityQtySnapshot: _dn(
      json['capacityQtySnapshot'] ?? json['capacityQty'],
    ),
    fillLevel: _s(json['fillLevel']),
    qtyBase: _dn(json['qtyBase']),
    rowVersion: _in(json['rowVersion']),
  );

  /// 已落库 (有行版本)。
  bool get persisted => rowVersion != null;

  WmCountLine copyWith({
    String? id,
    int? rowVersion,
    String? goodsId,
    String? colorId,
    String? goodsName,
    String? colorName,
    double? weighedQty,
    double? qtyBase,
  }) => WmCountLine(
    id: id ?? this.id,
    clientLineKey: clientLineKey,
    lineKind: lineKind,
    weighNote: weighNote,
    goodsId: goodsId ?? this.goodsId,
    colorId: colorId ?? this.colorId,
    goodsName: goodsName ?? this.goodsName,
    colorName: colorName ?? this.colorName,
    bagCount: bagCount,
    bagNetQty: bagNetQty,
    weighedQty: weighedQty ?? this.weighedQty,
    machineId: machineId,
    containerId: containerId,
    capacityQtySnapshot: capacityQtySnapshot,
    fillLevel: fillLevel,
    qtyBase: qtyBase ?? this.qtyBase,
    rowVersion: rowVersion ?? this.rowVersion,
  );

  /// 逐行保存请求体 (PUT /counts/{id}/lines/{clientLineKey})。
  Map<String, dynamic> toSaveJson() => {
    'expectedVersion': rowVersion,
    'lineKind': lineKind,
    'weighNote': weighNote,
    'goodsId': goodsId,
    'colorId': colorId,
    'bagCount': bagCount,
    'bagNetQty': bagNetQty,
    'weighedQty': weighedQty,
    'machineId': machineId,
    'containerId': containerId,
    'fillLevel': fillLevel,
  };
}

/// 盘点单 + 行 + 机台卡片分组 + 要盘的料。
class WmCount {
  const WmCount({
    required this.id,
    required this.periodId,
    required this.status,
    this.version = 1,
    this.rowVersion = 0,
    this.correctionReason,
    this.submittedByName,
    this.submittedAt,
    this.lines = const [],
    this.machines = const [],
    this.materials = const [],
    this.period,
    this.allowedActions = const [],
  });

  final String id;
  final String periodId;

  /// DRAFT / SUBMITTED / SUPERSEDED。
  final String status;
  final int version;
  final int rowVersion;
  final String? correctionReason;
  final String? submittedByName;
  final String? submittedAt;
  final List<WmCountLine> lines;
  final List<WmCountMachine> machines;
  final List<WmCountMaterial> materials;
  final WmPeriod? period;
  final List<String> allowedActions;

  bool can(String action) => allowedActions.contains(action);
  bool get isDraft => status == 'DRAFT';

  factory WmCount.fromJson(Map<String, dynamic> json) {
    final period = _map(json['period']);
    return WmCount(
      id: json['id'] as String,
      periodId: _s(json['periodId']) ?? (period?['id'] as String?) ?? '',
      status: _s(json['status']) ?? 'DRAFT',
      version: _in(json['version']) ?? 1,
      rowVersion: _i(json['rowVersion']),
      correctionReason: _s(json['correctionReason']),
      submittedByName: _s(json['submittedByName']),
      submittedAt: _s(json['submittedAt']),
      lines: _maps(
        json['lines'],
      ).map(WmCountLine.fromJson).toList(growable: false),
      machines: _maps(
        json['machines'],
      ).map(WmCountMachine.fromJson).toList(growable: false),
      materials: _maps(
        json['materials'],
      ).map(WmCountMaterial.fromJson).toList(growable: false),
      period: period == null || period['id'] == null
          ? null
          : WmPeriod.fromJson(period),
      allowedActions: _strings(json['allowedActions']),
    );
  }
}

/// 开始盘点的结果: 期间 (盘点中) + 新盘点单 (草稿, 已预置行)。
class WmStartCountResult {
  const WmStartCountResult({required this.period, required this.count});

  final WmPeriod period;
  final WmCount count;

  factory WmStartCountResult.fromJson(Map<String, dynamic> json) {
    final countJson = _map(json['count']) ?? json;
    final periodJson = _map(json['period']) ?? _map(countJson['period']);
    final count = WmCount.fromJson(countJson);
    return WmStartCountResult(
      period: periodJson != null
          ? WmPeriod.fromJson(periodJson)
          : WmPeriod(
              id: count.periodId,
              periodNo: 0,
              startDate: '',
              status: WmPeriodStatus.counting,
            ),
      count: count,
    );
  }
}

/// 上线准备一行 (GET /master/goods/periodic-bom/preparation 的 rows[]):
/// 产品 | 老库材质 | 颗粒 | 单个重量 (克) | 货品资料单重 (克) | 状态。
/// 一个产品一行; 双料件 (BOM 里有两种整批领料的料) 一种料一行。
class WmPreparationRow {
  const WmPreparationRow({
    required this.productGoodsId,
    this.productCode,
    this.productName,
    this.productSpec,
    this.legacyMaterial,
    this.recentRuns = 0,
    this.bomItemId,
    this.materialGoodsId,
    this.materialCode,
    this.materialName,
    this.materialColorId,
    this.materialSource,
    this.unitWeightGrams,
    this.goodsWeightGrams,
    this.status,
    this.alsoOrderMaterials = false,
    this.hasOrderBom = false,
  });

  final String productGoodsId;
  final String? productCode;
  final String? productName;
  final String? productSpec;

  /// 老库货品「材质」文字。
  final String? legacyMaterial;

  /// 近 12 个月在该车间做过几次。
  final int recentRuns;

  /// 已有期间边的 BOM 行; 没有为空。保存时带上它 = 改这一行 (改料或改单重)。
  final String? bomItemId;
  final String? materialGoodsId;
  final String? materialCode;
  final String? materialName;
  final String? materialColorId;

  /// 料从哪来: BOM (BOM 里已有) / CHOICE (车间认过) / LEGACY_MATERIAL_TEXT (老库材质唯一命中) / null。
  final String? materialSource;

  /// BOM 里的单个重量 (克)。
  final double? unitWeightGrams;

  /// 货品资料单重按质量单位换算成的克数 (非质量单位为空), 一键填入用。
  final double? goodsWeightGrams;

  /// WEIGHED 已填单重 / CHOSEN 已选料未填单重 / NOT_FROM_STORE 不用内料仓的料 / PENDING 待准备。
  final String? status;

  /// 认料时勾了「还要按工单领别的料」。
  final bool alsoOrderMaterials;

  /// 产品另有按工单领的 BOM 行 (嵌件、包材等)。
  final bool hasOrderBom;

  /// 料是老库材质文字唯一命中预填的 (没人确认过)。
  bool get prefilledFromLegacy => materialSource == 'LEGACY_MATERIAL_TEXT';

  factory WmPreparationRow.fromJson(Map<String, dynamic> json) =>
      WmPreparationRow(
        productGoodsId: json['productGoodsId'] as String,
        productCode: _s(json['productCode']),
        productName: _s(json['productName']),
        productSpec: _s(json['productSpec']),
        legacyMaterial: _s(json['legacyMaterial']),
        recentRuns: _i(json['recentRuns']),
        bomItemId: _s(json['bomItemId']),
        materialGoodsId: _s(json['materialGoodsId']),
        materialCode: _s(json['materialCode']),
        materialName: _s(json['materialName']),
        materialColorId: _s(json['materialColorId']),
        materialSource: _s(json['materialSource']),
        unitWeightGrams: _dn(json['unitWeightGrams']),
        goodsWeightGrams: _dn(json['goodsWeightGrams']),
        status: _s(json['status']),
        alsoOrderMaterials: _b(json['alsoOrderMaterials']),
        hasOrderBom: _b(json['hasOrderBom']),
      );
}

/// 上线准备列表 + 顶部进度 + 可选的料 (后端 PreparationView)。
class WmPreparation {
  const WmPreparation({
    required this.rows,
    this.workshopDepartmentId,
    this.workshopName,
    this.total = 0,
    this.chosen = 0,
    this.weighed = 0,
    this.materials = const [],
  });

  final List<WmPreparationRow> rows;
  final String? workshopDepartmentId;
  final String? workshopName;

  /// 产品数。
  final int total;

  /// 已选料 (BOM 里有整批领料的料, 或认了料) 的产品数。
  final int chosen;

  /// 已填单个重量的产品数。
  final int weighed;

  /// 可选的料 (本车间内料仓收的整批领料主料)。
  final List<WmMaterialOption> materials;

  factory WmPreparation.fromJson(Map<String, dynamic> json) {
    final rows = _maps(
      json['rows'],
    ).map(WmPreparationRow.fromJson).toList(growable: false);
    return WmPreparation(
      rows: rows,
      workshopDepartmentId: _s(json['workshopDepartmentId']),
      workshopName: _s(json['workshopName']),
      total: _in(json['totalProducts']) ?? rows.length,
      chosen: _i(json['chosenProducts']),
      weighed: _i(json['weighedProducts']),
      // 后端 MaterialOption: {goodsId, code, name, colorId, colorName, unitName, gramsConvertible}。
      materials: [
        for (final m in _maps(json['materials']))
          if (m['goodsId'] != null)
            WmMaterialOption(
              goodsId: m['goodsId'] as String,
              goodsName: _s(m['name']) ?? _s(m['code']) ?? '',
              goodsCode: _s(m['code']),
              colorId: _s(m['colorId']),
              colorName: _s(m['colorName']),
              unitName: _s(m['unitName']),
              costBasis: 'OWN',
            ),
      ],
    );
  }
}
