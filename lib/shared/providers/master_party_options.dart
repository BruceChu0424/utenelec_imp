import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/ui/app_notification.dart';
import '../../features/basic_data/models/master_facet.dart';
import '../../features/basic_data/repositories/client_repository.dart';
import '../../features/basic_data/repositories/supplier_repository.dart';
import '../../features/basic_data/widgets/uten_client_picker.dart';
import '../auth/permissions.dart';
import 'export_context_epoch_provider.dart';

/// Complete candidate pages are separate from the bounded cache of referenced party names.
/// Historical filters include disabled parties; write selectors use the existing master picker.
MasterFacetColumnLoader clientPartyFacetLoader(
  WidgetRef ref, {
  bool excludeLegacyFinanceStub = true,
}) => (keyword, page) async {
  final context = ref.context;
  final epoch = ref.read(exportContextEpochProvider);
  final api = ref.read(apiClientProvider);
  final result = await ref
      .read(clientRepositoryProvider)
      .search(
        keyword,
        page: page,
        size: 100,
        excludeLegacyFinanceStub: excludeLegacyFinanceStub,
      );
  if (!context.mounted ||
      epoch != ref.read(exportContextEpochProvider) ||
      !identical(api, ref.read(apiClientProvider))) {
    throw StateError('客户筛选读取作用域已变化');
  }
  return MasterFacetPage(
    items: [
      for (final party in result.items)
        MasterFacetBucket(
          value: party.id,
          label: clientPickerLabel(party),
          count: 0,
        ),
    ],
    hasMore: result.page < result.totalPages,
  );
};

MasterFacetColumnLoader supplierPartyFacetLoader(WidgetRef ref) =>
    (keyword, page) async {
      final context = ref.context;
      final epoch = ref.read(exportContextEpochProvider);
      final api = ref.read(apiClientProvider);
      final result = await ref
          .read(supplierRepositoryProvider)
          .search(keyword, page: page, size: 100);
      if (!context.mounted ||
          epoch != ref.read(exportContextEpochProvider) ||
          !identical(api, ref.read(apiClientProvider))) {
        throw StateError('供应商筛选读取作用域已变化');
      }
      return MasterFacetPage(
        items: [
          for (final party in result.items)
            MasterFacetBucket(
              value: party.id,
              label: party.name?.trim().isNotEmpty == true
                  ? party.name!.trim()
                  : party.description?.trim().isNotEmpty == true
                  ? party.description!.trim()
                  : party.id,
              count: 0,
            ),
        ],
        hasMore: result.page < result.totalPages,
      );
    };

/// Searching both party domains preserves each existing UUID filter contract.
MasterFacetColumnLoader combinedPartyFacetLoader(
  WidgetRef ref, {
  bool excludeLegacyFinanceStub = true,
}) => (keyword, page) async {
  final context = ref.context;
  final epoch = ref.read(exportContextEpochProvider);
  final permissions = ref.read(currentPermissionsProvider);
  final results = await Future.wait([
    if (permissions.contains(Perm.clientView))
      clientPartyFacetLoader(
        ref,
        excludeLegacyFinanceStub: excludeLegacyFinanceStub,
      )(keyword, page),
    if (permissions.contains(Perm.supplierView))
      supplierPartyFacetLoader(ref)(keyword, page),
  ]);
  if (!context.mounted || epoch != ref.read(exportContextEpochProvider)) {
    throw StateError('往来方筛选读取作用域已变化');
  }
  return MasterFacetPage(
    items: [for (final result in results) ...result.items],
    hasMore: results.any((result) => result.hasMore),
  );
};

/// Monotonic identity/server/permission epoch also invalidates an A→B→A request.
Object partyFacetSearchScope(WidgetRef ref, Object namespace) =>
    (ref.watch(exportContextEpochProvider), namespace);

Set<String> partyReferenceIds(Iterable<String?> ids) => {
  for (final id in ids)
    if (id != null && id.isNotEmpty && id != kMasterFilterNullValue) id,
};

/// A form result belongs to the reader that opened it, including A→B→A.
/// Preserve the user's local input while open; never return it as another reader's command.
Future<T?> guardPartyPanelResult<T>(
  BuildContext context,
  Future<T?> Function() open,
) async {
  final container = ProviderScope.containerOf(context, listen: false);
  var observedEpoch = container.read(exportContextEpochProvider);
  final epoch = observedEpoch;
  // Keep the monotonic source observed even when this modal is its only reader.
  // A lazy read after A→B→A cannot reconstruct the intermediate identity.
  final subscription = container.listen(exportContextEpochProvider, (_, next) {
    observedEpoch = next;
  });
  try {
    final result = await open();
    if (!context.mounted) return null;
    if (observedEpoch != epoch ||
        !identical(container, ProviderScope.containerOf(context, listen: false))) {
      if (result != null) context.appError('登录身份或读取范围已变化，请重新打开面板');
      return null;
    }
    return result;
  } finally {
    subscription.close();
  }
}

/// Keep a restored exact selection readable without enumerating the reference cache as candidates.
List<MasterFacetBucket> selectedPartyFacet(
  String? id,
  String? Function(String id) nameOf,
) {
  if (id == null || id.isEmpty) return const [];
  if (id == kMasterFilterNullValue) {
    return const [
      MasterFacetBucket(value: kMasterFilterNullValue, label: '(空)', count: 0),
    ];
  }
  final name = nameOf(id);
  return [
    MasterFacetBucket(
      value: id,
      label: name == null || name.isEmpty || name == '—' ? '已选择' : name,
      count: 0,
    ),
  ];
}

/// Resolve only the selected UUID before a form freezes its display/default reference.
Future<T?> resolvePickedParty<T>(
  WidgetRef ref,
  Future<T?> Function() pick, {
  required String Function(T value) idOf,
  required Future<void> Function(Iterable<String> ids) loadNames,
  required bool Function(String id) isResolved,
  bool Function()? isCurrent,
}) async {
  final context = ref.context;
  final epoch = ref.read(exportContextEpochProvider);
  bool current() =>
      context.mounted &&
      epoch == ref.read(exportContextEpochProvider) &&
      (isCurrent?.call() ?? true);
  if (!current()) return null;
  final selected = await pick();
  if (selected == null || !current()) return null;
  try {
    await loadNames([idOf(selected)]);
  } catch (_) {
    if (context.mounted && current()) {
      context.appError('暂时无法读取往来方信息，请重试');
    }
    return null;
  }
  if (!current()) return null;
  if (!isResolved(idOf(selected))) {
    if (context.mounted) {
      context.appError('往来方信息不可用或无权访问，请重新选择');
    }
    return null;
  }
  return current() ? selected : null;
}
