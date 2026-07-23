// 访客来访申请模型（对应后端 VisitorApplication / VisitorListItem / VisitorDetail）。

/// 申请状态：pending 申请中 / hostReviewing 转被访人 / approved 已批准 /
/// rejected 已拒绝 / checkedIn 已签到 / cancelled 已取消。
enum VisitorApplicationStatus { pending, hostReviewing, approved, rejected, checkedIn, cancelled }

VisitorApplicationStatus visitorStatusFromCode(String? code) {
  switch (code) {
    case 'pending':
      return VisitorApplicationStatus.pending;
    case 'hostReviewing':
      return VisitorApplicationStatus.hostReviewing;
    case 'approved':
      return VisitorApplicationStatus.approved;
    case 'rejected':
      return VisitorApplicationStatus.rejected;
    case 'checkedIn':
      return VisitorApplicationStatus.checkedIn;
    case 'cancelled':
      return VisitorApplicationStatus.cancelled;
    default:
      return VisitorApplicationStatus.pending;
  }
}

class VisitorApplication {
  const VisitorApplication({
    required this.id,
    required this.visitorName,
    required this.visitPurpose,
    required this.status,
    required this.plannedVisitAt,
    required this.appliedAt,
    this.company,
    this.hostName,
    this.hostDepartment,
    this.plannedLeaveAt,
    this.approvedAt,
    this.hasVehicle = false,
    this.plateNo,
    this.rejectReason,
    this.qrToken,
    this.passcode,
  });

  final String id;
  final String visitorName;
  final String visitPurpose;
  final VisitorApplicationStatus status;
  final DateTime plannedVisitAt;
  final DateTime appliedAt;
  final String? company;
  final String? hostName;
  final String? hostDepartment;
  final DateTime? plannedLeaveAt;
  final DateTime? approvedAt;
  final bool hasVehicle;
  final String? plateNo;
  final String? rejectReason;
  final String? qrToken;
  final String? passcode;

  factory VisitorApplication.fromJson(Map<String, dynamic> j) {
    DateTime parse(Object? v) => v is String && v.isNotEmpty
        ? DateTime.tryParse(v) ?? DateTime.now()
        : DateTime.now();
    return VisitorApplication(
      id: (j['id'] ?? '').toString(),
      visitorName: (j['visitorName'] ?? '').toString(),
      visitPurpose: (j['visitPurpose'] ?? '').toString(),
      status: visitorStatusFromCode(j['status'] as String?),
      plannedVisitAt: parse(j['plannedVisitAt']),
      appliedAt: parse(j['appliedAt']),
      company: j['company'] as String?,
      hostName: j['hostName'] as String?,
      hostDepartment: j['hostDepartment'] as String?,
      plannedLeaveAt: j['plannedLeaveAt'] == null ? null : parse(j['plannedLeaveAt']),
      approvedAt: j['approvedAt'] == null ? null : parse(j['approvedAt']),
      hasVehicle: j['hasVehicle'] == true,
      plateNo: j['plateNo'] as String?,
      rejectReason: j['rejectReason'] as String?,
      qrToken: j['qrToken'] as String?,
      passcode: j['passcode'] as String?,
    );
  }
}

class VisitorApprovalStep {
  const VisitorApprovalStep({
    required this.action,
    required this.actorType,
    required this.actorName,
    required this.actedAt,
    this.comment,
  });

  final String action;
  final String actorType;
  final String actorName;
  final DateTime actedAt;
  final String? comment;

  factory VisitorApprovalStep.fromJson(Map<String, dynamic> j) => VisitorApprovalStep(
        action: (j['action'] ?? '').toString(),
        actorType: (j['actorType'] ?? '').toString(),
        actorName: (j['actorName'] ?? '').toString(),
        actedAt: j['actedAt'] is String && (j['actedAt'] as String).isNotEmpty
            ? DateTime.tryParse(j['actedAt'] as String) ?? DateTime.now()
            : DateTime.now(),
        comment: j['comment'] as String?,
      );
}
