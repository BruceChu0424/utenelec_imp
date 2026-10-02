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
