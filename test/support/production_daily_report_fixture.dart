import 'package:dio/dio.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';

/// These task fixtures contain no server report drafts. A dedicated complete
/// empty page is explicit, without changing the global API or command mocks.
Override emptyServerReportDraftsFixture({
  void Function(List<String> ids)? onRead,
}) => productionDailyReportRepositoryProvider.overrideWithValue(
  ProductionDailyReportRepository(_NoReportDraftsApi(onRead)),
);

class _NoReportDraftsApi extends ApiClient {
  _NoReportDraftsApi(this.onRead) : super(Dio());
  final void Function(List<String> ids)? onRead;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => throw StateError('Unexpected task-fixture report read: $path');
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    if (path != '/production/daily-reports/draft-claims/query') {
      throw StateError('Unexpected task-fixture command/read: $path');
    }
    final request = body! as Map<String, dynamic>;
    onRead?.call((request['executionSegmentIds'] as List).cast<String>());
    return {
      'items': <Map<String, dynamic>>[],
      'page': request['page'],
      'size': request['size'],
      'total': 0,
      'totalPages': 0,
    };
  }
}
