import 'package:flutter_riverpod/legacy.dart';

import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/search/table_column_query.dart';

export '../../../shared/search/table_column_query.dart';

final profileMineColumnsProvider = StateProvider.autoDispose<TableColumnQuery>((
  ref,
) {
  ref.watch(exportContextEpochProvider);
  return const TableColumnQuery();
}, dependencies: [exportContextEpochProvider]);

final profileHrColumnsProvider = StateProvider.autoDispose<TableColumnQuery>((
  ref,
) {
  ref.watch(exportContextEpochProvider);
  return const TableColumnQuery();
}, dependencies: [exportContextEpochProvider]);
