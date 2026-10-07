// 员工资料核对更正(ADR-160)API 模型：核对计划 PlanView / 行 RowView / 项 ItemView /
// 执行 ApplyRequest·ApplyResult / 记录 PlanSummary，对应后端
// /api/org/employee-reconcile 契约（契约见 ADR-160，服务端同源实现）。
//
// 解析严格：字段存在但类型不符直接抛 FormatException（与仓库其他 model 的
// 「宁可在解析层炸掉也不静默吞错」同一口径）；可缺省字段用 *OrNull 容忍 null。
// 无 employee:pii:view 时 oldValue/newValue/candidates.value 是打码串
// （如 '****123X'），diffPositions/suspectPositions/candidates 可能为空——模型
// 原样承载，是否按打码渲染由页面按 capabilities.viewPii 决定。

/// 计划状态。
enum HrReconcilePlanStatus {
  open('OPEN'),
  applying('APPLYING'),
  closed('CLOSED');

  const HrReconcilePlanStatus(this.api);
  final String api;

  static HrReconcilePlanStatus fromApi(Object? value) => switch (value) {
    'OPEN' => open,
    'APPLYING' => applying,
    'CLOSED' => closed,
    _ => throw FormatException('未知核对计划状态：$value'),
  };
}

/// 计划关闭原因。
enum HrReconcileClosedReason {
  expired('EXPIRED'),
  discarded('DISCARDED');

  const HrReconcileClosedReason(this.api);
  final String api;

  static HrReconcileClosedReason fromApi(Object? value) => switch (value) {
    'EXPIRED' => expired,
    'DISCARDED' => discarded,
    _ => throw FormatException('未知核对计划关闭原因：$value'),
  };
}

/// 行类型：UPDATE=需更正 / INFO=仅提示 / SAME=一致。
enum HrReconcileRowKind {
  update('UPDATE'),
  info('INFO'),
  same('SAME');

  const HrReconcileRowKind(this.api);
  final String api;

  static HrReconcileRowKind fromApi(Object? value) => switch (value) {
    'UPDATE' => update,
    'INFO' => info,
    'SAME' => same,
    _ => throw FormatException('未知核对行类型：$value'),
  };
}

/// 修复建议把握档位。
enum HrReconcileTier {
  high('HIGH'),
  medium('MEDIUM'),
  manual('MANUAL'),
  none('NONE');

  const HrReconcileTier(this.api);
  final String api;

  static HrReconcileTier fromApi(Object? value) => switch (value) {
    'HIGH' => high,
    'MEDIUM' => medium,
    'MANUAL' => manual,
    'NONE' => none,
    _ => throw FormatException('未知修复建议把握档位：$value'),
  };
}

/// 单项执行结果。
enum HrReconcileOutcomeStatus {
  applied('APPLIED'),
  skipped('SKIPPED'),
  failed('FAILED');

  const HrReconcileOutcomeStatus(this.api);
  final String api;

  static HrReconcileOutcomeStatus fromApi(Object? value) => switch (value) {
    'APPLIED' => applied,
    'SKIPPED' => skipped,
    'FAILED' => failed,
    _ => throw FormatException('未知核对项执行结果：$value'),
  };
}

/// 整行执行结果。
enum HrReconcileRowResultStatus {
  applied('APPLIED'),
  partial('PARTIAL'),
  skipped('SKIPPED'),
  failed('FAILED');

  const HrReconcileRowResultStatus(this.api);
  final String api;

  static HrReconcileRowResultStatus fromApi(Object? value) => switch (value) {
    'APPLIED' => applied,
    'PARTIAL' => partial,
    'SKIPPED' => skipped,
    'FAILED' => failed,
    _ => throw FormatException('未知核对行执行结果：$value'),
  };
}

Never _mismatch(String field, Object? value) =>
    throw FormatException('核对计划字段 $field 类型不符：$value');

String _string(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is String) return value;
  _mismatch(field, value);
}

String? _stringOrNull(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is String) return value.isEmpty ? null : value;
  _mismatch(field, value);
}

int _int(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is int) return value;
  if (value is num) return value.toInt();
  _mismatch(field, value);
}

