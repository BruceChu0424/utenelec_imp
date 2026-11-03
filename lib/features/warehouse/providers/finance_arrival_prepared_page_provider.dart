import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/data_write_revision.dart';
import '../../../shared/models/procurement_inbound.dart';
import '../../../shared/paging/prepared_page_read.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/retain_read_snapshot.dart';

/// The finance coordinator and warehouse-owned arrival page adopt one read.
final financeArrivalPreparedPageProvider = Provider.autoDispose((ref) {
  ref.watch(exportContextEpochProvider);
  ref.watch(dataWriteRevisionProvider);
  retainReadSnapshot(ref);
  final page = PreparedPageRead<ProcurementArrivalException>();
  ref.onDispose(page.dispose);
  return page;
}, dependencies: [exportContextEpochProvider]);

Object financeArrivalReadKey(
  Object repo, {
  int page = 1,
  String status = 'PENDING_FINANCE',
}) => [repo, page, status];
