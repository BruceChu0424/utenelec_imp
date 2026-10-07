// AI 用量看板与按人限额(ADR-164)的客户端模型: 与服务端 /api/admin/ai/usage-* 一一对应。
//
// 读端点(usage-dashboard / usage-people)只要求超管+authorization:manage;
// 写限额(usage-people/{id}/limits)另要求再认证, 由网络层弹统一密码框。
library;

/// 统计窗口: 时(近24时)/日(近30天)/月(近12月)/年(近5年); wire 上是小写串。
enum AiUsageWindow {
  hour('hour'),
  day('day'),
  month('month'),
  year('year');

  const AiUsageWindow(this.wire);

  final String wire;

  static AiUsageWindow parse(Object? raw) => values.firstWhere(
    (value) => value.wire == '${raw ?? ''}'.trim().toLowerCase(),
    orElse: () => AiUsageWindow.day,
  );
}

/// 按人限额与停用(空限额=跟随全局默认; disabled 由管理员设置)。
class AiUserLimits {
  const AiUserLimits({
    required this.userId,
    required this.disabled,
    required this.dailyTokenLimit,
    required this.dailyJobLimit,
    required this.rowVersion,
  });

  factory AiUserLimits.fromJson(Map<String, dynamic> json) => AiUserLimits(
    userId: _text(json['userId']),
    disabled: json['disabled'] == true,
    dailyTokenLimit: _optionalInt(json['dailyTokenLimit']),
    dailyJobLimit: _optionalInt(json['dailyJobLimit']),
    rowVersion: _int(json['rowVersion']),
  );

  /// 无行=默认: 不停用、无限额; 首次保存时服务端按 rowVersion<0 首建。
  const AiUserLimits.defaults(String userId)
    : this(
        userId: userId,
        disabled: false,
        dailyTokenLimit: null,
        dailyJobLimit: null,
        rowVersion: -1,
      );

  final String userId;
  final bool disabled;
  final int? dailyTokenLimit;
  final int? dailyJobLimit;

  /// 乐观锁版本; -1 表示还没有配置行(首建)。
  final int rowVersion;

  Map<String, dynamic> toSaveJson({
    required bool disabled,
    int? dailyTokenLimit,
    int? dailyJobLimit,
  }) => {
    'disabled': disabled,
    'dailyTokenLimit': dailyTokenLimit,
    'dailyJobLimit': dailyJobLimit,
    'rowVersion': rowVersion,
  };
}

/// 趋势柱上的一个桶(bucket=起止定位, label=桶底短标签, 均由服务端给出)。
class AiUsageSeriesPoint {
  const AiUsageSeriesPoint({
    required this.bucket,
    required this.label,
    required this.tokens,
    required this.calls,
    required this.okCalls,
  });

  factory AiUsageSeriesPoint.fromJson(Map<String, dynamic> json) =>
      AiUsageSeriesPoint(
        bucket: _text(json['bucket']),
        label: _text(json['label'], fallback: _text(json['bucket'])),
        tokens: _int(json['tokens']),
        calls: _int(json['calls']),
        okCalls: _int(json['okCalls']),
      );

  final String bucket;
  final String label;
  final int tokens;
  final int calls;
  final int okCalls;
}

/// 人员行(窗口内有用量的用户 ∪ 有 limits 行的用户, 上限 500)。
class AiUsagePerson {
  const AiUsagePerson({
    required this.userId,
    required this.name,
    required this.code,
    required this.department,
    required this.deleted,
    required this.disabled,
    required this.dailyTokenLimit,
    required this.dailyJobLimit,
    required this.rowVersion,
    required this.todayTokens,
    required this.windowTokens,
    required this.windowCalls,
    required this.lastUsedAt,
  });

  factory AiUsagePerson.fromJson(Map<String, dynamic> json) => AiUsagePerson(
    userId: _text(json['userId']),
    name: _text(json['name']),
    code: _text(json['code']),
    department: _text(json['department']),
    deleted: json['deleted'] == true,
    disabled: json['disabled'] == true,
    dailyTokenLimit: _optionalInt(json['dailyTokenLimit']),
    dailyJobLimit: _optionalInt(json['dailyJobLimit']),
    // 服务端下发 COALESCE(row_version, -1): ≥0=已有配置行, -1=还没有配置行(首建);
    // 旧 wire 没带时为 null, 编辑面板先取人员详情补齐。
    rowVersion: _optionalInt(json['rowVersion']),
    todayTokens: _int(json['todayTokens']),
    windowTokens: _int(json['windowTokens']),
    windowCalls: _int(json['windowCalls']),
    lastUsedAt: json['lastUsedAt']?.toString(),
  );

  final String userId;

  /// 展示名 coalesce(full_name, login_account); 用户删除后回退「已删除员工」。
  final String name;
  final String code;
  final String department;

  /// users 行已删(统计行保留): 行点击与「设置限额」都禁用。
  final bool deleted;
  final bool disabled;
  final int? dailyTokenLimit;
  final int? dailyJobLimit;
  final int? rowVersion;
  final int todayTokens;
  final int windowTokens;
  final int windowCalls;

  /// 该用户 call_logs 最大 created_at; null=窗口内没用过。
  final String? lastUsedAt;

  /// 今日消耗是否已达到个人 token 限额(无限额=未超)。
  bool get overLimit =>
      dailyTokenLimit != null &&
      dailyTokenLimit! > 0 &&
      todayTokens >= dailyTokenLimit!;
}

