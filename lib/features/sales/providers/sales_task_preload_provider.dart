import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/data_write_revision.dart';
import '../../../shared/paging/prepared_page_read.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../models/sales_doc.dart';
import '../repositories/sales_repository.dart';

/// Prepare only the current category's working first pages. Two shared workers
/// survive category switches so abandoned categories cannot flood the network.
class SalesTaskPreloader {
  SalesTaskPreloader(this._ref);
  final Ref _ref;
  String? _group;
  int _active = 0;
  bool _disposed = false;
  final _waiting = <Future<void> Function()>[];
  bool Function()? _canPrepare;
  final _batchAge = Stopwatch();

  void prepare(String group, {required bool Function() canPrepare}) {
    _canPrepare = canPrepare;
    if (_disposed) return;
    if (_group == group &&
        (_active > 0 ||
            _waiting.isNotEmpty ||
            _batchAge.elapsed < PreparedPageRead.defaultFreshFor)) {
      _drain();
      return;
    }
    _group = group;
    _batchAge
      ..reset()
      ..start();
    _waiting.clear();
    if (group == 'progress') {
      final repo = _ref.read(salesRepositoryProvider(SalesDocType.order));
      for (final stage in const ['DRAFT', 'IN_PROGRESS', 'READY_TO_SHIP']) {
        _waiting.add(() => repo.prepareProgress(stage));
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
          _waiting.add(() => repo.prepareList(filter: filter));
        }
      }
    }
    // Register the handoff before post-frame automatic task selection.
    // Transport yields normally without blocking layout.
    _drain();
  }

  void _drain() {
    while (!_disposed &&
        _active < 2 &&
        _waiting.isNotEmpty &&
        (_canPrepare?.call() ?? false)) {
      final task = _waiting.removeAt(0);
      _active++;
      unawaited(
        Future<void>.sync(task).catchError((Object _) {}).whenComplete(() {
          _active--;
          _drain();
        }),
      );
    }
  }

  void dispose() {
    _disposed = true;
    _waiting.clear();
  }

  void retire() {
    _group = null;
    _waiting.clear();
  }
}

// Keep the tiny physical coordinator through a brief page departure, too.
// Reopening a page must not reset the budget while its old transports finish.
final salesTaskPreloaderProvider = Provider((ref) {
  final preloader = SalesTaskPreloader(ref);
  // Retire the jobs, not the physical workers. Late transports from a prior
  // owner still occupy the same two slots until they finish.
  void retire() {
    preloader.retire();
    ref.notifyListeners();
  }

  ref.listen(exportContextEpochProvider, (_, _) => retire());
  ref.listen(dataWriteRevisionProvider, (_, _) => retire());
  ref.onDispose(preloader.dispose);
  return preloader;
}, dependencies: [exportContextEpochProvider, salesRepositoryProvider]);
