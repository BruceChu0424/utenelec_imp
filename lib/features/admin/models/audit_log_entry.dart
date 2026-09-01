import '../../../shared/models/paged_result.dart';

// 审计日志列表项（GET /admin/audit-logs 的 items[]）。
//
// 对应后端 com.uten.imp.audit.AuditLogRow（只读 DTO，不含 before/after/user_agent）。
// 字段全部可空（DB 触发器行的 actor_account 可能缺；登录失败行 actor_id 为 null）。
// id 是 bigserial，JSON 序列化为 int；兼容 String 输入。
class AuditLogEntry {
  const AuditLogEntry({
    required this.id,
    this.actorId,
    this.actorAccount,
    this.actorName,
    this.actorDepartment,
    this.actorPosition,
    this.actorDisplay,
    required this.action,
    this.targetType,
    this.targetId,
    this.targetName,
    this.targetDisplayName,
    this.targetBusinessCode,
    this.targetLegacyCode,
    this.pageLabel,
    this.ip,
    this.result,
    this.resultLabel,
    this.actionLabel,
    this.objectLabel,
    this.summary,
    this.changeSummary,
    this.riskLevel = 'low',
    this.riskReason,
    this.eventCategory = 'business',
    this.eventSource = 'business',
    this.requestId,
    this.clientEventId,
    this.deviceInstallationId,
    this.deviceLabel,
    this.devicePlatform,
    this.statusCode,
    this.durationMs,
    this.createdAt,
  });

  final int id;
  final String? actorId;
  final String? actorAccount;

  /// 操作人姓名（后端解析自员工档案；访客/系统任务为 null）
  final String? actorName;

  /// 操作人部门名
  final String? actorDepartment;

  /// 操作人职位/岗位名
  final String? actorPosition;

  /// 后端拼好的"姓名（账号）"，展示优先使用
  final String? actorDisplay;

  /// 'export_purchase_report' / 'login' / 'login_failed' / 'change_password' /
  /// 'logout' / 触发器写入的 'insert'/'update'/'delete' 等
  final String action;
  final String? targetType;
  final String? targetId;

  /// 从快照提取的对象可读名（单据号/名称/编码），取不到为 null
  final String? targetName;

  /// 结构化的业务对象名称或单据标签，不包含 UUID。
  final String? targetDisplayName;

  /// 结构化业务编号、单号或主档编码。
  final String? targetBusinessCode;

  /// 历史单据的旧系统编号；新单据为空。
  final String? targetLegacyCode;

  /// 请求路径翻译成的页面名（"哪个页面操作的"）
  final String? pageLabel;
  final String? ip;

  /// 'success' / 'failure' / 'account_not_found' / 'bad_password' / 'reuse_detected' ...
  final String? result;

  /// 后端翻译好的结果中文（如 成功 / 密码错误 / 尝试过于频繁（已限流））
  final String? resultLabel;
  final String? actionLabel;
  final String? objectLabel;
  final String? summary;

  /// 活动关联行的脱敏中文字段变化摘要；列表按需展示，不包含 before/after 原始快照。
  final String? changeSummary;
  final String riskLevel;
  final String? riskReason;
  final String eventCategory;
  final String eventSource;
  final String? requestId;
  final String? clientEventId;
  final String? deviceInstallationId;
  final String? deviceLabel;
  final String? devicePlatform;
  final int? statusCode;
  final int? durationMs;

  /// ISO 8601 字符串（如 '2026-07-27T12:34:56.789+08:00'）
  final String? createdAt;

