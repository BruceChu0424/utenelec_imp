import 'package:dio/dio.dart';

/// Runs one operation with a newly owned client, releasing its connection pool
/// on success and failure. Graceful close lets a returned response stream drain.
Future<T> withOwnedDio<T>(
  Dio Function() create,
  Future<T> Function(Dio client) operation,
) async {
  final client = create();
  try {
    return await operation(client);
  } finally {
    client.close();
  }
}
