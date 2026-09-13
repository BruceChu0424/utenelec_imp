import 'material_future_transfer.dart';

/// Display-only aggregation of server transfer facts; it never computes stock readiness.
class MaterialFutureTransferProgress {
  const MaterialFutureTransferProgress({
    required this.outgoing,
    required this.outstandingOutgoing,
    required this.receivedOutgoing,
    required this.incoming,
    required this.outstandingIncoming,
    required this.receivedIncoming,
    required this.hasRecords,
    this.hasSupplyWarning = false,
  });
  final double outgoing;
  final double outstandingOutgoing;
  final double receivedOutgoing;
  final double incoming;
  final double outstandingIncoming;
  final double receivedIncoming;
  final bool hasRecords;
  final bool hasSupplyWarning;

  static const empty = MaterialFutureTransferProgress(
    outgoing: 0,
    outstandingOutgoing: 0,
    receivedOutgoing: 0,
    incoming: 0,
    outstandingIncoming: 0,
    receivedIncoming: 0,
    hasRecords: false,
  );

  static Map<String, List<MaterialFutureTransferRecord>> index(
    String analysisId,
    Iterable<MaterialFutureTransferRecord> records,
  ) {
    final result = <String, List<MaterialFutureTransferRecord>>{};
    final seen = <String>{};
    for (final record in records) {
      if (!seen.add(record.id)) continue;
      final id = record.sourceAnalysisId == analysisId
          ? record.sourceMaterialId
          : record.targetAnalysisId == analysisId
          ? record.targetMaterialId
          : null;
      if (id != null) result.putIfAbsent(id, () => []).add(record);
    }
    return Map.unmodifiable({
      for (final entry in result.entries)
        entry.key: List<MaterialFutureTransferRecord>.unmodifiable(entry.value),
    });
  }

  static MaterialFutureTransferProgress fromRecords(
    String analysisId,
    Iterable<String> materialIds,
    Iterable<MaterialFutureTransferRecord> records,
  ) {
    final ids = materialIds.toSet();
    final seen = <String>{};
    var outgoing = 0.0, outstandingOutgoing = 0.0, receivedOutgoing = 0.0;
    var incoming = 0.0, outstandingIncoming = 0.0, receivedIncoming = 0.0;
    var found = false;
    var warning = false;
    for (final record in records) {
      final out =
          record.sourceAnalysisId == analysisId &&
          ids.contains(record.sourceMaterialId);
      final into =
          record.targetAnalysisId == analysisId &&
          ids.contains(record.targetMaterialId);
      if ((!out && !into) || !seen.add(record.id)) continue;
      found = true;
      warning =
          warning ||
          (record.remainingQty > 0 &&
              (record.sourceSupplyShortfallQty > 0 ||
                  (record.supplyWarning?.trim().isNotEmpty ?? false)));
      final effective = (record.qty - record.cancelledQty).clamp(
        0.0,
        double.infinity,
      );
      if (out) {
        outgoing += effective;
        outstandingOutgoing += record.remainingQty;
        receivedOutgoing += record.receivedQty;
      }
      if (into) {
        incoming += effective;
        outstandingIncoming += record.remainingQty;
        receivedIncoming += record.receivedQty;
      }
    }
    if (!found) return empty;
    return MaterialFutureTransferProgress(
      outgoing: outgoing,
      outstandingOutgoing: outstandingOutgoing,
      receivedOutgoing: receivedOutgoing,
      incoming: incoming,
      outstandingIncoming: outstandingIncoming,
      receivedIncoming: receivedIncoming,
      hasRecords: found,
      hasSupplyWarning: warning,
    );
  }
}
