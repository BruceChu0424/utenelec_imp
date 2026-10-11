import 'package:uuid/uuid.dart';
import '../../../core/network/authenticated_request_scope.dart';

import '../../warehouse/repositories/procurement_inspection_repository.dart';
import '../repositories/production_fqc_repository.dart';

/// One receipt stays atomic on the server. Across receipts, the whole report is
/// one server-side transaction (2026-10-10 decide-report): any conflicting
/// receipt rolls back everything, and the exact accepted report replays
/// silently on retry.
class QualityReceiptSubmission {
  QualityReceiptSubmission({
    required this.receiptType,
    required this.receiptId,
    required this.label,
    required List<ProcurementInspectionDecideItem> items,
  }) : items = List.unmodifiable(items);

  final String receiptType;
  final String receiptId;
  final String label;
  final List<ProcurementInspectionDecideItem> items;
}

/// A timeout leaves the report unacknowledged, including its body and keys.
/// Retry sends that same whole report; committed receipts replay silently and
/// rolled-back ones execute fresh — no half-committed state exists.
/// This object is owned by the approval page, not a cross-session stock cache.
class QualityBatchSubmission {
  QualityBatchSubmission({
    required List<QualityReceiptSubmission> receipts,
    required List<String> fqcInspectionIds,
    required this.reason,
    String? fqcKey,
    int? fqcLotCount,
  }) : receipts = List.unmodifiable(receipts),
       fqcInspectionIds = List.unmodifiable(fqcInspectionIds.toSet()),
       fqcLotCount = fqcLotCount ?? fqcInspectionIds.toSet().length,
       fqcIdempotencyKey = fqcKey ?? 'fqc-batch-approval-${const Uuid().v4()}';

  Map<String, dynamic> exportDraft() => {
    'receipts': [
      for (final receipt in receipts)
        {
          'receiptType': receipt.receiptType,
          'receiptId': receipt.receiptId,
          'label': receipt.label,
          'items': receipt.items.map((item) => item.toJson()).toList(),
        },
    ],
    'fqcInspectionIds': fqcInspectionIds,
    'fqcLotCount': fqcLotCount,
    'reason': reason,
    'fqcIdempotencyKey': fqcIdempotencyKey,
    'acknowledged': _acknowledged.toList(),
    'fqcAcknowledged': _fqcAcknowledged,
  };

  factory QualityBatchSubmission.fromDraft(Map<String, dynamic> data) {
    final result = QualityBatchSubmission(
      receipts: [
        for (final receipt
            in (data['receipts'] as List<dynamic>).cast<Map<String, dynamic>>())
          QualityReceiptSubmission(
            receiptType: receipt['receiptType'] as String,
            receiptId: receipt['receiptId'] as String,
            label: receipt['label'] as String,
            items: [
              for (final item
                  in (receipt['items'] as List<dynamic>)
                      .cast<Map<String, dynamic>>())
                ProcurementInspectionDecideItem(
                  inspectionItemId: item['inspectionItemId'] as String,
                  expectedRemainingBaseQty:
                      (item['expectedRemainingBaseQty'] as num).toDouble(),
                  passBaseQty: (item['passBaseQty'] as num).toDouble(),
                  failBaseQty: (item['failBaseQty'] as num).toDouble(),
                  idempotencyKey: item['idempotencyKey'] as String,
                ),
            ],
          ),
      ],
      fqcInspectionIds: (data['fqcInspectionIds'] as List<dynamic>)
          .cast<String>(),
      reason: data['reason'] as String?,
      fqcKey: data['fqcIdempotencyKey'] as String,
      fqcLotCount: (data['fqcLotCount'] as num?)?.toInt(),
    );
    result._acknowledged.addAll(
      (data['acknowledged'] as List<dynamic>).cast<int>(),
    );
    result._fqcAcknowledged = data['fqcAcknowledged'] == true;
    return result;
  }

  final List<QualityReceiptSubmission> receipts;

  /// 本次全部合格的自制产成品批数(ADR-148: 一批实物一行; 批内各份的检查任务都在 [fqcInspectionIds] 里)。
  final int fqcLotCount;
  final List<String> fqcInspectionIds;
  final String? reason;
  final String fqcIdempotencyKey;
  final Set<int> _acknowledged = <int>{};
  bool _fqcAcknowledged = false;
  bool _running = false;
  AuthenticatedRequestScope? _requestScope;

  /// 服务端确认判定的检查任务份数(整批展开后); 还没发或从草稿恢复时为空。
  int? fqcProcessedCount;

  int get completedReceiptCount => _acknowledged.length;
  int get remainingReceiptCount => receipts.length - _acknowledged.length;
  int get iqcLineCount =>
      receipts.fold(0, (count, receipt) => count + receipt.items.length);
  bool get complete =>
      _acknowledged.length == receipts.length &&
      (fqcInspectionIds.isEmpty || _fqcAcknowledged);
  Iterable<String> get acknowledgedIqcIds => [
    for (var i = 0; i < receipts.length; i++)
      if (_acknowledged.contains(i))
        ...receipts[i].items.map((item) => item.inspectionItemId),
  ];

  Future<void> send({
    required ProcurementInspectionRepository iqc,
    required ProductionFqcRepository fqc,
    required AuthenticatedRequestScope requestScope,
    void Function()? onProgress,
  }) async {
    if (_running) throw StateError('这份检验报告正在提交中，请等本次提交完成后再操作');
    final scope = _requestScope ??= requestScope;
    _running = true;
    try {
      await scope.run(() async {
        // 2026-10-10 整份检验报告一次提交：服务端 decide-report 单事务原子执行全部
        // 收货单（联合预锁 + 按报告顺序逐单），任一单冲突整批回滚并按单号报错。
        // 此前逐单串行发 decide-batch——N 张单 N 次 HTTP 往返，长批次既慢又容易在
        // 中途撞会话边界。响应丢失后重试同一体：已提交的单静默重放，回滚过的重新
        // 执行，不存在半提交状态；旧版草稿恢复出的部分确认集合并入重试同一处理。
        if (_acknowledged.length < receipts.length) {
          await scope.verify();
          try {
            await iqc.decideReport(
              receipts: [
                for (final receipt in receipts)
                  ProcurementInspectionReportReceipt(
                    receiptType: receipt.receiptType,
                    receiptId: receipt.receiptId,
                    items: receipt.items,
                  ),
              ],
              reason: reason,
            );
          } catch (error) {
            // 业务驳回与响应期换身份是两回事：先核对身份，身份已换按会话边界报，
            // 旧报告不得再被新身份重试；否则原样抛业务错误。
            if (isSessionBoundaryError(error)) rethrow;
            await scope.verify();
            rethrow;
          }
          _acknowledged.addAll([for (var i = 0; i < receipts.length; i++) i]);
          onProgress?.call();
        }
        await scope.verify();
        if (fqcInspectionIds.isNotEmpty && !_fqcAcknowledged) {
          final result = await fqc.passAll(
            inspectionIds: fqcInspectionIds,
            idempotencyKey: fqcIdempotencyKey,
          );
          fqcProcessedCount = result.processedCount;
          _fqcAcknowledged = true;
          onProgress?.call();
        }
        await scope.verify();
      });
    } finally {
      _running = false;
    }
  }
}
