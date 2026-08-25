enum DataHandoverAction {
  transfer,
  historyAccess,
  release,
  blocking;

  static DataHandoverAction fromJson(Object? value) => switch (value) {
    'TRANSFER' => DataHandoverAction.transfer,
    'HISTORY_ACCESS' => DataHandoverAction.historyAccess,
    'RELEASE' => DataHandoverAction.release,
    'BLOCKING' => DataHandoverAction.blocking,
    // 未知动作 fail closed，不能把新后端动作误当成可安全执行。
    _ => DataHandoverAction.blocking,
  };

  String get label => switch (this) {
    DataHandoverAction.transfer => '转移当前责任',
    DataHandoverAction.historyAccess => '保留历史并授予查阅',
    DataHandoverAction.release => '释放个人占用',
    DataHandoverAction.blocking => '必须先处理',
  };
}

enum DataHandoverCandidateRole {
  source,
  target;

  String get apiValue => name;
}

class DataHandoverCandidate {
  const DataHandoverCandidate({
    required this.employeeId,
    required this.name,
    required this.code,
    required this.status,
    this.departmentId,
    this.departmentName,
  });

  final String employeeId;
  final String name;
  final String code;
  final String status;
  final String? departmentId;
  final String? departmentName;

  factory DataHandoverCandidate.fromJson(Map<String, dynamic> json) =>
      DataHandoverCandidate(
        employeeId: json['employeeId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        code: json['code'] as String? ?? '',
        status: json['status'] as String? ?? '',
        departmentId: json['departmentId'] as String?,
        departmentName: json['departmentName'] as String?,
      );
}

class DataHandoverPreviewItem {
  const DataHandoverPreviewItem({
    required this.key,
    required this.label,
    required this.scope,
    required this.count,
    required this.action,
  });

  final String key;
  final String label;
  final String scope;
  final int count;
  final DataHandoverAction action;

  bool get isBlocking => action == DataHandoverAction.blocking && count > 0;

  factory DataHandoverPreviewItem.fromJson(Map<String, dynamic> json) =>
      DataHandoverPreviewItem(
        key: json['key'] as String? ?? '',
        label: json['label'] as String? ?? '',
        scope: json['scope'] as String? ?? 'other',
        count: (json['count'] as num?)?.toInt() ?? 0,
        action: DataHandoverAction.fromJson(json['action']),
      );
}

class DataHandoverPreview {
  const DataHandoverPreview({
    required this.sourceEmployeeId,
    required this.scopes,
    required this.items,
    required this.hasBlockers,
    required this.requiresTarget,
    required this.total,
    this.targetEmployeeId,
    this.transferCount = -1,
    this.historyAccessCount = -1,
    this.releaseCount = -1,
    this.blockingCount = -1,
    this.scopeTargetEmployeeIds = const {},
    this.scopeTargetEmployeeNames = const {},
  });

  final String sourceEmployeeId;
  final String? targetEmployeeId;
  final Set<String> scopes;
  final List<DataHandoverPreviewItem> items;
  final bool hasBlockers;
  final bool requiresTarget;
  final int total;
  final int transferCount;
  final int historyAccessCount;
  final int releaseCount;
  final int blockingCount;

  /// 已有分模块交接形成的实际接手人；最终默认接手人只承接尚未交接的范围。
  final Map<String, String> scopeTargetEmployeeIds;
  final Map<String, String> scopeTargetEmployeeNames;

  bool get hasData => total > 0;
  List<DataHandoverPreviewItem> get blockers =>
      items.where((item) => item.isBlocking).toList(growable: false);

  /// 后端 [total] 是各预览分类的项次合计，不是去重后的业务记录数。
  ///
  /// `target.required` 只是“尚未选择接手人”的合成提示，不属于影响项次，
  /// 因而与后端 total 的口径一致地排除。
  int actionCount(DataHandoverAction action) {
    final authoritative = switch (action) {
      DataHandoverAction.transfer => transferCount,
      DataHandoverAction.historyAccess => historyAccessCount,
      DataHandoverAction.release => releaseCount,
      DataHandoverAction.blocking => blockingCount,
    };
    if (authoritative >= 0) return authoritative;
    return items
        .where((item) => item.key != 'target.required' && item.action == action)
        .fold(0, (sum, item) => sum + item.count);
  }

