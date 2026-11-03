import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/data_write_revision.dart';
import '../../../../shared/paging/prepared_page_read.dart';
import '../../../../shared/providers/export_context_epoch_provider.dart';
import '../models/stock_count_request.dart';

final stockCountPreparedPageProvider = Provider((ref) {
  ref.watch(exportContextEpochProvider);
  ref.watch(dataWriteRevisionProvider);
  final reads = PreparedPageRead<StockCountRequest>();
  ref.onDispose(reads.dispose);
  return reads;
}, dependencies: [exportContextEpochProvider]);
