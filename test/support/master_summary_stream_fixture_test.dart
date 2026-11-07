import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/repositories/master_summary_read.dart';

import 'master_summary_stream_fixture.dart';

class _Api extends MasterSummaryStreamTestApi {
  _Api(this.rows);
  final List<Map<String, dynamic>> rows;

  @override
  List<Map<String, dynamic>> masterSummaryRows(RequestOptions request) => rows;
}

Future<List<Map<String, dynamic>>> _read(ApiClient api) async =>
    (await readCompleteMasterSummary<Map<String, dynamic>>(
      api,
      path: '/business-references/clients/summaries',
      filter: const {'selectableOnly': true},
      decode: (row) => row,
      idOf: (row) => row['id'],
    )).items;

class _FaultyAdapter implements HttpClientAdapter {
  _FaultyAdapter(this.fault);
  final String fault;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final frames = masterSummaryStreamTestFrames([
      {'id': 'client-1', 'name': '原始客户'},
    ], options);
    if (fault == 'missing complete') frames.removeLast();
    if (fault == 'trailing frame') frames.add({'type': 'complete'});
    return ResponseBody.fromString(
      '${frames.map(jsonEncode).join('\n')}\n',
      200,
      headers: {
        Headers.contentTypeHeader: [
          fault == 'wrong MIME' ? 'application/json' : 'application/x-ndjson',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('real Dio summary keeps all 201 rows over one HTTP response', () async {
    final rows = [
      for (var i = 0; i < 201; i++)
        {
          'id': 'client-$i',
          'name': '原始客户$i',
          'amountExact': '90071992547409.1234567890123456789',
        },
    ];
    final api = _Api(rows);
    expect(await _read(api), rows);
    expect(api.summaryStreamRequests, hasLength(1));
    final request = api.summaryStreamRequests.single;
    expect(request.queryParameters, {'complete': true});
    expect(masterSummaryTestParameters(request)['selectableOnly'], isTrue);
    final frames = masterSummaryStreamTestFrames(rows, request);
    expect(frames, hasLength(4));
    expect(
      frames
          .take(3)
          .map((frame) => ((frame['value'] as Map)['items'] as List).length),
      [100, 100, 1],
    );
    expect(frames.last['total'], 201);
  });

  test('empty result still completes a real bounded page and EOF', () async {
    final api = _Api([]);
    expect(await _read(api), isEmpty);
    expect(api.summaryStreamRequests, hasLength(1));
    final frames = masterSummaryStreamTestFrames(
      [],
      api.summaryStreamRequests.single,
    );
    expect(frames.map((frame) => frame['type']), ['page', 'complete']);
    expect((frames.first['value'] as Map)['totalPages'], 0);
    expect(frames.last['total'], 0);
  });

  for (final fault in ['missing complete', 'trailing frame', 'wrong MIME']) {
    test(
      'real API rejects $fault rather than accepting a fixture map',
      () async {
        final dio = Dio(BaseOptions(baseUrl: 'https://fixture.invalid/api'))
          ..httpClientAdapter = _FaultyAdapter(fault);
        addTearDown(() => dio.close(force: true));
        await expectLater(
          _read(ApiClient(dio)),
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'INCOMPLETE_READ_PROTOCOL',
            ),
          ),
        );
      },
    );
  }
}