bool _bool(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value is bool) return value;
  _mismatch(field, value);
}

bool _boolOr(Map<String, dynamic> json, String field, bool fallback) {
  final value = json[field];
  if (value == null) return fallback;
  if (value is bool) return value;
  _mismatch(field, value);
}

double? _doubleOrNull(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is num) return value.toDouble();
  _mismatch(field, value);
}

List<Map<String, dynamic>> _objects(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return const [];
  if (value is! List) _mismatch(field, value);
  return [
    for (final entry in value)
      if (entry is Map<String, dynamic>)
        entry
      else
        _mismatch('$field[]', entry),
  ];
}

List<int> _ints(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return const [];
  if (value is! List) _mismatch(field, value);
  return [
    for (final entry in value)
      if (entry is int)
        entry
      else if (entry is num)
        entry.toInt()
      else
        _mismatch('$field[]', entry),
  ];
}

List<String> _strings(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return const [];
  if (value is! List) _mismatch(field, value);
  return [
    for (final entry in value)
      if (entry is String) entry else _mismatch('$field[]', entry),
  ];
}

Map<String, dynamic>? _objectOrNull(Map<String, dynamic> json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is Map<String, dynamic>) return value;
  _mismatch(field, value);
}

/// 枚举字段：null/空串 = null；未知值抛 FormatException。
E? _enumOrNull<E>(
  Map<String, dynamic> json,
  String field,
  E Function(Object?) fromApi,
) {
  final value = json[field];
  if (value == null || value == '') return null;
  if (value is String) return fromApi(value);
  _mismatch(field, value);
}

/// 计划计数（摘要行与记录列表共用同一结构）。
class HrReconcilePlanCounts {
  const HrReconcilePlanCounts({
    required this.rows,
    required this.update,
    required this.updateItems,
    required this.info,
    required this.same,
    required this.applied,
    required this.skipped,
    required this.failed,
  });

  final int rows;
  final int update;
  final int updateItems;
  final int info;
  final int same;
  final int applied;
  final int skipped;
  final int failed;

  factory HrReconcilePlanCounts.fromJson(Map<String, dynamic> json) =>
      HrReconcilePlanCounts(
        rows: _int(json, 'rows'),
        update: _int(json, 'update'),
        updateItems: _int(json, 'updateItems'),
        info: _int(json, 'info'),
        same: _int(json, 'same'),
        applied: _int(json, 'applied'),
        skipped: _int(json, 'skipped'),
        failed: _int(json, 'failed'),
      );
}

/// 当前账号对这份计划的能力（服务端按权限裁剪）。
class HrReconcilePlanCapabilities {
  const HrReconcilePlanCapabilities({
    required this.viewPii,
    required this.piiEdit,
  });

  /// 能看明文证件号；false 时号码是打码串。
  final bool viewPii;

  /// 能改证件号（勾选/手输/采用按钮的开关之一）。
  final bool piiEdit;

  factory HrReconcilePlanCapabilities.fromJson(Map<String, dynamic> json) =>
      HrReconcilePlanCapabilities(
        viewPii: _bool(json, 'viewPii'),
        piiEdit: _bool(json, 'piiEdit'),
      );
}

/// 核对计划（PlanView，契约见 ADR-160）。
class HrReconcilePlan {
  const HrReconcilePlan({
    required this.id,
    required this.version,
    required this.status,
    this.closedReason,
    this.source,
    this.origin,
    required this.actorName,
    required this.createdAt,
    required this.expiresAt,
    required this.canApply,
    this.readOnlyReason,
    required this.capabilities,
    required this.counts,
    required this.rows,
  });

  final String id;

  /// 乐观锁版本：apply 请求带 planVersion，409 RECONCILE_PLAN_CHANGED 表示已变。
  final int version;
  final HrReconcilePlanStatus status;
  final HrReconcileClosedReason? closedReason;
  final String? source;
  final String? origin;
  final String actorName;
  final String? createdAt;
  final String? expiresAt;

