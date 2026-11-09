import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;

/// The exact `(page, size)` requests a complete read of [total] rows makes
/// under the shared [plan] (50 → 50 → 100 → 200 … by default): every batch
/// is the page of its own size at the next unread row, offset ==
/// (page - 1) * size, so no row is read twice and none is skipped.
List<({int page, int size})> completeReadPlanBatches(
  int total, {
  CompleteReadBatchPlan plan = CompleteReadBatchPlan.progressive,
}) {
  final batches = <({int page, int size})>[];
  var offset = 0;
  do {
    final size = plan.sizeAt(offset);
    batches.add((page: offset ~/ size + 1, size: size));
    offset += size;
  } while (offset < total);
  return batches;
}