  factory DataHandoverPreview.fromJson(Map<String, dynamic> json) =>
      DataHandoverPreview(
        sourceEmployeeId: json['sourceEmployeeId'] as String? ?? '',
        targetEmployeeId: json['targetEmployeeId'] as String?,
        scopes: (json['scopes'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toSet(),
        scopeTargetEmployeeIds: {
          for (final entry
              in (json['scopeTargetEmployeeIds'] as Map<String, dynamic>? ??
                      const <String, dynamic>{})
                  .entries)
            if (entry.value is String && (entry.value as String).isNotEmpty)
              entry.key: entry.value as String,
        },
        scopeTargetEmployeeNames: {
          for (final entry
              in (json['scopeTargetEmployeeNames'] as Map<String, dynamic>? ??
                      const <String, dynamic>{})
                  .entries)
            if (entry.value is String && (entry.value as String).isNotEmpty)
              entry.key: entry.value as String,
        },
        transferCount: (json['transferCount'] as num?)?.toInt() ?? -1,
        historyAccessCount: (json['historyAccessCount'] as num?)?.toInt() ?? -1,
        releaseCount: (json['releaseCount'] as num?)?.toInt() ?? -1,
        blockingCount: (json['blockingCount'] as num?)?.toInt() ?? -1,
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DataHandoverPreviewItem.fromJson)
            .where((item) => item.count > 0)
            .toList(growable: false),
        hasBlockers: json['hasBlockers'] as bool? ?? true,
        requiresTarget: json['requiresTarget'] as bool? ?? true,
        total: (json['total'] as num?)?.toInt() ?? 0,
      );
}

class DataHandoverRequest {
  const DataHandoverRequest({
    required this.requestId,
    required this.sourceEmployeeId,
    required this.targetEmployeeId,
    required this.scopes,
    required this.reason,
    required this.effectiveDate,
  });

  final String requestId;
  final String sourceEmployeeId;
  final String targetEmployeeId;
  final Set<String> scopes;
  final String reason;
  final String effectiveDate;

  Map<String, dynamic> toJson() => {
    'requestId': requestId,
    'sourceEmployeeId': sourceEmployeeId,
    'targetEmployeeId': targetEmployeeId,
    'scopes': scopes.toList()..sort(),
    'reason': reason.trim(),
    'effectiveDate': effectiveDate,
  };
}

class DataHandoverResult {
  const DataHandoverResult({
    required this.id,
    required this.sequenceNo,
    required this.requestId,
    required this.sourceEmployeeId,
    required this.targetEmployeeId,
    required this.mode,
    required this.status,
    required this.scopes,
    required this.resultSummary,
    required this.replayed,
  });

  final String id;
  final int sequenceNo;
  final String requestId;
  final String sourceEmployeeId;
  final String targetEmployeeId;
  final String mode;
  final String status;
  final Set<String> scopes;
  final Map<String, int> resultSummary;
  final bool replayed;

  /// 服务端完成回执中的分类项次合计；兼容旧响应缺少 `total` 的情况。
  int get processedTotal =>
      resultSummary['total'] ??
      resultSummary.entries
          .where((entry) => entry.key != 'total')
          .fold(0, (sum, entry) => sum + entry.value);

  factory DataHandoverResult.fromJson(Map<String, dynamic> json) =>
      DataHandoverResult(
        id: json['id'] as String? ?? '',
        sequenceNo: (json['sequenceNo'] as num?)?.toInt() ?? 0,
        requestId: json['requestId'] as String? ?? '',
        sourceEmployeeId: json['sourceEmployeeId'] as String? ?? '',
        targetEmployeeId: json['targetEmployeeId'] as String? ?? '',
        mode: json['mode'] as String? ?? '',
        status: json['status'] as String? ?? '',
        scopes: (json['scopes'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toSet(),
        resultSummary:
            (json['resultSummary'] as Map<String, dynamic>? ?? const {}).map(
              (key, value) => MapEntry(key, (value as num?)?.toInt() ?? 0),
            ),
        replayed: json['replayed'] as bool? ?? false,
      );
}

const dataHandoverScopeLabels = <String, String>{
  'goods': '货品资料',
  'client': '客户资料',
  'sales': '销售单据',
  'finance': '财务单据',
  'purchase': '采购单据',
  'subcontract': '委外单据',
  'production_plan': '生产计划与日报',
  'stock_doc': '仓库单据',
  'workflow': '任务认领',
  'all': '全局检查',
  'organization': '组织关系',
};

String dataHandoverScopeLabel(String scope) =>
    dataHandoverScopeLabels[scope] ?? scope;

bool isSelectableDataHandoverScope(String scope) =>
    dataHandoverScopeLabels.containsKey(scope) &&
    scope != 'all' &&
    scope != 'organization' &&
    scope != 'workflow';
