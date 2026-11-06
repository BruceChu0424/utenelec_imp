import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/paging/complete_summary_stream.dart';
import 'package:uten_imp/shared/paging/versioned_summary_read.dart';

Map<String, dynamic> _page(int page, int total) => {
  'page': page,
  'size': 100,
  'total': total,
  'totalPages': (total + 99) ~/ 100,
  'readScopeVersion': 'a' * 64,
  'readSnapshotRevision': 'b' * 64,
  'readDataVersion': 'c' * 64,
  'items': [
    for (var i = (page - 1) * 100; i < page * 100 && i < total; i++)
      {
        'id': 'row-$i',
        'name': '原文货品😀$i',
        'amount': '90071992547409.1234567890123456789',
      },
  ],
};

List<Map<String, dynamic>> _frames(int total) => [
  for (var page = 1; page <= ((total + 99) ~/ 100).clamp(1, total + 1); page++)
    {'type': 'page', 'value': _page(page, total)},
  {
    'type': 'complete',
    'total': total,
    'readScopeVersion': 'a' * 64,
    'readSnapshotRevision': 'b' * 64,
    'readDataVersion': 'c' * 64,
  },
];

Future<VersionedSummarySnapshot<Map<String, dynamic>>> _read(
  Stream<Map<String, dynamic>> frames,
) async {
  final stream = CompleteSummaryStream(frames);
  try {
    return await readVersionedSummarySnapshot<Map<String, dynamic>>(
      loadPage: stream.page,
      isCurrent: () => true,
      decode: (row) => row,
      idOf: (row) => row['id'],
    );
  } finally {
    await stream.close();
  }
}

void main() {
  testWidgets('complete stream resolves while the widget clock pumps', (
    tester,
  ) async {
    Stream<Map<String, dynamic>> frames() async* {
      for (final frame in _frames(1)) {
        await Future<void>.delayed(Duration.zero);
        yield frame;
      }
    }

    var done = false;
    Object? failure;
    _read(frames()).then<void>(
      (_) => done = true,
      onError: (Object error) {
        failure = error;
        done = true;
      },
    );
    for (var i = 0; i < 10 && !done; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(done, isTrue);
    expect(failure, isNull);
  });
  for (final count in [0, 1, 100, 101, 10001]) {
    test(
      'one stream retains complete $count rows and exact originals',
      () async {
        final result = await _read(Stream.fromIterable(_frames(count)));
        expect(result.items, hasLength(count));
        expect(result.page.total, count);
        expect(result.page.totalPages, count == 0 ? 0 : 1);
        if (count > 0) {
          expect(result.items.last['id'], 'row-${count - 1}');
          expect(result.items.last['name'], '原文货品😀${count - 1}');
          expect(
            result.items.last['amount'],
            '90071992547409.1234567890123456789',
          );
        }
      },
    );
  }

  for (final failure in [
    'missing-end',
    'truncated',
    'extra-page',
    'extra-error',
    'wrong-end-proof',
    'wrong-end-total',
    'wrong-page',
    'short-page',
    'changed-data',
    'duplicate',
    'missing-proof',
    'changed-scope',
    'changed-end-scope',
  ]) {
    test('$failure never publishes a complete prefix', () async {
      final frames = _frames(201);
      switch (failure) {
        case 'missing-end':
          frames.removeLast();
        case 'truncated':
          frames.removeRange(1, frames.length);
        case 'extra-page':
          frames.add({'type': 'page', 'value': _page(3, 201)});
        case 'extra-error':
          frames.add({'type': 'error', 'code': 'INTERNAL', 'message': '失败'});
        case 'wrong-end-proof':
          frames.last['readSnapshotRevision'] = 'd' * 64;
        case 'wrong-end-total':
          frames.last['total'] = 200;
        case 'wrong-page':
          (frames[1]['value'] as Map)['page'] = 3;
        case 'short-page':
          ((frames[1]['value'] as Map)['items'] as List).removeLast();
        case 'changed-data':
          (frames[1]['value'] as Map)['readDataVersion'] = 'd' * 64;
        case 'duplicate':
          (((frames[1]['value'] as Map)['items'] as List).first as Map)['id'] =
              'row-0';
        case 'missing-proof':
          (frames[1]['value'] as Map).remove('readScopeVersion');
        case 'changed-scope':
          (frames[1]['value'] as Map)['readScopeVersion'] = 'd' * 64;
        case 'changed-end-scope':
          frames.last['readScopeVersion'] = 'd' * 64;
      }
      await expectLater(
        _read(Stream.fromIterable(frames)),
        throwsA(isA<ApiException>()),
      );
    });
  }

  test('last page waits for completion marker and real EOF', () async {
    final source = StreamController<Map<String, dynamic>>();
    var published = false;
    final result = _read(source.stream).then((value) {
      published = true;
      return value;
    });
    final frames = _frames(1);
    source.add(frames.first);
    await Future<void>.delayed(Duration.zero);
    expect(published, isFalse);
    source.add(frames.last);
    await Future<void>.delayed(Duration.zero);
    expect(published, isFalse);
    await source.close();
    expect((await result).items, hasLength(1));
  });

  test('structured access error retains its authoritative code', () async {
    await expectLater(
      _read(
        Stream.fromIterable([
          _frames(201).first,
          {'type': 'error', 'code': 'READ_SCOPE_CHANGED', 'message': '权限已变化'},
        ]),
      ),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'READ_SCOPE_CHANGED'),
      ),
    );
  });

  test(
    'NDJSON splits UTF-8 and frames across arbitrary transport chunks',
    () async {
      final bytes = utf8.encode('${_frames(101).map(jsonEncode).join('\n')}\n');
      final decoded = decodeSummaryFrames(
        Stream.fromIterable([
          for (var i = 0; i < bytes.length; i += 7)
            Uint8List.fromList(
              bytes.sublist(i, (i + 7).clamp(0, bytes.length)),
            ),
        ]),
        decode: (value) async => jsonDecode(utf8.decode(value)),
        isCurrent: () => true,
      );
      expect((await _read(decoded)).items.last['name'], '原文货品😀100');
    },
  );

  for (final bytes in [
    utf8.encode('{"type":"page"\n'),
    utf8.encode('[]\n'),
    utf8.encode('\n'),
    [0xff, 0x0a],
  ]) {
    test('malformed frame does not become a partial success', () async {
      await expectLater(
        decodeSummaryFrames(
          Stream.value(Uint8List.fromList(bytes)),
          decode: (value) async => jsonDecode(utf8.decode(value)),
          isCurrent: () => true,
        ).toList(),
        throwsA(isA<ApiException>()),
      );
    });
  }

  test('retired decoder cannot deliver a frame', () async {
    await expectLater(
      decodeSummaryFrames(
        Stream.value(Uint8List.fromList(utf8.encode('{"type":"complete"}\n'))),
        decode: (value) async => jsonDecode(utf8.decode(value)),
        isCurrent: () => false,
      ).toList(),
      throwsA(isA<UiWorkCancelled>()),
    );
  });
}
