import '../../../shared/history/record_revision_page.dart';

/// Stable owning entry for master-data restoration navigation.
class MasterRecordRevisionPage extends RecordRevisionPage {
  const MasterRecordRevisionPage({
    super.key,
    required super.entityType,
    required super.id,
    super.changeSignal,
  });
}
