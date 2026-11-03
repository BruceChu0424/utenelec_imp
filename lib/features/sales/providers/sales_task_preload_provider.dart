import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/data_write_revision.dart';
import '../../../shared/paging/page_preparation_coordinator.dart';
import '../../../shared/paging/page_preparation_budget_provider.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../models/sales_doc.dart';
import '../repositories/sales_repository.dart';

/// Prepare only the current category's working first pages. Two shared workers
/// survive category switches so abandoned categories cannot flood the network.
class SalesTaskPreloader {
  SalesTaskPreloader(Ref ref)
    : _ref = ref,
      _coordinator = PagePreparationCoordinator(
        budget: ref.read(pagePreparationBudgetProvider),
      );
  final Ref _ref;
  final PagePreparationCoordinator _coordinator;

  void prepare(String group, {required bool Function() canPrepare}) {
    final jobs = <Future<void> Function()>[];
    Object? source;
    if (group == 'progress') {
      final repo = _ref.read(salesRepositoryProvider(SalesDocType.order));
      source = repo;
      for (final stage in const ['DRAFT', 'IN_PROGRESS', 'READY_TO_SHIP']) {
        jobs.add(() => repo.prepareProgress(stage));
      }
    } else {
      final type = switch (group) {
        'shipments' => SalesDocType.shipment,
        'customerShipments' => SalesDocType.customerShipment,
        'returns' => SalesDocType.returnDoc,
        'quotes' => SalesDocType.quote,
        _ => null,
      };
      if (type != null) {
        final repo = _ref.read(salesRepositoryProvider(type));
        source = repo;
        final filters = type == SalesDocType.quote
            ? [
                const SalesDocFilter(bucket: 'ACTIVE'),
                for (final stage in SalesQuoteStage.segments)
                  if (stage != SalesQuoteStage.approved &&
                      stage != SalesQuoteStage.reversed)
                    SalesDocFilter(bucket: stage),
              ]
            : type.isShipment
            ? [
                const SalesDocFilter(stage: 'ACTIVE'),
                for (final stage in SalesShipmentStage.segments)
                  if (stage != SalesShipmentStage.shipped &&
                      stage != SalesShipmentStage.reversed)
                    SalesDocFilter(stage: stage),
              ]
            : const [SalesDocFilter(status: kSalesStatusDraft)];
        for (final filter in filters) {
          jobs.add(() => repo.prepareList(filter: filter));
        }
      }
    }
    _coordinator.prepare([group, source], jobs, canPrepare: canPrepare);
  }

  void dispose() {
    _coordinator.dispose();
  }

  void retire() {
    _coordinator.retire();
  }
}

// Keep the tiny physical coordinator through a brief page departure, too.
// Reopening a page must not reset the budget while its old transports finish.
final salesTaskPreloaderProvider = Provider((ref) {
  final preloader = SalesTaskPreloader(ref);
  // Retire the jobs, not the physical workers. Late transports from a prior
  // owner still occupy the same two slots until they finish.
  final retire = pagePreparationRetirementCallback(ref, preloader.retire);

  ref.listen(exportContextEpochProvider, (_, _) => retire());
  ref.listen(dataWriteRevisionProvider, (_, _) => retire());
  for (final type in SalesDocType.values) {
    ref.listen(salesRepositoryProvider(type), (_, _) => retire());
  }
  ref.onDispose(preloader.dispose);
  return preloader;
}, dependencies: [exportContextEpochProvider, salesRepositoryProvider]);