  /// 是否还能执行（OPEN 且属于我且未过期）。
  final bool canApply;
  final String? readOnlyReason;
  final HrReconcilePlanCapabilities capabilities;
  final HrReconcilePlanCounts counts;
  final List<HrReconcileRow> rows;

  bool get expired =>
      status == HrReconcilePlanStatus.closed &&
      closedReason == HrReconcileClosedReason.expired;

  factory HrReconcilePlan.fromJson(Map<String, dynamic> json) =>
      HrReconcilePlan(
        id: _string(json, 'id'),
        version: _int(json, 'version'),
        status: HrReconcilePlanStatus.fromApi(json['status']),
        closedReason: _enumOrNull(
          json,
          'closedReason',
          HrReconcileClosedReason.fromApi,
        ),
        source: _stringOrNull(json, 'source'),
        origin: _stringOrNull(json, 'origin'),
        actorName: _string(json, 'actorName'),
        createdAt: _stringOrNull(json, 'createdAt'),
        expiresAt: _stringOrNull(json, 'expiresAt'),
        canApply: _bool(json, 'canApply'),
        readOnlyReason: _stringOrNull(json, 'readOnlyReason'),
        capabilities: HrReconcilePlanCapabilities.fromJson(
          _objectOrNull(json, 'capabilities') ?? const {},
        ),
        counts: HrReconcilePlanCounts.fromJson(
          _objectOrNull(json, 'counts') ?? const {},
        ),
        rows: [
          for (final row in _objects(json, 'rows'))
            HrReconcileRow.fromJson(row),
        ],
      );
}

/// 行员工摘要（不含证件号——号码只在 ItemView 里）。
class HrReconcileEmployee {
  const HrReconcileEmployee({
    required this.id,
    required this.code,
    required this.name,
    this.deptName,
    this.positionName,
    this.hireDate,
  });

  final String id;
  final String code;
  final String name;
  final String? deptName;
  final String? positionName;

  /// yyyy-MM-dd。
  final String? hireDate;

  factory HrReconcileEmployee.fromJson(Map<String, dynamic> json) =>
      HrReconcileEmployee(
        id: _string(json, 'id'),
        code: _string(json, 'code'),
        name: _string(json, 'name'),
        deptName: _stringOrNull(json, 'deptName'),
        positionName: _stringOrNull(json, 'positionName'),
        hireDate: _stringOrNull(json, 'hireDate'),
      );
}

/// 行认领（软认领，ADR-021 同源）：null=未认领。
class HrReconcileRowClaim {
  const HrReconcileRowClaim({
    required this.byName,
    required this.byMe,
    this.leaseUntil,
  });

  final String byName;
  final bool byMe;
  final String? leaseUntil;

  factory HrReconcileRowClaim.fromJson(Map<String, dynamic> json) =>
      HrReconcileRowClaim(
        byName: _string(json, 'byName'),
        byMe: _bool(json, 'byMe'),
        leaseUntil: _stringOrNull(json, 'leaseUntil'),
      );
}

/// 行提示（服务端原话，不含号码）。
class HrReconcileRowNotice {
  const HrReconcileRowNotice({required this.code, required this.message});

  final String code;
  final String message;

  factory HrReconcileRowNotice.fromJson(Map<String, dynamic> json) =>
      HrReconcileRowNotice(
        code: _string(json, 'code'),
        message: _string(json, 'message'),
      );
}

/// 行执行结果（apply 后服务端回填）。
class HrReconcileRowResult {
  const HrReconcileRowResult({required this.status, this.message});

  final HrReconcileRowResultStatus status;
  final String? message;

  factory HrReconcileRowResult.fromJson(Map<String, dynamic> json) =>
      HrReconcileRowResult(
        status: HrReconcileRowResultStatus.fromApi(json['status']),
        message: _stringOrNull(json, 'message'),
      );
}

/// 核对行（RowView）。
class HrReconcileRow {
  const HrReconcileRow({
    required this.rowNo,
    required this.kind,
    required this.employee,
    this.reason,
    this.claim,
    this.notices = const [],
    this.items = const [],
    this.result,
  });

  final int rowNo;
  final HrReconcileRowKind kind;
  final HrReconcileEmployee employee;