  factory AuditLogEntry.fromJson(Map<String, dynamic> json) => AuditLogEntry(
    id: _parseInt(json['id']) ?? 0,
    actorId: json['actorId'] as String?,
    actorAccount: json['actorAccount'] as String?,
    actorName: json['actorName'] as String?,
    actorDepartment: json['actorDepartment'] as String?,
    actorPosition: json['actorPosition'] as String?,
    actorDisplay: json['actorDisplay'] as String?,
    action: json['action'] as String? ?? '',
    targetType: json['targetType'] as String?,
    targetId: json['targetId'] as String?,
    targetName: json['targetName'] as String?,
    targetDisplayName: json['targetDisplayName'] as String?,
    targetBusinessCode: json['targetBusinessCode'] as String?,
    targetLegacyCode: json['targetLegacyCode'] as String?,
    pageLabel: json['pageLabel'] as String?,
    ip: json['ip'] as String?,
    result: json['result'] as String?,
    resultLabel: json['resultLabel'] as String?,
    actionLabel: json['actionLabel'] as String?,
    objectLabel: json['objectLabel'] as String?,
    summary: json['summary'] as String?,
    changeSummary: json['changeSummary'] as String?,
    riskLevel: json['riskLevel'] as String? ?? 'low',
    riskReason: json['riskReason'] as String?,
    eventCategory: json['eventCategory'] as String? ?? 'business',
    eventSource: json['eventSource'] as String? ?? 'business',
    requestId: json['requestId'] as String?,
    clientEventId: json['clientEventId'] as String?,
    deviceInstallationId: json['deviceInstallationId'] as String?,
    deviceLabel: json['deviceLabel'] as String?,
    devicePlatform: json['devicePlatform'] as String?,
    statusCode: _parseInt(json['statusCode']),
    durationMs: _parseInt(json['durationMs']),
    createdAt: json['createdAt'] as String?,
  );

  static int? _parseInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

/// A high-water-bounded page of audit rows.
///
/// [snapshotId] is the upper audit-log id captured by the server for this
/// result set. Reusing it for summary, paging, and export excludes events that
/// are normally allocated a higher id; it is not a cross-request MVCC snapshot
/// and does not freeze late commits with an older id or retention deletions.
class AuditLogPage extends PagedResult<AuditLogEntry> {
  const AuditLogPage({
    required super.items,
    required super.page,
    required super.size,
    required super.total,
    required super.totalPages,
    required this.snapshotId,
  });

  final int snapshotId;

  factory AuditLogPage.fromJson(Map<String, dynamic> json) {
    final page = PagedResult.fromJson(json, AuditLogEntry.fromJson);
    return AuditLogPage(
      items: page.items,
      page: page.page,
      size: page.size,
      total: page.total,
      totalPages: page.totalPages,
      snapshotId: AuditLogEntry._parseInt(json['snapshotId']) ?? 0,
    );
  }
}

/// 可在审计中心选择的真实操作人员。
///
/// 候选来自全人员目录，可包含尚无日志的员工和真实访客；系统任务和迁移账号不会出现。
/// 查询时以不可变的 [actorId] 为准，账号、姓名和组织信息只用于展示。
class AuditActorOption {
  const AuditActorOption({
    required this.actorId,
    this.account,
    this.actorType,
    this.displayName,
    this.name,
    this.department,
    this.position,
    this.lastActivityAt,
  });

  final String actorId;
  final String? account;
  final String? actorType;
  final String? displayName;
  final String? name;
  final String? department;
  final String? position;
  final String? lastActivityAt;

  String get primaryLabel {
    final display = displayName?.trim();
    if (display?.isNotEmpty == true) return display!;
    final actorName = name?.trim();
    if (actorName?.isNotEmpty == true) return actorName!;
    final actorAccount = account?.trim();
    if (actorAccount?.isNotEmpty == true) return actorAccount!;
    return '未知人员';
  }

  factory AuditActorOption.fromJson(Map<String, dynamic> json) =>
      AuditActorOption(
        actorId: json['actorId'] as String? ?? '',
        account: json['account'] as String?,
        actorType: json['actorType'] as String?,
        displayName: json['displayName'] as String?,
        name: json['name'] as String?,
        department: json['department'] as String?,
        position: json['position'] as String?,
        lastActivityAt: json['lastActivityAt'] as String?,
      );
}

class AuditActorPage extends PagedResult<AuditActorOption> {
  const AuditActorPage({
    required super.items,
    required super.page,
    required super.size,
    required super.total,
    required super.totalPages,
  });

