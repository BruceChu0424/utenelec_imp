import 'dart:convert';
import '../../../core/utils/idempotency_key.dart';
import 'production_daily_report.dart';
import 'daily_report_material_review.dart';

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
    this.materialReviewFingerprint,
    this.materialDecisions = const [],
    this.materialReview,
  });

  final String reportId;
  final String idempotencyKey;
  final int commandVersion;
  final int? expectedVersion;
  final String confirmation;
  final String billNo;
  final String? materialReviewFingerprint;
  final List<DailyReportMaterialDecision> materialDecisions;
  final DailyReportMaterialReview? materialReview;
  bool get legacy => commandVersion == 1;

  factory DailyReportApprovalIntent.review(
    ProductionDailyReportDetail detail,
    String confirmation, {
    DailyReportMaterialReview? materialReview,
    Map<String, DailyReportMaterialAction> materialActions = const {},
  }) {
    if (!detail.supportsLegacyApproval && !detail.canFreezeReviewedApproval) {
      throw StateError('服务器未提供可核对的审核版本，请刷新后再试；当前没有提交审核。');
    }
    final protocol = detail.supportsMaterialReview
        ? 3
        : detail.canFreezeReviewedApproval
        ? 2
        : 1;
    if (protocol == 3 &&
        (materialReview == null ||
            materialReview.reportId != detail.id ||
            materialReview.reportVersion != detail.rowVersion)) {
      throw StateError('余料核对资料与日报版本不一致，请刷新后重新核对');
    }
    final decisions = protocol == 3
        ? materialReview!.freezeDecisions(materialActions)
        : const <DailyReportMaterialDecision>[];
    final orderedDecisions = decisions.toList()
      ..sort((a, b) => a.demandId.compareTo(b.demandId));
    final fingerprint = protocol == 3 ? materialReview!.fingerprint : null;
    return DailyReportApprovalIntent(
      reportId: detail.id,
      idempotencyKey: businessIdempotencyKey(
        protocol == 3
            ? 'daily-report-approve-v3'
            : protocol == 2
            ? 'daily-report-approve-v2'
            : 'daily-report-approve',
        '${detail.id}:${detail.rowVersion}'
        '${protocol == 3 ? ':$fingerprint:${jsonEncode(orderedDecisions.map((d) => d.toJson()).toList())}' : ''}',
      ),
      commandVersion: protocol,
      expectedVersion: protocol >= 2 ? detail.rowVersion : null,
      confirmation: confirmation,
      billNo: detail.billNo ?? detail.id,
      materialReviewFingerprint: fingerprint,
      materialDecisions: List.unmodifiable(decisions),
      materialReview: protocol == 3
          ? DailyReportMaterialReview.fromJson(materialReview!.toJson())
          : null,
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
          : receipt.commandVersion == commandVersion &&
                receipt.reviewedVersion == expectedVersion &&
                (commandVersion != 3 ||
                    receipt.materialReviewFingerprint ==
                        materialReviewFingerprint));

  Map<String, dynamic> toJson() => {
    'schemaVersion': commandVersion == 3 ? 2 : 1,
    'reportId': reportId,
    'idempotencyKey': idempotencyKey,
    'commandVersion': commandVersion,
    'expectedVersion': ?expectedVersion,
    'confirmation': confirmation,
    'billNo': billNo,
    'materialReviewFingerprint': ?materialReviewFingerprint,
    if (commandVersion == 3)
      'materialDecisions': materialDecisions
          .map((line) => line.toJson())
          .toList(),
    if (commandVersion == 3) 'materialReview': materialReview!.toJson(),
  };

  factory DailyReportApprovalIntent.fromJson(Map<String, dynamic> json) {
    // Older local records without protocol metadata are legacy unknown commands.
    final protocol = json['commandVersion'] ?? 1;
    final version = json['expectedVersion'];
    final schema = json['schemaVersion'];
    final fingerprint = json['materialReviewFingerprint'];
    final rawDecisions = json['materialDecisions'];
    final rawReview = json['materialReview'];
    if ((schema != null && schema != 1 && schema != 2) ||
        (protocol != 1 && protocol != 2 && protocol != 3) ||
        (protocol == 1 && version != null) ||
        ((protocol == 2 || protocol == 3) &&
            (version is! int || version < 0)) ||
        (protocol == 3 &&
            (schema != 2 ||
                fingerprint is! String ||
                fingerprint.isEmpty ||
                rawDecisions is! List ||
                rawReview is! Map)) ||
        (protocol != 3 &&
            (fingerprint != null ||
                rawDecisions != null ||
                rawReview != null)) ||
        json['reportId'] is! String ||
        (json['reportId'] as String).isEmpty ||
        json['idempotencyKey'] is! String ||
        (json['idempotencyKey'] as String).isEmpty) {
      throw const FormatException('原审核记录不完整，请保留本机记录并联系管理员核对');
    }
    final decisions = [
      for (final raw in rawDecisions as List? ?? const [])
        DailyReportMaterialDecision.fromJson(
          Map<String, dynamic>.from(raw as Map),
        ),
    ];
    if (decisions.map((line) => line.demandId).toSet().length !=
        decisions.length) {
      throw const FormatException('原审核余料处理包含重复需求，请保留记录核对');
    }
    final materialReview = protocol == 3
        ? DailyReportMaterialReview.fromJson(
            Map<String, dynamic>.from(rawReview as Map),
          )
        : null;
    if (materialReview != null &&
        (materialReview.reportId != json['reportId'] ||
            materialReview.reportVersion != version ||
            materialReview.fingerprint != fingerprint ||
            materialReview.rows.length != decisions.length ||
            decisions.any(
              (decision) => !materialReview.rows.any(
                (row) =>
                    row.demandId == decision.demandId &&
                    (decision.action == DailyReportMaterialAction.keep ||
                        row.requiresDecision),
              ),
            ))) {
      throw const FormatException('原审核材料快照与处理方式不一致，请保留记录核对');
    }
    return DailyReportApprovalIntent(
      reportId: json['reportId'] as String,
      idempotencyKey: json['idempotencyKey'] as String,
      commandVersion: protocol as int,
      expectedVersion: version as int?,
      confirmation: json['confirmation'] as String? ?? '历史审核请求，原确认内容未保存。',
      billNo: json['billNo'] as String? ?? json['reportId'] as String,
      materialReviewFingerprint: fingerprint as String?,
      materialDecisions: List.unmodifiable(decisions),
      materialReview: materialReview,
    );
  }
}
