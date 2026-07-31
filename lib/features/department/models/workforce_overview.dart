/// 公司/部门人员概况（所选节点及其全部下级组织）。
class WorkforceOverview {
  const WorkforceOverview({
    required this.organizationId,
    required this.organizationName,
    required this.organizationLevel,
    required this.asOf,
    required this.periodStart,
    required this.periodMonths,
    required this.directCurrentEmployees,
    required this.currentEmployees,
    required this.activeEmployees,
    required this.probationEmployees,
    required this.onLeaveEmployees,
    required this.hiredEmployees,
    required this.rehiredEmployees,
    required this.departedEmployees,
    required this.transferInEmployees,
    required this.transferOutEmployees,
    required this.openingHeadcount,
    required this.netChange,
    required this.descendantDepartmentCount,
    required this.contractOverdue,
    required this.contractExpiringIn30Days,
    required this.probationOverdue,
    required this.probationEndingIn30Days,
    required this.turnoverRateApproximate,
    required this.historyCoverageComplete,
    required this.missingHistoryRecords,
    required this.dataQualityNote,
    this.averageHeadcount,
    this.turnoverRatePct,
  });

  final String organizationId;
  final String organizationName;
  final String organizationLevel;
  final String asOf;
  final String periodStart;
  final int periodMonths;
  final int directCurrentEmployees;
  final int currentEmployees;
  final int activeEmployees;
  final int probationEmployees;
  final int onLeaveEmployees;
  final int hiredEmployees;
  final int rehiredEmployees;
  final int departedEmployees;
  final int transferInEmployees;
  final int transferOutEmployees;
  final int openingHeadcount;
  final double? averageHeadcount;
  final double? turnoverRatePct;
  final int netChange;
  final int descendantDepartmentCount;
  final int contractOverdue;
  final int contractExpiringIn30Days;
  final int probationOverdue;
  final int probationEndingIn30Days;
  final bool turnoverRateApproximate;
  final bool historyCoverageComplete;
  final int missingHistoryRecords;
  final String dataQualityNote;

  factory WorkforceOverview.fromJson(
    Map<String, dynamic> json,
  ) => WorkforceOverview(
    organizationId: json['organizationId'] as String,
    organizationName: json['organizationName'] as String? ?? '',
    organizationLevel: json['organizationLevel'] as String? ?? '',
    asOf: json['asOf'] as String? ?? '',
    periodStart: json['periodStart'] as String? ?? '',
    periodMonths: _int(json['periodMonths']),
    directCurrentEmployees: _int(json['directCurrentEmployees']),
    currentEmployees: _int(json['currentEmployees']),
    activeEmployees: _int(json['activeEmployees']),
    probationEmployees: _int(json['probationEmployees']),
    onLeaveEmployees: _int(json['onLeaveEmployees']),
    hiredEmployees: _int(json['hiredEmployees']),
    rehiredEmployees: _int(json['rehiredEmployees']),
    departedEmployees: _int(json['departedEmployees']),
    transferInEmployees: _int(json['transferInEmployees']),
    transferOutEmployees: _int(json['transferOutEmployees']),
    openingHeadcount: _int(json['openingHeadcount']),
    averageHeadcount: _doubleOrNull(json['averageHeadcount']),
    turnoverRatePct: _doubleOrNull(json['turnoverRatePct']),
    netChange: _int(json['netChange']),
    descendantDepartmentCount: _int(json['descendantDepartmentCount']),
    contractOverdue: _int(json['contractOverdue']),
    contractExpiringIn30Days: _int(json['contractExpiringIn30Days']),
    probationOverdue: _int(json['probationOverdue']),
    probationEndingIn30Days: _int(json['probationEndingIn30Days']),
    turnoverRateApproximate: json['turnoverRateApproximate'] as bool? ?? true,
    historyCoverageComplete: json['historyCoverageComplete'] as bool? ?? false,
    missingHistoryRecords: _int(json['missingHistoryRecords']),
    dataQualityNote: json['dataQualityNote'] as String? ?? '',
  );

  static int _int(dynamic value) => (value as num?)?.toInt() ?? 0;

  static double? _doubleOrNull(dynamic value) =>
      value == null ? null : (value as num).toDouble();
}