  factory AuditActorPage.fromJson(Map<String, dynamic> json) {
    final page = PagedResult.fromJson(json, AuditActorOption.fromJson);
    return AuditActorPage(
      items: page.items.where((actor) => actor.actorId.isNotEmpty).toList(),
      page: page.page,
      size: page.size,
      total: page.total,
      totalPages: page.totalPages,
    );
  }
}

/// Super-admin-only full audit detail.
///
/// [beforeJson]/[afterJson] are the already-redacted JSON payloads persisted by
/// the database trigger. They are intentionally loaded only after a row is
/// opened so the normal audit list remains small.
class AuditLogDetail {
  const AuditLogDetail({
    required this.id,
    this.actorId,
    this.actorAccount,
    this.actorName,
    this.actorDepartment,
    this.actorPosition,
    this.actorDisplay,
    required this.action,
    this.targetType,
    this.targetId,
    this.targetName,
    this.targetDisplayName,
    this.targetBusinessCode,
    this.targetLegacyCode,
    this.pageLabel,
    this.beforeJson,
    this.afterJson,
    this.ip,
    this.userAgent,
    this.result,
    this.resultLabel,
    this.actionLabel,
    this.objectLabel,
    this.summary,
    this.changeSummary,
    this.riskLevel = 'low',
    this.riskReason,
    this.eventCategory = 'business',
    this.eventSource = 'business',
    this.requestId,
    this.clientEventId,
    this.device,
    this.httpMethod,
    this.httpPath,
    this.statusCode,
    this.durationMs,
    this.createdAt,
  });

  final int id;
  final String? actorId;
  final String? actorAccount;
  final String? actorName;
  final String? actorDepartment;
  final String? actorPosition;
  final String? actorDisplay;
  final String action;
  final String? targetType;
  final String? targetId;
  final String? targetName;
  final String? targetDisplayName;
  final String? targetBusinessCode;
  final String? targetLegacyCode;
  final String? pageLabel;
  final String? beforeJson;
  final String? afterJson;
  final String? ip;
  final String? userAgent;
  final String? result;

  /// 后端翻译好的结果中文（如 成功 / 密码错误 / 失败（HTTP 403））
  final String? resultLabel;
  final String? actionLabel;
  final String? objectLabel;
  final String? summary;

  /// 数据库变更行的逐字段中文变更说明（"状态：待审核 → 已审核；…"，分号分隔）
  final String? changeSummary;
  final String riskLevel;
  final String? riskReason;
  final String eventCategory;
  final String eventSource;
  final String? requestId;
  final String? clientEventId;
  final AuditDeviceEvidence? device;
  final String? httpMethod;
  final String? httpPath;
  final int? statusCode;
  final int? durationMs;
  final String? createdAt;

  factory AuditLogDetail.fromJson(Map<String, dynamic> json) => AuditLogDetail(
    id: AuditLogEntry._parseInt(json['id']) ?? 0,
    actorId: json['actorId'] as String?,
    actorAccount: json['actorAccount'] as String?,
    actorName: json['actorName'] as String?,
    actorDepartment: json['actorDepartment'] as String?,
    actorPosition: json['actorPosition'] as String?,
    actorDisplay: json['actorDisplay'] as String?,
    action: json['action'] as String? ?? '',
    targetType: json['targetType'] as String?,
    targetId: json['targetId'] as String?,
    targetName: json['targetName'] as String?,
    targetDisplayName: json['targetDisplayName'] as String?,
    targetBusinessCode: json['targetBusinessCode'] as String?,
    targetLegacyCode: json['targetLegacyCode'] as String?,
    pageLabel: json['pageLabel'] as String?,
    beforeJson: _jsonText(json['before']),
    afterJson: _jsonText(json['after']),
    ip: json['ip'] as String?,
    userAgent: json['userAgent'] as String?,
    result: json['result'] as String?,
    resultLabel: json['resultLabel'] as String?,
    actionLabel: json['actionLabel'] as String?,
    objectLabel: json['objectLabel'] as String?,
    summary: json['summary'] as String?,
    changeSummary: json['changeSummary'] as String?,
    riskLevel: json['riskLevel'] as String? ?? 'low',
    riskReason: json['riskReason'] as String?,
    eventCategory: json['eventCategory'] as String? ?? 'business',
    eventSource: json['eventSource'] as String? ?? 'business',
    requestId: json['requestId'] as String?,
    clientEventId: json['clientEventId'] as String?,
    device: json['device'] is Map
        ? AuditDeviceEvidence.fromJson(
            Map<String, dynamic>.from(json['device'] as Map),
          )
        : null,
    httpMethod: json['httpMethod'] as String?,
    httpPath: json['httpPath'] as String?,
    statusCode: AuditLogEntry._parseInt(json['statusCode']),
    durationMs: AuditLogEntry._parseInt(json['durationMs']),
    createdAt: json['createdAt'] as String?,
  );

