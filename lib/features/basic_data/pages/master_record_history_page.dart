import '../../../shared/history/record_history_page.dart';

/// Stable owning entry; rendering, paging and lifecycle live in the shared page.
class MasterRecordHistoryPage extends RecordHistoryPage {
  const MasterRecordHistoryPage({
    super.key,
    super.entityType,
    super.recordId,
    super.categoryId,
    super.changeSignal,
  });
}