  /// 当前证件号的问题原文（服务端按存量号现算，与证件核对列表同口径）。
  final String? reason;
  final HrReconcileRowClaim? claim;
  final List<HrReconcileRowNotice> notices;
  final List<HrReconcileItem> items;
  final HrReconcileRowResult? result;

  /// 被他人认领（勾选位换成锁）。
  bool get claimedByOther => claim != null && !claim!.byMe;

  factory HrReconcileRow.fromJson(Map<String, dynamic> json) => HrReconcileRow(
    rowNo: _int(json, 'rowNo'),
    kind: HrReconcileRowKind.fromApi(json['kind']),
    reason: _stringOrNull(json, 'reason'),
    employee: HrReconcileEmployee.fromJson(
      _objectOrNull(json, 'employee') ?? const {},
    ),
    claim: _objectOrNull(json, 'claim') == null
        ? null
        : HrReconcileRowClaim.fromJson(json['claim'] as Map<String, dynamic>),
    notices: [
      for (final notice in _objects(json, 'notices'))
        HrReconcileRowNotice.fromJson(notice),
    ],
    items: [
      for (final item in _objects(json, 'items'))
        HrReconcileItem.fromJson(item),
    ],
    result: _objectOrNull(json, 'result') == null
        ? null
        : HrReconcileRowResult.fromJson(json['result'] as Map<String, dynamic>),
  );
}

/// 修复依据（如 BIRTH_ANCHOR=生日对齐）。
class HrReconcileBasis {
  const HrReconcileBasis({required this.code, required this.label});

  final String code;
  final String label;

  factory HrReconcileBasis.fromJson(Map<String, dynamic> json) =>
      HrReconcileBasis(
        code: _string(json, 'code'),
        label: _string(json, 'label'),
      );
}

/// 候选号码（≤3；无 pii:view 时 value 是打码串）。
class HrReconcileCandidate {
  const HrReconcileCandidate({
    required this.value,
    this.probability,
    this.diffPositions = const [],
  });

  final String value;
  final double? probability;
  final List<int> diffPositions;

  factory HrReconcileCandidate.fromJson(Map<String, dynamic> json) =>
      HrReconcileCandidate(
        value: _string(json, 'value'),
        probability: _doubleOrNull(json, 'probability'),
        diffPositions: _ints(json, 'diffPositions'),
      );
}

/// 单项执行结果（APPLIED/SKIPPED/FAILED + 服务端说明）。
class HrReconcileItemOutcome {
  const HrReconcileItemOutcome({required this.status, this.code, this.message});

  final HrReconcileOutcomeStatus status;
  final String? code;
  final String? message;

  factory HrReconcileItemOutcome.fromJson(Map<String, dynamic> json) =>
      HrReconcileItemOutcome(
        status: HrReconcileOutcomeStatus.fromApi(json['status']),
        code: _stringOrNull(json, 'code'),
        message: _stringOrNull(json, 'message'),
      );
}

/// 核对项（ItemView）：一期只有 field=idNumber 一种。
class HrReconcileItem {
  const HrReconcileItem({
    required this.itemNo,
    required this.field,
    required this.label,
    required this.writePath,
    this.oldValue,
    this.newValue,
    this.diffPositions = const [],
    this.basis,
    required this.tier,
    this.probability,
    this.preselected = false,
    this.permitted = true,
    this.permissionLabel,
    this.candidates = const [],
    this.suspectPositions = const [],
    this.notes = const [],
    this.outcome,
  });

  final int itemNo;
  final String field;
  final String label;
  final String? writePath;

  /// 旧证件号；无 pii:view 时是打码串。
  final String? oldValue;

  /// 建议新证件号；无 pii:view 时是打码串。
  final String? newValue;

  /// 建议值与旧值差异位（1-based）；打码时可能为空。
  final List<int> diffPositions;
  final HrReconcileBasis? basis;
  final HrReconcileTier tier;
  final double? probability;

  /// 服务端预选（HIGH 默认采用）。
  final bool preselected;

