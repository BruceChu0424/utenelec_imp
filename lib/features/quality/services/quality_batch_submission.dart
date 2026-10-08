import 'package:uuid/uuid.dart';

import '../../warehouse/repositories/procurement_inspection_repository.dart';
import '../repositories/production_fqc_repository.dart';

/// One receipt stays atomic on the server. Across receipts, each command keeps the
/// exact accepted report and only its own acknowledgement advances that receipt.
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

  /// 报错口径：最靠前的未确认收货单；全部确认后才轮到自制产成品。
  String get currentLabel {
    for (var i = 0; i < receipts.length; i++) {
      if (!_acknowledged.contains(i)) return receipts[i].label;
    }
    return '自制产成品检验';
  }

  Future<void> send({
    required ProcurementInspectionRepository iqc,
    required ProductionFqcRepository fqc,
    void Function()? onProgress,
  }) async {
    if (_running) throw StateError('这份检验报告正在提交中，请等本次提交完成后再操作');
    _running = true;
    try {
      final pending = [
        for (var i = 0; i < receipts.length; i++)
          if (!_acknowledged.contains(i)) i,
      ];
      // 共用主仓锁的收货单按报告顺序提交。失败不取消其它单，重试保留原命令身份。
      Object? firstFailure;
      for (final index in pending) {
        final receipt = receipts[index];
        try {
          await iqc.decideBatch(
            receiptType: receipt.receiptType,
            receiptId: receipt.receiptId,
            items: receipt.items,
            reason: reason,
          );
          _acknowledged.add(index);
          onProgress?.call();
        } catch (error) {
          firstFailure ??= error;
        }
      }
      if (firstFailure != null) throw firstFailure;
      if (fqcInspectionIds.isNotEmpty && !_fqcAcknowledged) {
        final result = await fqc.passAll(
          inspectionIds: fqcInspectionIds,
          idempotencyKey: fqcIdempotencyKey,
        );
        fqcProcessedCount = result.processedCount;
        _fqcAcknowledged = true;
        onProgress?.call();
      }
    } finally {
      _running = false;
    }
  }
}
