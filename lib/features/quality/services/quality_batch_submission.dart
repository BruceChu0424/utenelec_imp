import 'package:uuid/uuid.dart';

import '../../warehouse/repositories/procurement_inspection_repository.dart';
import '../repositories/production_fqc_repository.dart';

/// One receipt stays atomic on the server. Across receipts, keep the exact
/// accepted report and advance only after a successful acknowledgement.
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

/// A timeout leaves the current command unacknowledged, including its body and
/// keys. Retry sends that same command; completed receipts are never sent again.
/// This object is owned by the approval page, not a cross-session stock cache.
class QualityBatchSubmission {
  QualityBatchSubmission({
    required List<QualityReceiptSubmission> receipts,
    required List<String> fqcInspectionIds,
    required this.reason,
  }) : receipts = List.unmodifiable(receipts),
       fqcInspectionIds = List.unmodifiable(fqcInspectionIds.toSet()),
       fqcIdempotencyKey = 'fqc-batch-approval-${const Uuid().v4()}';

  final List<QualityReceiptSubmission> receipts;
  final List<String> fqcInspectionIds;
  final String? reason;
  final String fqcIdempotencyKey;
  int _nextReceipt = 0;
  bool _fqcAcknowledged = false;
  bool _running = false;

  int get completedReceiptCount => _nextReceipt;
  int get remainingReceiptCount => receipts.length - _nextReceipt;
  int get iqcLineCount =>
      receipts.fold(0, (count, receipt) => count + receipt.items.length);
  bool get complete =>
      _nextReceipt == receipts.length &&
      (fqcInspectionIds.isEmpty || _fqcAcknowledged);
  Iterable<String> get acknowledgedIqcIds => receipts
      .take(_nextReceipt)
      .expand((receipt) => receipt.items.map((item) => item.inspectionItemId));
  String get currentLabel =>
      _nextReceipt < receipts.length ? receipts[_nextReceipt].label : '自制产成品检验';

  Future<void> send({
    required ProcurementInspectionRepository iqc,
    required ProductionFqcRepository fqc,
    void Function()? onProgress,
  }) async {
    if (_running) throw StateError('同一检验报告不能并发提交');
    _running = true;
    try {
      while (_nextReceipt < receipts.length) {
        final receipt = receipts[_nextReceipt];
        await iqc.decideBatch(
          receiptType: receipt.receiptType,
          receiptId: receipt.receiptId,
          items: receipt.items,
          reason: reason,
        );
        _nextReceipt++;
        onProgress?.call();
      }
      if (fqcInspectionIds.isNotEmpty && !_fqcAcknowledged) {
        await fqc.passAll(
          inspectionIds: fqcInspectionIds,
          idempotencyKey: fqcIdempotencyKey,
        );
        _fqcAcknowledged = true;
        onProgress?.call();
      }
    } finally {
      _running = false;
    }
  }
}