/// 看板总览(GET /admin/ai/usage-dashboard?window=)。
class AiUsageDashboard {
  const AiUsageDashboard({
    required this.window,
    required this.todayTokens,
    required this.dailyTokenBudget,
    required this.todayCalls,
    required this.activeUsersToday,
    required this.disabledCount,
    required this.series,
    required this.people,
  });

  factory AiUsageDashboard.fromJson(Map<String, dynamic> json) =>
      AiUsageDashboard(
        window: AiUsageWindow.parse(json['window']),
        todayTokens: _int(json['todayTokens']),
        dailyTokenBudget: _int(json['dailyTokenBudget']),
        todayCalls: _int(json['todayCalls']),
        activeUsersToday: _int(json['activeUsersToday']),
        disabledCount: _int(json['disabledCount']),
        series: [
          for (final row in _rows(json['series']))
            AiUsageSeriesPoint.fromJson(row),
        ],
        people: [
          for (final row in _rows(json['people'])) AiUsagePerson.fromJson(row),
        ],
      );

  final AiUsageWindow window;
  final int todayTokens;
  final int dailyTokenBudget;
  final int todayCalls;
  final int activeUsersToday;
  final int disabledCount;
  final List<AiUsageSeriesPoint> series;
  final List<AiUsagePerson> people;
}

/// 按用途/按服务商的一行分布。
class AiUsageDistribution {
  const AiUsageDistribution({
    required this.label,
    required this.calls,
    required this.tokens,
  });

  factory AiUsageDistribution.fromJson(Map<String, dynamic> json) =>
      AiUsageDistribution(
        // 按服务商的行键叫 name, 按用途的叫 label; 都收。
        label: _text(json['label'], fallback: _text(json['name'])),
        calls: _int(json['calls']),
        tokens: _int(json['tokens']),
      );

  final String label;
  final int calls;
  final int tokens;
}

/// 最近使用一条(近 20 条, 照 usage-audit 的 Use 投影精简)。
class AiUsageRecentUse {
  const AiUsageRecentUse({
    required this.jobId,
    required this.kind,
    required this.question,
    required this.createdAt,
    required this.status,
    required this.tokens,
  });

  factory AiUsageRecentUse.fromJson(Map<String, dynamic> json) =>
      AiUsageRecentUse(
        jobId: _text(json['jobId']),
        kind: _text(json['kind']),
        question: _text(json['question']),
        createdAt: _text(json['createdAt']),
        status: _text(json['status']),
        tokens: _int(json['tokens']),
      );

  final String jobId;
  final String kind;
  final String question;
  final String createdAt;
  final String status;
  final int tokens;
}

/// 人员详情(GET /admin/ai/usage-people/{userId}?window=)。
class AiUsagePersonDetail {
  const AiUsagePersonDetail({
    required this.userId,
    required this.name,
    required this.code,
    required this.department,
    required this.todayTokens,
    required this.todayCalls,
    required this.dailyTokenBudget,
    required this.limits,
    required this.series,
    required this.byPurpose,
    required this.byProvider,
    required this.recentUses,
  });

  factory AiUsagePersonDetail.fromJson(Map<String, dynamic> json) {
    // 与服务端 wire 一致: 用户信息与今日三值都平铺在根级(今日值照看板 KPI 同口径,
    // 由 call_logs 上海日实时聚合 + properties 的全站预算)。
    final limits = AiUserLimits.fromJson(
      json['limits'] is Map
          ? _rows([json['limits']]).first
          : <String, dynamic>{'userId': _text(json['userId'])},
    );
    return AiUsagePersonDetail(
      userId: _text(json['userId']),
      name: _text(json['name']),
      code: _text(json['code']),
      department: _text(json['department']),
      todayTokens: _int(json['todayTokens']),
      todayCalls: _int(json['todayCalls']),
      dailyTokenBudget: _int(json['dailyTokenBudget']),
      limits: limits,
      series: [
        for (final row in _rows(json['series']))
          AiUsageSeriesPoint.fromJson(row),
      ],
      byPurpose: [
        for (final row in _rows(json['byPurpose']))
          AiUsageDistribution.fromJson(row),
      ],
      byProvider: [
        for (final row in _rows(json['byProvider']))
          AiUsageDistribution.fromJson(row),
      ],
      recentUses: [
        for (final row in _rows(json['recentUses']))
          AiUsageRecentUse.fromJson(row),
      ],
    );
  }

  final String userId;
  final String name;
  final String code;
  final String department;
  final int todayTokens;
  final int todayCalls;
  final int dailyTokenBudget;
  final AiUserLimits limits;
  final List<AiUsageSeriesPoint> series;
  final List<AiUsageDistribution> byPurpose;
  final List<AiUsageDistribution> byProvider;
  final List<AiUsageRecentUse> recentUses;

  /// 环形表的满环值: 个人限额优先, 没设时用全站预算(都没有则 null=未知)。
  int? get gaugeMax {
    final personal = limits.dailyTokenLimit;
    if (personal != null && personal > 0) return personal;
    if (dailyTokenBudget > 0) return dailyTokenBudget;
    return null;
  }
}

List<Map<String, dynamic>> _rows(Object? value) => value is List
    ? value
          .whereType<Map<dynamic, dynamic>>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList()
    : [];

String _text(Object? value, {String fallback = ''}) =>
    value == null || value.toString().isEmpty ? fallback : value.toString();

int _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse(_text(value)) ?? 0;

int? _optionalInt(Object? value) => value == null
    ? null
    : (value is num ? value.toInt() : int.tryParse(value.toString()));
