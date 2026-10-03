import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';

/// Deterministic durable-record stand-in, including CAS contention and write failures.
class MemoryCasStorage implements FormDraftStorage {
  final records = <String, String>{};
  bool failReads = false;
  bool failWrites = false;
  Future<void>? writeGate;
  @override
  Future<Map<String, String>> readAll(String prefix) async {
    if (failReads) throw StateError('storage read failed');
    return {
      for (final entry in records.entries)
        if (entry.key.startsWith(prefix)) entry.key: entry.value,
    };
  }

  @override
  Future<String?> read(String key) async {
    if (failReads) throw StateError('storage read failed');
    return records[key];
  }

  @override
  Future<void> write(String key, String value) async {
    records[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    records.remove(key);
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    await writeGate;
    if (failWrites) throw StateError('storage write failed');
    if (records[key] != expectedValue) return false;
    if (value == null) {
      records.remove(key);
    } else {
      records[key] = value;
    }
    return true;
  }
}