  /// 当前账号是否有权限改这一项。
  final bool permitted;
  final String? permissionLabel;
  final List<HrReconcileCandidate> candidates;
  final List<int> suspectPositions;
  final List<String> notes;
  final HrReconcileItemOutcome? outcome;

  factory HrReconcileItem.fromJson(Map<String, dynamic> json) =>
      HrReconcileItem(
        itemNo: _int(json, 'itemNo'),
        field: _string(json, 'field'),
        label: _string(json, 'label'),
        writePath: _stringOrNull(json, 'writePath'),
        oldValue: _stringOrNull(json, 'oldValue'),
        newValue: _stringOrNull(json, 'newValue'),
        diffPositions: _ints(json, 'diffPositions'),
        basis: _objectOrNull(json, 'basis') == null
            ? null
            : HrReconcileBasis.fromJson(json['basis'] as Map<String, dynamic>),
        tier: HrReconcileTier.fromApi(json['tier']),
        probability: _doubleOrNull(json, 'probability'),
        preselected: _boolOr(json, 'preselected', false),
        permitted: _boolOr(json, 'permitted', true),
        permissionLabel: _stringOrNull(json, 'permissionLabel'),
        candidates: [
          for (final candidate in _objects(json, 'candidates'))
            HrReconcileCandidate.fromJson(candidate),
        ],
        suspectPositions: _ints(json, 'suspectPositions'),
        notes: _strings(json, 'notes'),
        outcome: _objectOrNull(json, 'outcome') == null
            ? null
            : HrReconcileItemOutcome.fromJson(
                json['outcome'] as Map<String, dynamic>,
              ),
      );
}

/// apply 请求体（ApplyRequest，契约见 ADR-160）。
///
/// 语义：最终值 = value(手输/编辑) 优先，其次 candidates[candidateIndex].value，
/// 都没给 = 采用建议 newValue（如 HIGH 预选）。rows 只放勾选且已确认值的人。
class HrReconcileApplyRequest {
  const HrReconcileApplyRequest({
    required this.planVersion,
    required this.requestId,
    required this.rows,
  });

  final int planVersion;

  /// 幂等键：planId+时间戳，≤64 字符。
  final String requestId;
  final List<HrReconcileApplyRow> rows;

  Map<String, dynamic> toJson() => {
    'planVersion': planVersion,
    'requestId': requestId,
    'rows': [for (final row in rows) row.toJson()],
  };
}

class HrReconcileApplyRow {
  const HrReconcileApplyRow({required this.rowNo, required this.items});

  final int rowNo;
  final List<HrReconcileApplyItem> items;

  factory HrReconcileApplyRow.fromJson(Map<String, dynamic> json) =>
      HrReconcileApplyRow(
        rowNo: _int(json, 'rowNo'),
        items: [
          for (final item in _objects(json, 'items'))
            HrReconcileApplyItem.fromJson(item),
        ],
      );

  Map<String, dynamic> toJson() => {
    'rowNo': rowNo,
    'items': [for (final item in items) item.toJson()],
  };
}

class HrReconcileApplyItem {
  const HrReconcileApplyItem({
    required this.itemNo,
    this.candidateIndex,
    this.value,
  });

  final int itemNo;
  final int? candidateIndex;
  final String? value;

  factory HrReconcileApplyItem.fromJson(Map<String, dynamic> json) =>
      HrReconcileApplyItem(
        itemNo: _int(json, 'itemNo'),
        candidateIndex: json['candidateIndex'] == null
            ? null
            : _int(json, 'candidateIndex'),
        value: _stringOrNull(json, 'value'),
      );

  Map<String, dynamic> toJson() => {
    'itemNo': itemNo,
    'candidateIndex': candidateIndex,
    'value': value,
  };
}

/// apply 响应（ApplyResult）。
class HrReconcileApplyResult {
  const HrReconcileApplyResult({
    required this.planVersion,
    required this.round,
    required this.counts,
    required this.rows,
    required this.summary,
  });

  final int planVersion;
  final int round;
  final HrReconcileApplyCounts counts;
  final List<HrReconcileApplyRowResult> rows;
  final String summary;

