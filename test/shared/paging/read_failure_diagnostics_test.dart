import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_log.dart';
import 'package:uten_imp/core/diagnostics/diagnostic_store.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart';
import 'package:uten_imp/shared/paging/read_failure_diagnostics.dart';

class _RecordingStore implements DiagnosticStore {
  final lines = <String>[];
  @override
  String? get directory => null;
  @override
  Future<void> append(String lines) async => this.lines.add(lines);
  @override
  Future<Uint8List> readRecent() async => Uint8List(0);
  @override
  Future<void> openDirectory() async {}
}

Future<List<Map<String, Object?>>> _records(_RecordingStore store) async {
  await AppDiagnostics.log?.flush();
  return [
    for (final line in store.lines.join().split('\n'))
      if (line.trim().isNotEmpty)
        jsonDecode(line) as Map<String, Object?>,
  ];
}

void main() {
  test('a real protocol failure carries one correlation ref end to end', () async {
    final store = _RecordingStore();
    AppDiagnostics.log = DiagnosticLog(store);
    addTearDown(() => AppDiagnostics.log = null);
    Object? caught;
    try {
      await loadCompletePagedResult<int>(
        loadPage: (page, size) async => const PagedResult<int>(
          items: [1, 2, 3],
          page: 1,
          size: 50,
          total: 10,
          totalPages: 1,
        ),
        isCurrent: () => true,
      );
    } catch (error) {
      caught = error;
    }
    final failure = caught;
    expect(failure, isA<ApiException>());
    final api = failure as ApiException;
    expect(api.code, 'INVALID_PAGINATION');
    // The ref rides the user-facing message and the exception details.
    final refMatch = RegExp(r'（关联号 ([0-9A-Z]{6})）$').firstMatch(api.message);
    expect(refMatch, isNotNull, reason: api.message);
    final ref = refMatch!.group(1)!;
    expect(api.details?['diagnosticRef'], ref);
    // One structured diagnostic record, anonymous: stage/code/ref only.
    final records = await _records(store);
    final read = records.where((r) => r['event'] == 'read.failed').toList();
    expect(read, hasLength(1));
    expect(read.single['stage'], 'complete-read');
    expect(read.single['code'], 'INVALID_PAGINATION');
    expect(read.single['ref'], ref);
    expect(read.single.keys, isNot(contains('message')));
  });

  test('a retirement stays quiet: no ref, no diagnostic record', () async {
    final store = _RecordingStore();
    AppDiagnostics.log = DiagnosticLog(store);
    addTearDown(() => AppDiagnostics.log = null);
    var live = true;
    Object? caught;
    try {
      await loadCompletePagedResult<int>(
        loadPage: (page, size) async {
          live = false; // the read is retired right after its first batch
          return const PagedResult<int>(
            items: [1],
            page: 1,
            size: 1,
            total: 2,
            totalPages: 2,
          );
        },
        isCurrent: () => live,
      );
    } catch (error) {
      caught = error;
    }
    expect(caught, isA<UiWorkCancelled>());
    final records = await _records(store);
    expect(records.where((r) => r['event'] == 'read.failed'), isEmpty);
  });

  test('a server-attached correlation wins over a generated one', () async {
    final store = _RecordingStore();
    AppDiagnostics.log = DiagnosticLog(store);
    addTearDown(() => AppDiagnostics.log = null);
    final annotated = annotateCompleteReadFailure(
      ApiException('SNAPSHOT_CHANGED', '数据已变化', details: {
        'correlation': 'SRV42X',
      }),
      StackTrace.current,
      stage: 'cursor-read',
    ) as ApiException;
    expect(annotated.message, endsWith('（关联号 SRV42X）'));
    expect(annotated.details?['diagnosticRef'], 'SRV42X');
    final records = await _records(store);
    final read = records.singleWhere((r) => r['event'] == 'read.failed');
    expect(read['ref'], 'SRV42X');
    expect(read['stage'], 'cursor-read');
  });

  test('subtype failures keep their exact type and message', () async {
    final store = _RecordingStore();
    AppDiagnostics.log = DiagnosticLog(store);
    addTearDown(() => AppDiagnostics.log = null);
    final original = NetworkException();
    final annotated = annotateCompleteReadFailure(
      original,
      StackTrace.current,
      stage: 'complete-read',
    );
    expect(identical(annotated, original), isTrue);
    final records = await _records(store);
    final read = records.singleWhere((r) => r['event'] == 'read.failed');
    expect(read['code'], 'NETWORK');
  });
}
