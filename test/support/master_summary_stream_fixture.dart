import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/summary_stream_contract.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart'
    show CompleteReadBatchPlan;
import 'package:uten_imp/shared/paging/complete_summary_stream.dart'
    show kProgressiveSummaryStreamSize;

import 'versioned_summary_test_response.dart';
export 'package:uten_imp/shared/paging/complete_summary_stream.dart'
    show kProgressiveSummaryStreamSize;
export 'versioned_summary_test_response.dart' show masterSummaryTestParameters;

const _scope =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _revision =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _dataVersion =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';

/// Validate the actual Dio request without rewriting its transport or filter.
/// `size` selects the frame plan exactly as the server does: 100 keeps the
/// original fixed frames, [kProgressiveSummaryStreamSize] the 50→200 ladder.
void _validateRequest(RequestOptions request) {
  final parameters = masterSummaryTestParameters(request);
  final acceptsStream = request.headers.entries.any(
    (entry) =>
        entry.key.toLowerCase() == 'accept' &&
        entry.value == summaryStreamContentType,
  );
  if (!isSummaryStreamPath(request.path) ||
      request.queryParameters['complete'] != true ||
      request.responseType != ResponseType.stream ||
      request.extra[summaryStreamRequestKey] != true ||
      !acceptsStream ||
      parameters['page'] != 1 ||
      (parameters['size'] != 100 &&
          parameters['size'] != kProgressiveSummaryStreamSize) ||
      request.queryParameters.containsKey('readSnapshotRevision')) {
    throw StateError('Expected one bounded complete-summary NDJSON request');
  }
}

/// All original rows appear once. Every frame is the exact bounded page the
/// shared plan places at the rows already sent (the server's own framing),
/// followed by a complete marker and a real stream EOF rather than a legacy
/// JSON response.
List<Map<String, dynamic>> masterSummaryStreamTestFrames(
  List<Map<String, dynamic>> items,
  RequestOptions request,
) {
  _validateRequest(request);
  final plan =
      masterSummaryTestParameters(request)['size'] ==
          kProgressiveSummaryStreamSize
      ? CompleteReadBatchPlan.progressive
      : const CompleteReadBatchPlan.fixed(100);
  final frames = <Map<String, dynamic>>[];
  var offset = 0;
  do {
    final size = plan.sizeAt(offset);
    frames.add({
      'type': 'page',
      'value': versionedSummaryTestResponse(
        items,
        {'page': offset ~/ size + 1, 'size': size},
        scopeVersion: _scope,
        revision: _revision,
        dataVersion: _dataVersion,
      ),
    });
    offset += size;
  } while (offset < items.length);
  return [
    ...frames,
    {
      'type': 'complete',
      'total': items.length,
      'readScopeVersion': _scope,
      'readSnapshotRevision': _revision,
      'readDataVersion': _dataVersion,
    },
  ];
}

ResponseBody masterSummaryStreamTestResponse(
  List<Map<String, dynamic>> items,
  RequestOptions request,
) => ResponseBody(
  Stream<Uint8List>.fromIterable(
    masterSummaryStreamTestFrames(
      items,
      request,
    ).map((frame) => Uint8List.fromList(utf8.encode('${jsonEncode(frame)}\n'))),
  ),
  200,
  headers: {
    Headers.contentTypeHeader: ['$summaryStreamContentType; charset=utf-8'],
    'X-Uten-Read-Scope-Version': [_scope],
  },
);

/// Dio interceptor fixtures must carry the stream headers themselves because
/// handler.resolve bypasses the adapter's ResponseBody-to-Response conversion.
Response<dynamic> masterSummaryStreamTestInterceptResponse(
  List<Map<String, dynamic>> items,
  RequestOptions request,
) {
  final body = masterSummaryStreamTestResponse(items, request);
  return Response<dynamic>(
    requestOptions: request,
    statusCode: body.statusCode,
    headers: Headers.fromMap(body.headers),
    data: body,
  );
}

class MasterSummaryStreamTestAdapter implements HttpClientAdapter {
  MasterSummaryStreamTestAdapter(this.rows);

  final FutureOr<List<Map<String, dynamic>>> Function(RequestOptions) rows;
  final calls = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    _validateRequest(options);
    calls.add(options);
    return masterSummaryStreamTestResponse(await rows(options), options);
  }

  @override
  void close({bool force = false}) {}
}

/// API doubles keep business overrides, while summary reads execute the real
/// ApiClient/Dio/NDJSON path. Only the authorized fixture row set is supplied.
abstract class MasterSummaryStreamTestApi extends ApiClient {
  MasterSummaryStreamTestApi()
    : this._(Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api')));

  MasterSummaryStreamTestApi._(Dio dio) : super(dio) {
    _adapter = MasterSummaryStreamTestAdapter(masterSummaryRows);
    dio.httpClientAdapter = _adapter;
  }

  late final MasterSummaryStreamTestAdapter _adapter;
  List<RequestOptions> get summaryStreamRequests => _adapter.calls;

  FutureOr<List<Map<String, dynamic>>> masterSummaryRows(
    RequestOptions request,
  );
}
