import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/export/report_export_jobs.dart';

/// Caller-level wire evidence only: capture the real shared download request,
/// then stop before any file saver receives bytes.
class OutputSelectionWireApi extends ApiClient {
  static const capabilitiesPath = '${ReportExportJobsClient.base}/capabilities';
  OutputSelectionWireApi()
    : super(Dio(BaseOptions(baseUrl: 'https://wire.invalid/api')));
  final capabilityReads = <String>[];
  final downloads = <({String path, Map<String, dynamic> body})>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == capabilitiesPath) {
      capabilityReads.add(path);
      return {'available': false, 'selectionVersion': 1};
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => [];

  @override
  Future<Uint8List> downloadBytes(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    ProgressCallback? onReceiveProgress,
    Map<String, String>? headers,
  }) async {
    downloads.add((
      path: path,
      body: jsonDecode(jsonEncode(body)) as Map<String, dynamic>,
    ));
    throw StateError(
      'Synthetic wire capture completed; no artifact bytes or file writes',
    );
  }
}
