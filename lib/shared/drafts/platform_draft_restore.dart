import '../platform_tables/platform_row_draft.dart';

const platformDraftRestoreFormatError = '草稿扩展字段格式无法核对，原草稿保留';

/// Association is supplied only after the host verifies its row codec or manifest.
class PlatformDraftRestoreTarget {
  const PlatformDraftRestoreTarget(this.target, this.snapshot);
  final PlatformRowDraft target;
  final Object? snapshot;
}

/// A later malformed row must not replace any earlier in-memory user input.
/// Parsing never changes targets; only a completely prepared set is published.
void restorePlatformDraftsAtomically(
  Iterable<PlatformDraftRestoreTarget> rows,
) {
  final prepared = <PlatformRowDraft, PlatformRowDraft>{};
  try {
    for (final row in rows) {
      if (row.snapshot == null) continue;
      if (row.snapshot is! Map || prepared.containsKey(row.target)) {
        throw StateError(platformDraftRestoreFormatError);
      }
      final parsed = PlatformRowDraft();
      prepared[row.target] = parsed;
      parsed.restoreDraft(row.snapshot);
    }
    for (final entry in prepared.entries) {
      entry.key.restoreDraft(entry.value.exportDraft());
    }
  } finally {
    for (final parsed in prepared.values) {
      parsed.dispose();
    }
  }
}
