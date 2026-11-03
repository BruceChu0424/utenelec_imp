import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/data_write_revision.dart';
import '../../../shared/paging/prepared_page_read.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/retain_read_snapshot.dart';
import '../models/procurement_iqc_rejection.dart';

/// Shared by this domain's table and the composing finance queue coordinator.
final financeIqcPreparedPageProvider = Provider.autoDispose((ref) {
  ref.watch(exportContextEpochProvider);
  ref.watch(dataWriteRevisionProvider);
  retainReadSnapshot(ref);
  final page = PreparedPageRead<ProcurementIqcRejectionCase>();
  ref.onDispose(page.dispose);
  return page;
}, dependencies: [exportContextEpochProvider]);

Object financeIqcReadKey(Object repo, ProcurementIqcRejectionFilter filter) => [
  repo,
  filter.toQuery(),
];
