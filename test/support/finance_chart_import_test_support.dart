import 'versioned_summary_test_response.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'finance_command_test_support.dart';

// Server preview UUIDs may retain non-RFC version bits; client intents stay V4.
const financeChartImportTestRoot = '00000000-0000-0000-0000-000000000801';
const financeChartImportTestChild = '00000000-0000-0000-0000-000000000802';
final financeChartImportTestBytes = Uint8List.fromList(
  utf8.encode('anonymous-original-chart-bytes'),
);
final financeChartImportTestSha = crypto.sha256
    .convert(financeChartImportTestBytes)
    .toString();
const _root = financeChartImportTestRoot, _child = financeChartImportTestChild;
final _sha = financeChartImportTestSha;

/// One preview wire shape used by direct directory fakes and Dio transport tests.
Map<String, dynamic> financeChartImportTestPreview({
  String importId = financeChartImportTestRoot,
  String sourceName = '原始目录.xls',
  String? sha256,
  String? parentImportId,
  String sourceImportId = financeChartImportTestRoot,
  int? existingVersion,
  List<Map<String, dynamic>>? rows,
}) => {
  'importId': importId,
  'sourceName': sourceName,
  'sha256': sha256 ?? financeChartImportTestSha,
  'rows':
      rows ??
      [
        {
          'code': '1001',
          'name': '原件字面科目名称',
          'currencyName': '',
          'sourceRow': 1,
          'existingVersion': ?existingVersion,
        },
      ],
  'issues': <Object>[],
  'applied': false,
  'cancelled': false,
  'applyOutcome': null,
  'parentImportId': parentImportId,
  'sourceImportId': sourceImportId,
};

class FinanceChartImportTestSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    status: AuthStatus.authenticated,
    user: AppUser(id: financeCommandTestActor, code: 'fixture', name: '匿名测试人员'),
  );
}

class FinanceChartImportTestCall {
  FinanceChartImportTestCall(this.method, this.path, this.body);
  final String method, path;
  final Map<String, dynamic> body;
}

