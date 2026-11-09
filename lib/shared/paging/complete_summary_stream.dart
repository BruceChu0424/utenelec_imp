import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../core/network/api_error.dart';
import '../../core/network/api_exception.dart';
import '../../core/performance/ui_work_budget.dart';
import 'complete_paged_snapshot.dart';

ApiException _invalidStream() =>
    ApiException('INCOMPLETE_READ_PROTOCOL', '完整列表传输未完成或读取凭据无效，请重试');

/// Frames are decoded independently, including UTF-8 split across network
/// chunks. Large JSON frames retain the client's worker/isolate decoder.
Stream<Map<String, dynamic>> decodeSummaryFrames(
  Stream<Uint8List> bytes, {
  required Future<Object?> Function(Uint8List) decode,
  required bool Function() isCurrent,
}) async* {
  final lines = bytes
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  try {
    await for (final line in lines) {
      if (!isCurrent()) throw const UiWorkCancelled();
      if (line.isEmpty) throw _invalidStream();
      final value = await decode(Uint8List.fromList(utf8.encode(line)));
      if (!isCurrent()) throw const UiWorkCancelled();
      if (value is! Map<String, dynamic>) throw _invalidStream();
      yield value;
    }
  } on FormatException {
    throw _invalidStream();
  }
}

/// The request `size` that selects the progressive frame plan (first frame
/// 50 rows, then aligned up to 200). `100` keeps the original fixed frames.
const kProgressiveSummaryStreamSize = 200;

/// Adapts one HTTP stream to the existing complete-page validator. Only this
/// transport changes: row identity, totals, authority and snapshot validation
/// remain owned by readVersionedSummarySnapshot/loadCompletePagedResult.
/// Every frame is the exact server page the shared [plan] places at the rows
/// already received, so client and server agree on each frame boundary.
class CompleteSummaryStream {
  CompleteSummaryStream(
    Stream<Map<String, dynamic>> frames, {
    this.plan = const CompleteReadBatchPlan.fixed(100),
  }) : _frames = StreamIterator(frames);

  final CompleteReadBatchPlan plan;
  final StreamIterator<Map<String, dynamic>> _frames;
  Map<String, dynamic>? _first;
  var _offset = 0;
  var _complete = false;
  var _started = false;
  var _sourceFinished = false;

  Future<bool> _moveNext() async {
    try {
      _started = true;
      final next = await _frames.moveNext();
      if (!next) _sourceFinished = true;
      return next;
    } catch (_) {
      _sourceFinished = true;
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _next() async {
    if (!await _moveNext()) throw _invalidStream();
    final frame = _frames.current;
    if (frame['type'] == 'error') {
      if (frame['code'] is! String || frame['message'] is! String) {
        throw _invalidStream();
      }
      throw ApiException.fromApiError(ApiError.fromJson(frame));
    }
    return frame;
  }

  Future<Map<String, dynamic>> page(
    int page,
    int size,
    String? revision,
  ) async {
    final expectedSize = plan.sizeAt(_offset);
    if (_complete ||
        size != expectedSize ||
        page != _offset ~/ expectedSize + 1) {
      throw _invalidStream();
    }
    final frame = await _next();
    final value = frame['value'];
    if (frame['type'] != 'page' || value is! Map<String, dynamic>) {
      throw _invalidStream();
    }
    if (value['page'] != page || value['size'] != size) {
      throw _invalidStream();
    }
    final pages = value['totalPages'];
    final total = value['total'];
    final rows = value['items'];
    if (pages is! int || total is! int || total < 0 || rows is! List) {
      throw _invalidStream();
    }
    final expectedPages = (total + size - 1) ~/ size;
    final remaining = total - _offset;
    final expectedRows = remaining <= 0 ? 0 : remaining.clamp(0, size);
    if (pages != expectedPages || rows.length != expectedRows) {
      throw _invalidStream();
    }
    for (final key in const [
      'readScopeVersion',
      'readSnapshotRevision',
      'readDataVersion',
    ]) {
      final proof = value[key];
      if (proof is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(proof)) {
        throw _invalidStream();
      }
    }
    _first ??= value;
    if (value['readScopeVersion'] != _first!['readScopeVersion']) {
      throw ApiException(
        'READ_SCOPE_CHANGED',
        '数据访问范围已变化，请重新读取',
        httpStatus: 403,
      );
    }
    if (revision != null && value['readSnapshotRevision'] != revision) {
      throw ApiException('SNAPSHOT_CHANGED', '列表已变化，请重新读取');
    }
    _offset += rows.length;
    if (_offset >= total) {
      final end = await _next();
      if (end['type'] != 'complete') throw _invalidStream();
      if (end['readScopeVersion'] != _first!['readScopeVersion']) {
        throw ApiException(
          'READ_SCOPE_CHANGED',
          '数据访问范围已变化，请重新读取',
          httpStatus: 403,
        );
      }
      for (final key in const [
        'readScopeVersion',
        'readSnapshotRevision',
        'readDataVersion',
        'total',
      ]) {
        if (end[key] != _first![key] || end[key] != value[key]) {
          throw _invalidStream();
        }
      }
      // A complete marker alone is insufficient: trailing pages, errors or
      // another document must never be silently ignored.
      if (await _moveNext()) throw _invalidStream();
      _complete = true;
    }
    return value;
  }

  Future<void> close() async {
    if (_sourceFinished) return;
    _sourceFinished = true;
    if (!_started) return;
    await _frames.cancel();
  }
}