  factory HrReconcileApplyResult.fromJson(Map<String, dynamic> json) =>
      HrReconcileApplyResult(
        planVersion: _int(json, 'planVersion'),
        round: _int(json, 'round'),
        counts: HrReconcileApplyCounts.fromJson(
          _objectOrNull(json, 'counts') ?? const {},
        ),
        rows: [
          for (final row in _objects(json, 'rows'))
            HrReconcileApplyRowResult.fromJson(row),
        ],
        summary: _string(json, 'summary'),
      );
}

class HrReconcileApplyCounts {
  const HrReconcileApplyCounts({
    required this.applied,
    required this.skipped,
    required this.failed,
  });

  final int applied;
  final int skipped;
  final int failed;

  factory HrReconcileApplyCounts.fromJson(Map<String, dynamic> json) =>
      HrReconcileApplyCounts(
        applied: _int(json, 'applied'),
        skipped: _int(json, 'skipped'),
        failed: _int(json, 'failed'),
      );
}

class HrReconcileApplyRowResult {
  const HrReconcileApplyRowResult({
    required this.rowNo,
    required this.result,
    required this.items,
  });

  final int rowNo;
  final HrReconcileRowResultStatus result;
  final List<HrReconcileApplyItemResult> items;

  factory HrReconcileApplyRowResult.fromJson(Map<String, dynamic> json) =>
      HrReconcileApplyRowResult(
        rowNo: _int(json, 'rowNo'),
        result: HrReconcileRowResultStatus.fromApi(json['result']),
        items: [
          for (final item in _objects(json, 'items'))
            HrReconcileApplyItemResult.fromJson(item),
        ],
      );
}

class HrReconcileApplyItemResult {
  const HrReconcileApplyItemResult({
    required this.itemNo,
    required this.status,
    this.message,
  });

  final int itemNo;
  final HrReconcileOutcomeStatus status;
  final String? message;

  factory HrReconcileApplyItemResult.fromJson(Map<String, dynamic> json) =>
      HrReconcileApplyItemResult(
        itemNo: _int(json, 'itemNo'),
        status: HrReconcileOutcomeStatus.fromApi(json['status']),
        message: _stringOrNull(json, 'message'),
      );
}

/// 核对记录列表项（PlanSummary）。
class HrReconcilePlanSummary {
  const HrReconcilePlanSummary({
    required this.id,
    required this.createdAt,
    required this.actorName,
    required this.status,
    this.closedReason,
    required this.counts,
  });

  final String id;
  final String? createdAt;
  final String actorName;
  final HrReconcilePlanStatus status;
  final HrReconcileClosedReason? closedReason;
  final HrReconcilePlanCounts counts;

  factory HrReconcilePlanSummary.fromJson(Map<String, dynamic> json) =>
      HrReconcilePlanSummary(
        id: _string(json, 'id'),
        createdAt: _stringOrNull(json, 'createdAt'),
        actorName: _string(json, 'actorName'),
        status: HrReconcilePlanStatus.fromApi(json['status']),
        closedReason: _enumOrNull(
          json,
          'closedReason',
          HrReconcileClosedReason.fromApi,
        ),
        counts: HrReconcilePlanCounts.fromJson(
          _objectOrNull(json, 'counts') ?? const {},
        ),
      );
}

/// 记录分页（GET /plans 的 items/page/size/total/totalPages）。
class HrReconcilePlanSummaryPage {
  const HrReconcilePlanSummaryPage({
    required this.items,
    required this.page,
    required this.size,
    required this.total,
    required this.totalPages,
  });

  final List<HrReconcilePlanSummary> items;
  final int page;
  final int size;
  final int total;
  final int totalPages;

  factory HrReconcilePlanSummaryPage.fromJson(Map<String, dynamic> json) =>
      HrReconcilePlanSummaryPage(
        items: [
          for (final item in _objects(json, 'items'))
            HrReconcilePlanSummary.fromJson(item),
        ],
        page: _int(json, 'page'),
        size: _int(json, 'size'),
        total: _int(json, 'total'),
        totalPages: _int(json, 'totalPages'),
      );
}
