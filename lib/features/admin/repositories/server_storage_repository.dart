import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/server_storage.dart';

abstract interface class ServerStorageRepository {
  Future<ServerStorageSummary> summary();
  Future<ServerStorageResources> resources(String kind, {String? cursor});
  Future<ServerStoragePreview> preview(List<String> resourceIds);
  Future<ServerStorageCleanupReceipt> cleanup({
    required String previewId,
    required String requestId,
  });
  Future<ServerStorageCleanupReceipt> receipt(String requestId);
}

final serverStorageRepositoryProvider = Provider<ServerStorageRepository>(
  (ref) => DioServerStorageRepository(ref.watch(apiClientProvider)),
);

class DioServerStorageRepository implements ServerStorageRepository {
  DioServerStorageRepository(this.api);
  final ApiClient api;
  static const path = '/admin/server-storage';

  @override
  Future<ServerStorageSummary> summary() async =>
      ServerStorageSummary.fromJson(await api.get(path));

  @override
  Future<ServerStorageResources> resources(
    String kind, {
    String? cursor,
  }) async => ServerStorageResources.fromJson(
    await api.get(
      '$path/resources',
      query: {'kind': kind, 'limit': 50, 'cursor': ?cursor},
    ),
  );

  @override
  Future<ServerStoragePreview> preview(List<String> resourceIds) async =>
      ServerStoragePreview.fromJson(
        await api.post(
          '$path/cleanup/preview',
          body: {'resourceIds': resourceIds},
        ),
      );

  @override
  Future<ServerStorageCleanupReceipt> cleanup({
    required String previewId,
    required String requestId,
  }) async {
    final result = ServerStorageCleanupReceipt.fromJson(
      await api.post(
        '$path/cleanup',
        body: {'previewId': previewId, 'requestId': requestId},
      ),
    );
    if (result.requestId != requestId ||
        !const {
          'RUNNING',
          'SUCCEEDED',
          'PARTIAL',
          'FAILED',
          'RECOVERY_REQUIRED',
        }.contains(result.status)) {
      throw const FormatException('Invalid cleanup receipt');
    }
    return result;
  }

  @override
  Future<ServerStorageCleanupReceipt> receipt(String requestId) async {
    final result = ServerStorageCleanupReceipt.fromJson(
      await api.get('$path/cleanup/${Uri.encodeComponent(requestId)}'),
    );
    if (result.requestId != requestId ||
        !const {
          'RUNNING',
          'SUCCEEDED',
          'PARTIAL',
          'FAILED',
          'RECOVERY_REQUIRED',
        }.contains(result.status)) {
      throw const FormatException('Invalid cleanup receipt');
    }
    return result;
  }
}
