/// Server-authoritative finance approval projection attached to procurement
/// and subcontract order DTOs.
class ProcurementFinanceApproval {
  const ProcurementFinanceApproval({
    required this.status,
    required this.attempt,
    required this.version,
    required this.allowedActions,
    this.caseId,
    this.assigneeUserId,
    this.assigneeEmployeeId,
    this.assigneeName,
    this.rejectionReason,
    this.submittedAt,
  });

  final String? caseId;
  final String status;
  final int attempt;
  final int version;
  final String? assigneeUserId;
  final String? assigneeEmployeeId;
  final String? assigneeName;
  final String? rejectionReason;
  final String? submittedAt;
  final Set<String> allowedActions;

  bool get isPending => status == 'PENDING';
  bool get isRejected => status == 'REJECTED';
  bool get isApproved => status == 'APPROVED';
  bool get canSubmit => allowedActions.contains('SUBMIT_FINANCE');

  factory ProcurementFinanceApproval.fromJson(Map<String, dynamic> json) {
    int number(String key) {
      final value = json[key];
      if (value is num) return value.toInt();
      return int.tryParse(value?.toString() ?? '') ?? 0;
    }

    return ProcurementFinanceApproval(
      caseId: json['caseId'] as String?,
      status: (json['status'] as String? ?? 'DRAFT').toUpperCase(),
      attempt: number('attempt'),
      version: number('version'),
      assigneeUserId: json['assigneeUserId'] as String?,
      assigneeEmployeeId: json['assigneeEmployeeId'] as String?,
      assigneeName: json['assigneeName'] as String?,
      rejectionReason: json['rejectionReason'] as String?,
      submittedAt: json['submittedAt'] as String?,
      allowedActions: (json['allowedActions'] as List? ?? const [])
          .map((value) => value.toString().toUpperCase())
          .toSet(),
    );
  }
}
