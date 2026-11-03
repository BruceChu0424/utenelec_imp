import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/data_write_revision.dart';
import '../../../shared/paging/prepared_page_read.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/retain_read_snapshot.dart';
import '../models/sales_doc.dart';
import '../models/sales_order_progress.dart';

PreparedPageRead<T> _lease<T>(Ref ref) {
  ref.watch(exportContextEpochProvider);
  ref.watch(dataWriteRevisionProvider);
  retainReadSnapshot(ref);
  final reads = PreparedPageRead<T>();
  ref.onDispose(reads.dispose);
  return reads;
}

final salesPreparedListProvider = Provider.autoDispose(
  (ref) => _lease<SalesDocListItem>(ref),
  dependencies: [exportContextEpochProvider],
);

final salesPreparedProgressProvider = Provider.autoDispose(
  (ref) => _lease<SalesOrderProgressRow>(ref),
  dependencies: [exportContextEpochProvider],
);
