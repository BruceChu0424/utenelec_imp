import '../../../core/utils/china_datetime.dart';
import 'payroll_slip.dart';

enum PayrollBatchStatus { draft, submitted, approved, rejected, published }

extension PayrollBatchStatusValue on PayrollBatchStatus {
  String get label => switch (this) {
    PayrollBatchStatus.draft => '草稿',
    PayrollBatchStatus.submitted => '待审核',
    PayrollBatchStatus.approved => '已通过',
    PayrollBatchStatus.rejected => '已驳回',
    PayrollBatchStatus.published => '已发布',
  };

  String get apiValue => name.toUpperCase();

  static PayrollBatchStatus fromApi(Object? value) {
    final normalized = value?.toString().trim().toUpperCase();
    return switch (normalized) {
      'DRAFT' => PayrollBatchStatus.draft,
      'SUBMITTED' => PayrollBatchStatus.submitted,
      'APPROVED' => PayrollBatchStatus.approved,
      'REJECTED' => PayrollBatchStatus.rejected,
      'PUBLISHED' => PayrollBatchStatus.published,
      _ => throw FormatException('未知工资批次状态：$value'),
    };
  }
}

class PayrollBatch {
  const PayrollBatch({
    required this.id,
    required this.year,
    required this.month,
    required this.status,
    required this.headcount,
    required this.grossIncome,
    required this.totalDeduction,
    required this.netIncome,
    this.departmentId,
    this.departmentName,
    this.slips = const [],
    this.createdAt,
    this.submittedAt,
    this.approvedAt,
    this.publishedAt,
    this.rejectReason,
  });

  final String id;
  final int year;
  final int month;
  final String? departmentId;
  final String? departmentName;
  final PayrollBatchStatus status;
  final int headcount;
  final double grossIncome;
  final double totalDeduction;
  final double netIncome;
  final List<PayrollSlip> slips;
  final DateTime? createdAt;
  final DateTime? submittedAt;
  final DateTime? approvedAt;
  final DateTime? publishedAt;
  final String? rejectReason;

  String get periodLabel => '$year-${month.toString().padLeft(2, '0')}';

  String get scopeLabel {
    final name = departmentName?.trim();
    return name == null || name.isEmpty ? '全员' : name;
  }

  factory PayrollBatch.fromJson(Map<String, dynamic> json) {
    final rawSlips = json['slips'] as List<dynamic>? ?? const [];
    return PayrollBatch(
      id: json['id'] as String,
      year: (json['year'] as num).toInt(),
      month: (json['month'] as num).toInt(),
      departmentId: json['departmentId'] as String?,
      departmentName: json['departmentName'] as String?,
      status: PayrollBatchStatusValue.fromApi(json['status']),
      headcount: (json['headcount'] as num?)?.toInt() ?? rawSlips.length,
      grossIncome: (json['grossIncome'] as num?)?.toDouble() ?? 0,
      totalDeduction: (json['totalDeduction'] as num?)?.toDouble() ?? 0,
      netIncome: (json['netIncome'] as num?)?.toDouble() ?? 0,
      slips: rawSlips
          .map((slip) => PayrollSlip.fromJson(slip as Map<String, dynamic>))
          .toList(growable: false),
      createdAt: _dateTime(json['createdAt']),
      submittedAt: _dateTime(json['submittedAt']),
      approvedAt: _dateTime(json['approvedAt']),
      publishedAt: _dateTime(json['publishedAt']),
      rejectReason: json['rejectReason'] as String?,
    );
  }
}

class PayrollBatchCreateInput {
  const PayrollBatchCreateInput({
    required this.year,
    required this.month,
    required this.includeOvertime,
    required this.includeBonus,
    required this.includeSocialInsurance,
    required this.includeTax,
    this.departmentId,
  });

  final int year;
  final int month;
  final String? departmentId;
  final bool includeOvertime;
  final bool includeBonus;
  final bool includeSocialInsurance;
  final bool includeTax;

  Map<String, dynamic> toJson() => {
    'year': year,
    'month': month,
    if (departmentId != null) 'departmentId': departmentId,
    'includeOvertime': includeOvertime,
    'includeBonus': includeBonus,
    'includeSocialInsurance': includeSocialInsurance,
    'includeTax': includeTax,
  };
}

class PayrollDepartmentOption {
  const PayrollDepartmentOption({
    required this.id,
    required this.name,
    required this.path,
  });

  final String id;
  final String name;
  final String path;

  static List<PayrollDepartmentOption> fromTree(
    List<Map<String, dynamic>> tree,
  ) {
    const selectableLevels = {'一级部门', '二级班组', '三级科室'};
    final result = <PayrollDepartmentOption>[];

    void walk(List<Map<String, dynamic>> nodes, List<String> parents) {
      for (final node in nodes) {
        final name = node['name'] as String;
        final level = node['level'] as String?;
        final nextParents = selectableLevels.contains(level)
            ? [...parents, name]
            : parents;
        if (selectableLevels.contains(level)) {
          result.add(
            PayrollDepartmentOption(
              id: node['id'] as String,
              name: name,
              path: nextParents.join('-'),
            ),
          );
        }
        final children = (node['children'] as List<dynamic>? ?? const [])
            .cast<Map<String, dynamic>>();
        walk(children, nextParents);
      }
    }

    walk(tree, const []);
    return result;
  }
}

DateTime? _dateTime(Object? value) {
  if (value == null) return null;
  return ChinaDateTime.tryParse(value as String);
}
