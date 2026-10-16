import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/server_operations.dart';

abstract interface class ServerOperationsRepository {
  Future<ServerOperationsStatus> status();
  Future<ServerUpdateJob> startUpdate({
    required String requestId,
    required String expectedSourceRevision,
    required String expectedCurrentVersion,
    String mode = 'CHECK_ONLY',
    String? targetVersion,
    String? scheduledAt,
  });
  Future<ServerUpdateJob> job(String id);
  Future<ServerUpdateJob?> latestJob();
  Future<ServerUpdateSource> source();
  Future<ServerUpdateSource> saveSource(Map<String, dynamic> command);
  Future<ServerUpdateSchedulePreview> schedulePreview({
    required String localDate,
    required int hour,
  });
  Future<ServerUpdateJob> cancel(String jobId, {required String requestId});
}

final serverOperationsRepositoryProvider = Provider<ServerOperationsRepository>(
  (ref) => DioServerOperationsRepository(ref.watch(apiClientProvider)),
);

class DioServerOperationsRepository implements ServerOperationsRepository {
  DioServerOperationsRepository(this.api);
  final ApiClient api;
  static const path = '/admin/server-operations';

  @override
  Future<ServerOperationsStatus> status() async =>
      ServerOperationsStatus.fromJson(await api.get('$path/status'));
  @override
  Future<ServerUpdateJob> startUpdate({
    required String requestId,
    required String expectedSourceRevision,
    required String expectedCurrentVersion,
    String mode = 'CHECK_ONLY',
    String? targetVersion,
    String? scheduledAt,
  }) async {
    final result = ServerUpdateJob.fromJson(
      await api.post(
        mode == 'CHECK_ONLY' ? '$path/updates/check' : '$path/updates',
        body: {
          'requestId': requestId,
          'expectedSourceRevision': expectedSourceRevision,
          'expectedCurrentVersion': expectedCurrentVersion,
          if (mode != 'CHECK_ONLY') 'mode': mode,
          'targetVersion': ?targetVersion,
          'scheduledAt': ?scheduledAt,
        },
      ),
    );
    if (result.requestId != requestId || result.id.isEmpty) {
      throw const FormatException('Invalid update receipt');
    }
    return result;
  }

  @override
  Future<ServerUpdateJob> job(String id) async => ServerUpdateJob.fromJson(
    await api.get('$path/updates/${Uri.encodeComponent(id)}'),
  );
  @override
  Future<ServerUpdateJob?> latestJob() async {
    final response = await api.get('$path/updates/latest');
    return response['job'] == null
        ? null
        : ServerUpdateJob.fromJson(response['job'] as Map<String, dynamic>);
  }

  @override
  Future<ServerUpdateSource> source() async =>
      ServerUpdateSource.fromJson(await api.get('$path/source'));
  @override
  Future<ServerUpdateSource> saveSource(Map<String, dynamic> command) async {
    final result = ServerUpdateSource.fromJson(
      await api.put('$path/source', body: command),
    );
    if (!result.applied || result.revision.isEmpty) {
      throw const FormatException('Server source was not confirmed applied');
    }
    return result;
  }

  @override
  Future<ServerUpdateSchedulePreview> schedulePreview({
    required String localDate,
    required int hour,
  }) async => ServerUpdateSchedulePreview.fromJson(
    await api.post(
      '$path/updates/schedule-preview',
      body: {'localDate': localDate, 'hour': hour},
    ),
  );

  @override
  Future<ServerUpdateJob> cancel(
    String jobId, {
    required String requestId,
  }) async => ServerUpdateJob.fromJson(
    await api.post(
      '$path/updates/${Uri.encodeComponent(jobId)}/cancel',
      body: {'requestId': requestId},
    ),
  );
}
