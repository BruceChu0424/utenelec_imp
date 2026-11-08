import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';

/// Stable 64-hex read proof for workbench fakes. A different [label]
/// simulates a server whose data version moved between two batches.
String workbenchReadProof(String label) =>
    sha256.convert(utf8.encode('workbench-read-$label')).toString();

/// Serves [source] the way the workbench endpoints answer one batch of a
/// complete read: the requested page/size window with the exact row count,
/// the whole result's total, an over-the-end page clamped to the last page,
/// metadata only on the first batch, and the same scope/revision/data-version
/// proof on every batch (V1118). Concurrent complete reads reject batches
/// without these, so fakes return their plain data through this function.
OperationsWorkbenchData workbenchPageSlice(
  OperationsWorkbenchData source,
  int page,
  int size, {
  String revision = 'fixture',
}) {
  if (size < 1) throw ArgumentError.value(size, 'size');
  final rows = source.items;
  final totalPages = rows.isEmpty ? 0 : (rows.length + size - 1) ~/ size;
  final served = totalPages == 0 ? 1 : (page > totalPages ? totalPages : page);
  final first = served == 1;
  return OperationsWorkbenchData(
    department: source.department,
    summary: first && source.metadataIncluded ? source.summary : null,
    items: rows
        .skip((served - 1) * size)
        .take(size)
        .toList(growable: false),
    page: served,
    size: size,
    total: rows.length,
    totalPages: totalPages,
    capabilities: source.capabilities,
    facets: first ? source.facets : const {},
    nullCounts: first ? source.nullCounts : const {},
    metadataIncluded: first && source.metadataIncluded,
    readScopeVersion: source.readScopeVersion ?? 'fixture-scope',
    readSnapshotRevision:
        source.readSnapshotRevision ?? workbenchReadProof(revision),
    readDataVersion:
        source.readDataVersion ?? workbenchReadProof('data-$revision'),
  );
}
