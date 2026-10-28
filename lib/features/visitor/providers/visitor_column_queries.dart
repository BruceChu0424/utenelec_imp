import 'package:flutter_riverpod/legacy.dart';

import '../../../shared/providers/export_context_epoch_provider.dart';
import '../models/visitor_column_query.dart';

export '../models/visitor_column_query.dart';

final visitorMineColumnsProvider =
    StateProvider.autoDispose<VisitorColumnQuery>((ref) {
      ref.watch(exportContextEpochProvider);
      return const VisitorColumnQuery();
    }, dependencies: [exportContextEpochProvider]);

final visitorApprovalColumnsProvider =
    StateProvider.autoDispose<VisitorColumnQuery>((ref) {
      ref.watch(exportContextEpochProvider);
      return const VisitorColumnQuery();
    }, dependencies: [exportContextEpochProvider]);

final visitorHostColumnsProvider =
    StateProvider.autoDispose<VisitorColumnQuery>((ref) {
      ref.watch(exportContextEpochProvider);
      return const VisitorColumnQuery();
    }, dependencies: [exportContextEpochProvider]);

final visitorBlacklistColumnsProvider =
    StateProvider.autoDispose<VisitorColumnQuery>((ref) {
      ref.watch(exportContextEpochProvider);
      return const VisitorColumnQuery();
    }, dependencies: [exportContextEpochProvider]);
