// 工资条模型
// 文档：docs/04-数据模型/实体字典.md#PayrollSlip

import '../../../core/utils/china_datetime.dart';
import 'payroll_item.dart';

/// 工资条状态
enum PayrollSlipStatus {
  /// 待发布（人事未点发布）
  pending,

  /// 已发布（员工可见）
  published,

  /// 已查看（员工打开过）
  viewed,

  /// 已下载（员工导出过）
  downloaded,
}

extension PayrollSlipStatusValue on PayrollSlipStatus {
  String get label => switch (this) {
    PayrollSlipStatus.pending => '待发布',
    PayrollSlipStatus.published => '已发布',
    PayrollSlipStatus.viewed => '已查看',
    PayrollSlipStatus.downloaded => '已下载',
  };

  String get labelEn => switch (this) {
    PayrollSlipStatus.pending => 'Pending',
    PayrollSlipStatus.published => 'Published',
    PayrollSlipStatus.viewed => 'Viewed',
    PayrollSlipStatus.downloaded => 'Downloaded',
  };

  /// 工资条的服务端状态只表示发布可见性；查看/下载由时间字段派生。
  static PayrollSlipStatus fromApi(
    Object? value, {
    DateTime? viewedAt,
    DateTime? downloadedAt,
  }) {
    if (downloadedAt != null) return PayrollSlipStatus.downloaded;
    if (viewedAt != null) return PayrollSlipStatus.viewed;
    return switch (value?.toString().trim().toUpperCase()) {
      'PENDING' || 'DRAFT' => PayrollSlipStatus.pending,
      'PUBLISHED' => PayrollSlipStatus.published,
      // 兼容旧接口，但新后端不应再把行为状态写进 status。
      'VIEWED' => PayrollSlipStatus.viewed,
      'DOWNLOADED' => PayrollSlipStatus.downloaded,
      final unknown => throw FormatException('未知工资条状态：$unknown'),
    };
  }
}

/// 工资条
class PayrollSlip {
  const PayrollSlip({
    required this.id,
    required this.employeeId,
    required this.employeeName,
    required this.employeeCode,
    required this.year,
    required this.month,
    required this.items,
    required this.grossIncome,
    required this.totalDeduction,
    required this.netIncome,
    required this.status,
    required this.publishedAt,
    this.viewedAt,
    this.downloadedAt,
    this.remark,
  });

  final String id;
  final String employeeId;
  final String employeeName;
  final String employeeCode;

  /// 工资所属年（如 2026）
  final int year;

  /// 工资所属月（1-12）
  final int month;

  /// 工资项明细
  final List<PayrollItem> items;

  /// 应发合计（税前）
  final double grossIncome;

  /// 扣除合计（社保+公积金+个税+其他）
  final double totalDeduction;

  /// 实发合计（到手）
  final double netIncome;

  /// 状态
  final PayrollSlipStatus status;

  /// 发布时间
  final DateTime? publishedAt;

  /// 首次查看时间
  final DateTime? viewedAt;

  /// 首次下载时间
  final DateTime? downloadedAt;

  /// 备注（如调整说明）
  final String? remark;

  /// 月份格式化（如 2026-07）
  String get periodLabel {
    final m = month.toString().padLeft(2, '0');
    return '$year-$m';
  }

  /// 月份中文（如 2026年7月）
  String get periodLabelZh => '$year年$month月';

  factory PayrollSlip.fromJson(Map<String, dynamic> json) {
    final publishedAt = _dateTime(json['publishedAt']);
    final viewedAt = _dateTime(json['viewedAt']);
    final downloadedAt = _dateTime(json['downloadedAt']);
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return PayrollSlip(
      id: json['id'] as String,
      employeeId: json['employeeId'] as String,
      employeeName: json['employeeName'] as String,
      employeeCode: json['employeeCode'] as String,
      year: (json['year'] as num).toInt(),
      month: (json['month'] as num).toInt(),
      items: rawItems
          .map((item) => PayrollItem.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      grossIncome: (json['grossIncome'] as num).toDouble(),
      totalDeduction: (json['totalDeduction'] as num).toDouble(),
      netIncome: (json['netIncome'] as num).toDouble(),
      status: PayrollSlipStatusValue.fromApi(
        json['status'],
        viewedAt: viewedAt,
        downloadedAt: downloadedAt,
      ),
      publishedAt: publishedAt,
      viewedAt: viewedAt,
      downloadedAt: downloadedAt,
      remark: json['remark'] as String?,
    );
  }

  PayrollSlip copyWith({
    PayrollSlipStatus? status,
    DateTime? viewedAt,
    DateTime? downloadedAt,
  }) {
    return PayrollSlip(
      id: id,
      employeeId: employeeId,
      employeeName: employeeName,
      employeeCode: employeeCode,
      year: year,
      month: month,
      items: items,
      grossIncome: grossIncome,
      totalDeduction: totalDeduction,
      netIncome: netIncome,
      status: status ?? this.status,
      publishedAt: publishedAt,
      viewedAt: viewedAt ?? this.viewedAt,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      remark: remark,
    );
  }
}

DateTime? _dateTime(Object? value) {
  if (value == null) return null;
  return ChinaDateTime.tryParse(value as String);
}
