import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/authenticated_request_scope.dart';
import '../../core/io/file_saver.dart';
import 'master_export_job.dart';
import 'supplemental_export_job.dart';

/// Exact registered adapters share job transport while retaining their own
/// server-side permission, projection and source contracts.
String? reportExportJobDomain(String endpoint) {
  final supplemental = supplementalExportJobDomain(endpoint);
  if (supplemental != null) return supplemental;
  if (masterExportJobReport(endpoint) != null) return 'master';
  final workbench = RegExp(
    r'^/operations/workbench/(purchase|subcontract)/export$',
  ).firstMatch(endpoint);
  if (workbench != null) return 'workbench_${workbench.group(1)}';
  if (endpoint == '/production/reports/where-used/export') return 'where_used';
  final match = RegExp(
    r'^/(sales|purchase|subcontract|production|stock|finance)/reports/export$',
  ).firstMatch(endpoint);
  return match?.group(1);
}

class ReportExportJobRequest {
  ReportExportJobRequest._(this.json);

  factory ReportExportJobRequest.create({
    required String domain,
    required String report,
    required Map<String, dynamic> parameters,
    Map<String, dynamic>? columnProjection,
    String? id,
    String format = 'xlsx',
  }) => ReportExportJobRequest.fromJson({
    'id': id ?? const Uuid().v4(),
    'domain': domain,
    'report': report,
    'format': format,
    'parameters': {
      for (final entry in parameters.entries)
        if (!const {
          'password',
          'sort',
          'order',
          'report',
          'page',
          'size',
          'includeCount',
          'includeFacets',
          'includeTotals',
        }.contains(entry.key))
          entry.key: entry.value,
    },
    if (parameters['sort'] != null) 'sort': parameters['sort'],
    if (parameters['order'] != null) 'order': parameters['order'],
    'columnProjection': ?columnProjection,
  });

  factory ReportExportJobRequest.fromJson(Map<String, dynamic> value) {
    // Freeze the small query/projection before any dialog or network await.
    final frozen = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
    frozen.remove('password');
    frozen.putIfAbsent('format', () => 'xlsx');
    (frozen['parameters'] as Map?)?.remove('password');
    return ReportExportJobRequest._(Map.unmodifiable(frozen));
  }

  final Map<String, dynamic> json;
  String get id => json['id'] as String;
  String get domain => json['domain'] as String;
  String get report => json['report'] as String;
  String get format => json['format'] as String;
}

class ReportExportJob {
  ReportExportJob.fromJson(Map<String, dynamic> json)
    : id = json['id'] as String,
      domain = json['domain'] as String,
      report = json['report'] as String,
      format = json['format'] as String? ?? 'xlsx',
      status = json['status'] as String,
      cancelRequested = json['cancelRequested'] == true,
      rows = (json['rows'] as num?)?.toInt() ?? 0,
      bytes = (json['bytes'] as num?)?.toInt() ?? 0,
      snapshotAt = json['snapshotAt']?.toString(),
      createdAt = json['createdAt']?.toString(),
      error = json['error']?.toString();

  final String id;
  final String domain;
  final String report;
  final String format;
  final String status;
  final bool cancelRequested;
  final int rows;
  final int bytes;
  final String? snapshotAt;
  final String? createdAt;
  final String? error;

  bool get active => status == 'PENDING' || status == 'RUNNING';
  bool get downloadable => status == 'SUCCEEDED';
  String get statusLabel => active && cancelRequested
      ? '正在取消'
      : switch (status) {
          'PENDING' => '等待生成',
          'RUNNING' => '正在生成',
          'SUCCEEDED' => '已生成',
          'FAILED' => '生成失败',
          'CANCELLED' => '已取消',
          'EXPIRED' => '文件已过期',
          _ => '状态待核查',
        };
}

/// Every request retains the original authenticated command scope. A create
/// timeout is returned to the caller with its original ID; it is never retried
/// automatically with a fresh identity or a different job ID.
class ReportExportJobsClient {
  ReportExportJobsClient(this.api, this.scope);
  final ApiClient api;
  final AuthenticatedRequestScope scope;
  static const base = '/report-export-jobs';

