import '../../../core/utils/idempotency_key.dart';
import 'production_daily_report.dart';

/// Frozen at confirmation, persisted before sending. A current GET never supplies
/// missing historical review metadata when this command is recovered.
class DailyReportApprovalIntent {
  const DailyReportApprovalIntent({
    required this.reportId,
    required this.idempotencyKey,
    required this.commandVersion,
    required this.expectedVersion,
    required this.confirmation,
    required this.billNo,
  });

  final String reportId;
  final String idempotencyKey;
  final int commandVersion;
  final int? expectedVersion;
  final String confirmation;
  final String billNo;
  bool get legacy => commandVersion == 1;

  factory DailyReportApprovalIntent.review(
    ProductionDailyReportDetail detail,
    String confirmation,
  ) {
    if (!detail.supportsLegacyApproval && !detail.canFreezeReviewedApproval) {
      throw StateError('服务器未提供可核对的审核版本，请刷新后再试；当前没有提交审核。');
    }
    final protocol = detail.canFreezeReviewedApproval ? 2 : 1;
    return DailyReportApprovalIntent(
      reportId: detail.id,
      idempotencyKey: businessIdempotencyKey(
        protocol == 2 ? 'daily-report-approve-v2' : 'daily-report-approve',
        '${detail.id}:${detail.rowVersion}',
      ),
      commandVersion: protocol,
      expectedVersion: protocol == 2 ? detail.rowVersion : null,
      confirmation: confirmation,
      billNo: detail.billNo ?? detail.id,
    );
  }

  bool ownsReceipt(ProductionDailyReportApprovalReceipt receipt) =>
      receipt.valid &&
      receipt.reportId == reportId &&
      receipt.idempotencyKey == idempotencyKey;

  bool verifiedReceipt(ProductionDailyReportApprovalReceipt receipt) =>
      ownsReceipt(receipt) &&
      (legacy
          ? receipt.legacy
          : receipt.commandVersion == 2 &&
                receipt.reviewedVersion == expectedVersion);

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'reportId': reportId,
    'idempotencyKey': idempotencyKey,
    'commandVersion': commandVersion,
    'expectedVersion': ?expectedVersion,
    'confirmation': confirmation,
    'billNo': billNo,
  };

  factory DailyReportApprovalIntent.fromJson(Map<String, dynamic> json) {
    // Older local records without protocol metadata are legacy unknown commands.
    final protocol = json['commandVersion'] ?? 1;
    final version = json['expectedVersion'];
    if ((json['schemaVersion'] != null && json['schemaVersion'] != 1) ||
        (protocol != 1 && protocol != 2) ||
        (protocol == 1 && version != null) ||
        (protocol == 2 && (version is! int || version < 0)) ||
        json['reportId'] is! String ||
        (json['reportId'] as String).isEmpty ||
        json['idempotencyKey'] is! String ||
        (json['idempotencyKey'] as String).isEmpty) {
      throw const FormatException('原审核记录不完整，请保留本机记录并联系管理员核对');
    }
    return DailyReportApprovalIntent(
      reportId: json['reportId'] as String,
      idempotencyKey: json['idempotencyKey'] as String,
      commandVersion: protocol as int,
      expectedVersion: version as int?,
      confirmation: json['confirmation'] as String? ?? '历史审核请求，原确认内容未保存。',
      billNo: json['billNo'] as String? ?? json['reportId'] as String,
    );
  }
}
