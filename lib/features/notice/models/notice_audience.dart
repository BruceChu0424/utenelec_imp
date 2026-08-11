/// 通知发布接收范围。
enum NoticeAudienceScope {
  all,
  selected;

  static NoticeAudienceScope fromName(String? value) => switch (value) {
    'selected' => NoticeAudienceScope.selected,
    _ => NoticeAudienceScope.all,
  };
}

/// 服务端按当前组织与账号状态解析后的接收范围预览。
class NoticeAudiencePreview {
  const NoticeAudiencePreview({
    required this.summary,
    required this.recipientCount,
  });

  final String summary;
  final int recipientCount;

  factory NoticeAudiencePreview.fromJson(Map<String, dynamic> json) {
    return NoticeAudiencePreview(
      summary: json['summary'] as String? ?? '',
      recipientCount: (json['recipientCount'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 通知发布人员选择器候选，仅包含非敏感组织目录字段。
class NoticeAudienceEmployee {
  const NoticeAudienceEmployee({
    required this.id,
    required this.name,
    required this.code,
    this.departmentName,
  });

  /// employees.id；发布请求由服务端再映射为 users.id。
  final String id;
  final String name;
  final String code;
  final String? departmentName;

  factory NoticeAudienceEmployee.fromJson(Map<String, dynamic> json) {
    return NoticeAudienceEmployee(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      code: json['code'] as String? ?? '',
      departmentName: json['departmentName'] as String?,
    );
  }
}
