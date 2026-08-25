/// 客户负责人和单客户额外只读查看人契约。
///
/// 负责人代表当前业务责任；历史制单、审批和审计事实不在本契约内改写。
class ClientAccessSettings {
  const ClientAccessSettings({
    required this.clientId,
    required this.accessVersion,
    required this.viewers,
    this.ownerEmployeeId,
    this.ownerEmployeeName,
  });

  final String clientId;
  final String? ownerEmployeeId;
  final String? ownerEmployeeName;
  final int accessVersion;
  final List<ClientAccessViewer> viewers;

  factory ClientAccessSettings.fromJson(Map<String, dynamic> json) =>
      ClientAccessSettings(
        clientId: json['clientId'] as String? ?? '',
        ownerEmployeeId: json['ownerEmployeeId'] as String?,
        ownerEmployeeName: json['ownerEmployeeName'] as String?,
        accessVersion: (json['accessVersion'] as num?)?.toInt() ?? 0,
        viewers: (json['viewers'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(ClientAccessViewer.fromJson)
            .where((viewer) => viewer.employeeId.isNotEmpty)
            .toList(growable: false),
      );
}

class ClientAccessViewer {
  const ClientAccessViewer({
    required this.employeeId,
    required this.name,
    this.code,
    this.departmentName,
  });

  final String employeeId;
  final String name;
  final String? code;
  final String? departmentName;

  factory ClientAccessViewer.fromJson(Map<String, dynamic> json) =>
      ClientAccessViewer(
        employeeId: json['employeeId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        code: json['code'] as String?,
        departmentName: json['departmentName'] as String?,
      );
}

class ClientAccessCandidate {
  const ClientAccessCandidate({
    required this.employeeId,
    required this.name,
    required this.code,
    required this.status,
    required this.activeAccount,
    this.departmentName,
  });

  final String employeeId;
  final String name;
  final String code;
  final String status;
  final bool activeAccount;
  final String? departmentName;

  factory ClientAccessCandidate.fromJson(Map<String, dynamic> json) =>
      ClientAccessCandidate(
        employeeId: json['employeeId'] as String? ?? '',
        name: json['name'] as String? ?? '',
        code: json['code'] as String? ?? '',
        status: json['status'] as String? ?? '',
        activeAccount: json['activeAccount'] as bool? ?? false,
        departmentName: json['departmentName'] as String?,
      );
}

class ClientAccessUpdate {
  const ClientAccessUpdate({
    required this.ownerEmployeeId,
    required this.viewerEmployeeIds,
    required this.expectedAccessVersion,
    required this.reason,
  });

  final String ownerEmployeeId;
  final List<String> viewerEmployeeIds;
  final int expectedAccessVersion;
  final String reason;

  Map<String, dynamic> toJson() => {
    'ownerEmployeeId': ownerEmployeeId,
    'viewerEmployeeIds': viewerEmployeeIds,
    'expectedAccessVersion': expectedAccessVersion,
    'reason': reason.trim(),
  };
}