  Future<bool> available() async {
    try {
      final response = await scope.run(() => api.get('$base/capabilities'));
      await scope.verify();
      return response['available'] == true;
    } on ApiException catch (error) {
      if (error.httpStatus == 404) return false; // Previous server version.
      rethrow;
    }
  }

  Future<ReportExportJob> create(ReportExportJobRequest request) async {
    final response = await scope.run(() => api.post(base, body: request.json));
    await scope.verify();
    return ReportExportJob.fromJson(response);
  }

  Future<ReportExportJob> read(String id) async {
    final response = await scope.run(() => api.get('$base/$id'));
    await scope.verify();
    return ReportExportJob.fromJson(response);
  }

  Future<List<ReportExportJob>> recent() async {
    final response = await scope.run(() => api.getList(base));
    await scope.verify();
    return response.map(ReportExportJob.fromJson).toList(growable: false);
  }

  Future<ReportExportJob> cancel(String id) async {
    await scope.run(() => api.post('$base/$id/cancel'));
    return read(id);
  }

  Future<Uint8List> download(String id, String password) async {
    final bytes = await scope.run(
      () =>
          api.downloadBytes('$base/$id/download', body: {'password': password}),
    );
    await scope.verify();
    await verifyDownload(id);
    return bytes;
  }

  Future<void> verifyDownload(String id) async {
    final response = await scope.run(
      () => api.get('$base/$id/download-authorization'),
    );
    await scope.verify();
    if (response['authorized'] != true) {
      throw ApiException('FORBIDDEN', '文件接收权限无法确认，请核查原任务', httpStatus: 403);
    }
  }

  /// Null means the caller must use its explicitly bounded compatibility path.
  Future<String?> downloadToFile(
    String id,
    String password,
    String filename, {
    required bool Function() stillCurrent,
  }) async {
    if (!api.streamingDownloads || !await canSaveStream()) return null;
    await scope.verify();
    try {
      return await scope.run(
        () => saveStream(
          api.downloadExportStream(
            '$base/$id/download',
            body: {'password': password},
            stillCurrent: () => stillCurrent() && scope.isCurrent,
          ),
          filename,
          stillCurrent: () => stillCurrent() && scope.isCurrent,
          verifyScope: () => verifyDownload(id),
        ),
      );
    } on ApiException {
      rethrow;
    } on StateError catch (error) {
      throw ApiException('FILE_SAVE_FAILED', error.message.toString());
    } catch (_) {
      throw ApiException('FILE_SAVE_FAILED', '文件保存未完成，请检查可用空间后重试原任务');
    }
  }
}

/// Only an unresolved create request is retained. Passwords never enter this
/// store. Its server/session/impersonation namespace cannot adopt another
/// reader's request; the server still authorizes every lookup and download.
class ReportExportPendingStore {
  ReportExportPendingStore(
    this.preferences,
    AuthenticatedRequestIdentity identity,
    String domain,
    String report, {
    String format = 'xlsx',
  }) : key =
           'report-export.pending.${sha256.convert(utf8.encode(jsonEncode([identity.baseUrl, identity.lineage, identity.intent, identity.impersonationLineage, domain, report, if (format != 'xlsx') format])))}';

  final SharedPreferences preferences;
  final String key;

  ReportExportJobRequest? read() {
    final value = preferences.getString(key);
    if (value == null) return null;
    return ReportExportJobRequest.fromJson(
      jsonDecode(value) as Map<String, dynamic>,
    );
  }

  Future<void> save(ReportExportJobRequest request) async {
    if (!await preferences.setString(key, jsonEncode(request.json))) {
      throw StateError('无法保留导出任务编号，请稍后重试');
    }
  }

  Future<void> resolve(String id) async {
    if (read()?.id == id && !await preferences.remove(key)) {
      throw StateError('无法更新导出任务记录，请稍后重试');
    }
  }
}