class FinanceChartImportTestTransport implements HttpClientAdapter {
  bool uploaded = false,
      loseUpload = false,
      loseApply = true,
      rejectApply = false,
      loseReview = false,
      loseCancel = false,
      lookupMissing = false,
      forbidRead = false;
  bool wrongReview = false;
  Completer<void>? holdApply;
  int uploads = 0,
      applied = 0,
      reviews = 0,
      currentVersion = 5,
      rootVersion = 5;
  String storedName = '原始目录.xls';
  final calls = <FinanceChartImportTestCall>[],
      applyCalls = <FinanceChartImportTestCall>[],
      reviewCalls = <FinanceChartImportTestCall>[];
  final applyReceipts = <String, Map<String, dynamic>>{},
      reviewReceipts = <String, Map<String, dynamic>>{};
  final previews = <String, Map<String, dynamic>>{};
  void Function()? beforeUpload;
  Map<String, dynamic>? Function(String path)? readExtra;
  Map<String, dynamic> preview(String id) => previews.putIfAbsent(
    id,
    () => financeChartImportTestPreview(
      importId: id,
      sourceName: storedName,
      parentImportId: id == _root ? null : _root,
      existingVersion: id == _root ? rootVersion : currentVersion,
    ),
  );
  ResponseBody json(Object? value, [int status = 200]) =>
      ResponseBody.fromString(
        jsonEncode(value),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
  Map<String, dynamic> proof(
    FinanceChartImportTestCall call,
    String operation,
    Object result, {
    bool stopped = false,
  }) => financeCommandTestReceipt(
    operation: operation,
    method: 'POST',
    path: call.path,
    body: call.body,
    result: result,
    identityField: operation == 'CHART_IMPORT_APPLY' ? 'importId' : 'requestId',
    outcome: stopped ? 'CANCELLED_UNWRITTEN' : 'SUCCEEDED',
  );
  // Flutter SDK expectSync preserves the exact matcher inside asynchronous
  // user-input completion callbacks, without a conflicting WidgetTester guard.
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? stream,
    Future<void>? cancel,
  ) async {
    final bytes = stream == null
        ? <int>[]
        : await stream.expand((chunk) => chunk).toList();
    final body = o.data is FormData || bytes.isEmpty
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    final call = FinanceChartImportTestCall(o.method, o.path, body);
    calls.add(call);
    if (o.path == '/finance/chart/import-preview' && o.method == 'POST') {
      uploads++;
      beforeUpload?.call();
      uploaded = true;
      preview(_root);
      if (loseUpload) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.receiveTimeout,
        );
      }
      return json(preview(_root));
    }
    if (o.method == 'GET') {
      if (forbidRead && o.path.contains('/finance/chart/import')) {
        return json({'code': 'FORBIDDEN', 'message': '读取权限已撤销'}, 403);
      }
      if (o.path == '/finance/chart/imports/by-sha/$_sha') {
        return json(
          !uploaded || lookupMissing
              ? {'found': false}
              : {
                  'found': true,
                  'importId': _root,
                  'sha256': _sha,
                  'sourceName': storedName,
                  'storageSize': financeChartImportTestBytes.length,
                  'applied': preview(_root)['applied'],
                  'cancelled': preview(_root)['cancelled'],
                },
        );
      }
      if (o.path.endsWith('/operations/apply')) {
        return json(applyReceipts[o.path.split('/')[4]] ?? {'found': false});
      }
      if (o.path.startsWith('/finance/chart/operations/')) {
        return json(reviewReceipts[o.path.split('/').last] ?? {'found': false});
      }
      if (o.path == '/finance/chart/imports/summaries') {
        return json(
          versionedSummaryTestResponse([
            if (uploaded)
              {
                'importId': _root,
                'sourceName': storedName,
                'applied': preview(_root)['applied'],
                'cancelled': preview(_root)['cancelled'],
              },
          ], o.queryParameters),
        );
      }
      if (o.path == '/finance/chart/imports/$_root') {
        return json(preview(_root));
      }
      if (o.path == '/finance/chart/imports/$_child') {
        return json(preview(_child));
      }
      final extra = readExtra?.call(o.path);
      if (extra != null) return json(extra);
      return json({
        'items': <Object>[],
        'total': 0,
        'page': 1,
        'size': 100,
        'totalPages': 0,
      });
    }
    if (o.path.endsWith('/cancel')) {
      final original = Map<String, dynamic>.from(body['requestBody'] as Map);
      final apply = body['operation'] == 'CHART_IMPORT_APPLY';
      final id = original[apply ? 'importId' : 'requestId'] as String;
      final stored = apply ? applyReceipts : reviewReceipts;
      expectSync(body['requestId'], id);
      expectSync(body['actorId'], financeCommandTestActor);
      final originalCall = FinanceChartImportTestCall(
        'POST',
        body['path'] as String,
        original,
      );
      final response = stored.putIfAbsent(
        id,
        () => proof(originalCall, body['operation'] as String, {
          'cancelled': true,
        }, stopped: true),
      );
      if (apply && response['outcome'] == 'CANCELLED_UNWRITTEN') {
        preview(id)['cancelled'] = true;
        preview(id)['applyOutcome'] = 'CANCELLED_UNWRITTEN';
      }
      if (loseCancel) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.receiveTimeout,
        );
      }
      return json(response);
    }
    if (o.path == '/finance/chart/import-apply') {
      applyCalls.add(call);
      expectSync(body.keys, ['importId']);
      final id = body['importId'] as String;
      if (holdApply != null) await holdApply!.future;
      if (applyReceipts[id] != null) {
        return json(applyReceipts[id]);
      }
      if (rejectApply) {
        return json({'code': 'CONFLICT', 'message': '原预览版本已过期'}, 409);
      }
      applied++;
      preview(id)['applied'] = true;
      preview(id)['applyOutcome'] = 'SUCCEEDED';
      final response = proof(call, 'CHART_IMPORT_APPLY', {
        'importId': id,
        'imported': 1,
        'status': 'APPLIED',
      });
      applyReceipts[id] = response;
      if (loseApply) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.receiveTimeout,
        );
      }
      return json(response);
    }
    if (o.path == '/finance/chart/imports/$_root/repreview') {
      reviewCalls.add(call);
      expectSync(body.keys, ['requestId']);
      final id = body['requestId'] as String;
      if (reviewReceipts[id] != null) {
        return json(reviewReceipts[id]);
      }
      reviews++;
      preview(_child);
      final response = proof(call, 'CHART_IMPORT_REPREVIEW', {
        'requestId': id,
        'importId': _child,
        'parentImportId': wrongReview
            ? '00000000-0000-0000-0000-000000000899'
            : _root,
        'sourceImportId': _root,
        'sha256': _sha,
        'status': 'PREVIEWED',
      });
      reviewReceipts[id] = response;
      if (loseReview) {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.receiveTimeout,
        );
      }
      return json(response);
    }
    return json({});
  }

  @override
  void close({bool force = false}) {}
}
