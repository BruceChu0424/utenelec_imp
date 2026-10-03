/// Point reads and durable compare-and-set writes. There is deliberately no
/// delete or age-pruning API. Replaced values remain in the private archive.
abstract interface class DeviceAuditReceiptStorage {
  Future<T> initialize<T>(Future<T> Function() action);

  Future<String?> read(String key);

  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String value,
  });
}
