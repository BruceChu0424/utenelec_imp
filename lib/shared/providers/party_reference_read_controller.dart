import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/sales/providers/master_name_provider.dart';
import '../auth/read_owner_fence.dart';
import 'master_name_provider.dart';

class PartyReferenceSnapshot {
  const PartyReferenceSnapshot({
    this.clients = const {},
    this.suppliers = const {},
  });
  final Map<String, String> clients;
  final Map<String, String> suppliers;
}

Map<String, String> _resolvedLabels(
  Iterable<String> ids,
  String Function(String id) nameOf,
) => {
  for (final id in ids)
    if (nameOf(id) case final label when label.isNotEmpty && label != '—')
      id: label,
};

/// One read owns its fresh ID proofs and immutable labels; the shared reference
/// cache's later eviction or another view's pending request cannot change them.
class PartyReferenceReadController extends ChangeNotifier {
  PartyReferenceReadController(this.ref);
  final WidgetRef ref;
  Object? _signature;
  int _version = 0;
  bool _disposed = false;
  bool Function()? _current;
  PartyReferenceSnapshot _snapshot = const PartyReferenceSnapshot();

  PartyReferenceSnapshot get snapshot =>
      _current?.call() == true ? _snapshot : const PartyReferenceSnapshot();

  void prepare(
    Object signature, {
    required Set<String> clients,
    required Set<String> suppliers,
  }) {
    if (_disposed || signature == _signature) return;
    _signature = signature;
    _snapshot = const PartyReferenceSnapshot();
    final version = ++_version;
    final current = _current = captureReadOwner(ref);
    if (clients.isEmpty && suppliers.isEmpty) return;
    scheduleMicrotask(() => _load(version, current, clients, suppliers));
  }

  Future<void> _load(
    int version,
    bool Function() current,
    Set<String> clients,
    Set<String> suppliers,
  ) async {
    if (_disposed || !current()) return;
    var clientLabels = <String, String>{};
    var supplierLabels = <String, String>{};
    await Future.wait([
      () async {
        if (suppliers.isEmpty) return;
        try {
          final master = ref.read(masterNameServiceProvider);
          await master.loadSupplierNames(suppliers);
          if (!_disposed && current()) {
            supplierLabels = _resolvedLabels(suppliers, master.supplier);
          }
        } catch (_) {
          /* Unproved references remain placeholders. */
        }
      }(),
      () async {
        if (clients.isEmpty) return;
        try {
          final sales = ref.read(salesMasterNameServiceProvider);
          await sales.loadClientNames(clients);
          if (!_disposed && current()) {
            clientLabels = _resolvedLabels(clients, sales.client);
          }
        } catch (_) {
          /* Original input is never rewritten by a failed lookup. */
        }
      }(),
    ]);
    if (_disposed || version != _version || !current()) return;
    _snapshot = PartyReferenceSnapshot(
      clients: Map.unmodifiable(clientLabels),
      suppliers: Map.unmodifiable(supplierLabels),
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_version;
    super.dispose();
  }
}