  static String? _jsonText(dynamic value) {
    if (value == null) return null;
    return value is String ? value : value.toString();
  }
}

class AuditDeviceEvidence {
  const AuditDeviceEvidence({
    this.clientEventId,
    this.installationId,
    this.deviceName,
    this.manufacturer,
    this.model,
    this.platform,
    this.osVersion,
    this.appVersion,
    this.appBuild,
    this.formFactor,
    this.browserName,
    this.locale,
    this.timeZone,
    this.timeZoneOffsetMinutes,
    this.physicalDevice,
    this.clientEventAt,
    this.captureStatus = 'legacy',
    this.profileHash,
    this.clientDeclared = false,
  });

  final String? clientEventId;
  final String? installationId;
  final String? deviceName;
  final String? manufacturer;
  final String? model;
  final String? platform;
  final String? osVersion;
  final String? appVersion;
  final String? appBuild;
  final String? formFactor;
  final String? browserName;
  final String? locale;
  final String? timeZone;
  final int? timeZoneOffsetMinutes;
  final bool? physicalDevice;
  final String? clientEventAt;
  final String captureStatus;
  final String? profileHash;
  final bool clientDeclared;

  String get displayLabel {
    final name = deviceName?.trim();
    final deviceModel = model?.trim();
    if (name?.isNotEmpty == true &&
        deviceModel?.isNotEmpty == true &&
        name!.toLowerCase() != deviceModel!.toLowerCase()) {
      return '$name · $deviceModel';
    }
    if (name?.isNotEmpty == true) return name!;
    if (deviceModel?.isNotEmpty == true) return deviceModel!;
    return platform?.isNotEmpty == true ? platform! : '未提供设备信息';
  }

  factory AuditDeviceEvidence.fromJson(Map<String, dynamic> json) =>
      AuditDeviceEvidence(
        clientEventId: json['clientEventId'] as String?,
        installationId: json['installationId'] as String?,
        deviceName: json['deviceName'] as String?,
        manufacturer: json['manufacturer'] as String?,
        model: json['model'] as String?,
        platform: json['platform'] as String?,
        osVersion: json['osVersion'] as String?,
        appVersion: json['appVersion'] as String?,
        appBuild: json['appBuild'] as String?,
        formFactor: json['formFactor'] as String?,
        browserName: json['browserName'] as String?,
        locale: json['locale'] as String?,
        timeZone: json['timeZone'] as String?,
        timeZoneOffsetMinutes: AuditLogEntry._parseInt(
          json['timeZoneOffsetMinutes'],
        ),
        physicalDevice: json['physicalDevice'] as bool?,
        clientEventAt: json['clientEventAt'] as String?,
        captureStatus: json['captureStatus'] as String? ?? 'legacy',
        profileHash: json['profileHash'] as String?,
        clientDeclared: json['clientDeclared'] as bool? ?? false,
      );
}

class AuditSummary {
  const AuditSummary({
    required this.total,
    required this.riskCount,
    required this.criticalCount,
    required this.failedCount,
    required this.dataChangeCount,
    required this.dailyTrend,
  });

  final int total;
  final int riskCount;
  final int criticalCount;
  final int failedCount;
  final int dataChangeCount;
  final List<AuditDailyPoint> dailyTrend;

  factory AuditSummary.fromJson(Map<String, dynamic> json) => AuditSummary(
    total: AuditLogEntry._parseInt(json['total']) ?? 0,
    riskCount: AuditLogEntry._parseInt(json['riskCount']) ?? 0,
    criticalCount: AuditLogEntry._parseInt(json['criticalCount']) ?? 0,
    failedCount: AuditLogEntry._parseInt(json['failedCount']) ?? 0,
    dataChangeCount: AuditLogEntry._parseInt(json['dataChangeCount']) ?? 0,
    dailyTrend: (json['dailyTrend'] as List<dynamic>? ?? const [])
        .map(
          (item) =>
              AuditDailyPoint.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(growable: false),
  );
}

class AuditDailyPoint {
  const AuditDailyPoint({
    required this.date,
    required this.total,
    required this.riskCount,
  });

  final String date;
  final int total;
  final int riskCount;

  factory AuditDailyPoint.fromJson(Map<String, dynamic> json) =>
      AuditDailyPoint(
        date: json['date'] as String? ?? '',
        total: AuditLogEntry._parseInt(json['total']) ?? 0,
        riskCount: AuditLogEntry._parseInt(json['riskCount']) ?? 0,
      );
}
