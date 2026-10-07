import 'form_draft_history.dart';

export 'form_draft_history.dart';

/// Per-record durable storage. No shared read/modify/write list across tabs.
abstract class FormDraftStorage {
  Future<Map<String, String>> readAll(String prefix);
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);

  /// Compare and mutate in one durable transaction, including across tabs or
  /// application processes. Null expectedValue creates. A null value removes
  /// generic values; real drafts retain an immutable history and terminal marker.
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  });
}

/// Durable metadata seek index, separate from potentially large form payloads.
/// Callers must recheck current permissions before exposing an entry or record.
abstract interface class FormDraftHistoryStorage {
  Future<FormDraftHistoryPage> readHistoryPage(
    String prefix, {
    String? before,
    int limit = 30,
  });
  Future<FormDraftHistoryRecord?> readHistoryRecord(String prefix, String id);
}

/// Storage implementations with a persistent connection can release it without
/// deleting committed drafts. Reopening must read the same durable records.
abstract interface class ClosableFormDraftStorage {
  Future<void> close();
}

/// The server's committed reset generation is monotonic. Reset cleanup also
/// removes retained draft history; normal draft deletion still keeps history.
abstract interface class BusinessResetFormDraftStorage {
  Future<void> synchronizeBusinessReset(String ownerPrefix, int generation);
}

({String owner, int generation})? formDraftResetScope(String prefix) {
  final match = RegExp(
    r'^(?:daily_report_approval_)?([a-f0-9]{64}_)(?:g([1-9][0-9]*)_)?$',
  ).firstMatch(prefix);
  if (match == null) return null;
  return (owner: match[1]!, generation: int.parse(match[2] ?? '0'));
}

void validateFormDraftReset(String ownerPrefix, int generation) {
  if (!RegExp(r'^[a-f0-9]{64}_$').hasMatch(ownerPrefix) || generation < 0) {
    throw const FormatException('草稿清空标识无效');
  }
}
