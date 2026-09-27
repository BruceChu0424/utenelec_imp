/// Per-record durable storage. No shared read/modify/write list across tabs.
abstract class FormDraftStorage {
  Future<Map<String, String>> readAll(String prefix);
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);

  /// Compare and mutate in one durable transaction, including across tabs or
  /// application processes. A null value deletes; null expectedValue creates.
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  });
}

/// Storage implementations with a persistent connection can release it without
/// deleting committed drafts. Reopening must read the same durable records.
abstract interface class ClosableFormDraftStorage {
  Future<void> close();
}
