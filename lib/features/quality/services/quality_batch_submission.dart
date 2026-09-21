import 'package:uuid/uuid.dart';

import '../../warehouse/repositories/procurement_inspection_repository.dart';
import '../repositories/production_fqc_repository.dart';

/// One receipt stays atomic on the server. Across receipts, each lane keeps the
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
  }) : receipts = List.unmodifiable(receipts),
       fqcInspectionIds = List.unmodifiable(fqcInspectionIds.toSet()),
       fqcIdempotencyKey = 'fqc-batch-approval-${const Uuid().v4()}';

  /// 2026-09-21 起收货单按报告顺序逐单提交(此前 2026-09-18 为最多 4 条并行通道)。
  /// 实测(QualityBatchApprovalPerfProbeTest)：同一主仓/同一订货单的收货单在服务端本就
  /// 按同一把物料分析仓级锁与订单行锁串行执行，4 条通道并不比逐单快，反而互相等锁、
  /// 撞「来源集合在预读后变化」后整笔回滚重跑；真正的提速在服务端(一次结论一个自动
  /// 转正批次、只刷一遍物料分析)。每张单仍是服务端一个独立原子事务(冻结命令 + 幂等键
  /// 不变)，失败不连坐、重试只补未确认的单。
  static const int _sendLanes = 1;

  final List<QualityReceiptSubmission> receipts;
  final List<String> fqcInspectionIds;
  final String? reason;
  final String fqcIdempotencyKey;
  final Set<int> _acknowledged = <int>{};
  bool _fqcAcknowledged = false;
  bool _running = false;

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
    if (_running) throw StateError('同一检验报告不能并发提交');
    _running = true;
    try {
      final pending = [
        for (var i = 0; i < receipts.length; i++)
          if (!_acknowledged.contains(i)) i,
      ];
      // 一张单失败不再连坐取消其余单：通道全部跑完后按报告顺序抛最早失败，
      // 未确认的单重试时原样重发（串行时代的快速失败在并行下只会白丢进度）。
      final failures = <int, Object>{};
      var next = 0;
      Future<void> worker() async {
        while (next < pending.length) {
          final index = pending[next++];
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
            failures[index] = error;
          }
        }
      }

      await Future.wait([
        for (var i = 0; i < _sendLanes && i < pending.length; i++) worker(),
      ]);
      if (failures.isNotEmpty) {
        final earliest = failures.keys.reduce((a, b) => a < b ? a : b);
        throw failures[earliest]!;
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
