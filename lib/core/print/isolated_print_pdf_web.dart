import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../performance/ui_work_budget.dart';
import 'print_pdf_document.dart';

extension type _PdfRequest._(JSObject _) implements JSObject {
  external factory _PdfRequest({
    required JSNumber version,
    required JSString title,
    required JSString? subtitle,
    required JSArray<JSString> headers,
    required JSArray<JSArray<JSString>> rows,
    required JSArray<JSNumber>? widths,
    required JSUint8Array? font,
    required JSArray<_OutlineLine>? outline,
    required JSString? kind,
    required JSString? payload,
  });
}

extension type _OutlineLine._(JSObject _) implements JSObject {
  external factory _OutlineLine({
    required JSString kind,
    required JSNumber depth,
    required JSString text,
    required JSString? detail,
    required JSBoolean bold,
  });
}

/// Owns exactly one dedicated worker at a time. Failure never falls back to
/// blocking generation on the UI thread; disposal terminates sensitive work.
class IsolatedPrintPdfGenerator {
  web.Worker? _worker;
  Completer<Uint8List>? _pending;
  bool _disposed = false;
  bool _busy = false;

  Future<Uint8List> generate(PrintPdfRequest request) async {
    if (_disposed) throw const UiWorkCancelled();
    if (_busy) throw StateError('PDF generation is already running');
    _busy = true;
    try {
      final work = UiWorkBudget(
        isCurrent: () => !_disposed,
        debugLabel: 'print-worker-input',
      );
      final rows = <JSArray<JSString>>[].toJS;
      for (final row in request.rows) {
        final cells = <JSString>[];
        for (final cell in row) {
          cells.add(cell.toJS);
          await work.checkpoint();
        }
        rows.add(cells.toJS);
      }
      final outline = request.orgChartLines == null
          ? null
          : <_OutlineLine>[].toJS;
      for (final line in request.orgChartLines ?? const <OrgChartPrintLine>[]) {
        outline!.add(
          _OutlineLine(
            kind: line.kind.toJS,
            depth: line.depth.toJS,
            text: line.text.toJS,
            detail: line.detail?.toJS,
            bold: line.bold.toJS,
          ),
        );
        await work.checkpoint();
      }
      work.ensureCurrent();
      final url = Uri.parse(
        web.document.baseURI,
      ).resolve('assets/assets/workers/uten_pdf_worker.js');
      final worker = _worker = web.Worker(url.toString().toJS);
      final result = _pending = Completer<Uint8List>();
      final version = request.binaryKind != null
          ? 3
          : request.orgChartLines == null
          ? 1
          : 2;
      worker.onmessage = ((web.MessageEvent event) {
        if (_disposed || result.isCompleted) return;
        try {
          final message = event.data as JSObject;
          if (message.getProperty<JSNumber>('version'.toJS).toDartInt !=
                  version ||
              message.getProperty<JSBoolean?>('error'.toJS)?.toDart == true) {
            result.completeError(StateError('PDF worker failed'));
          } else {
            result.complete(
              message.getProperty<JSUint8Array>('bytes'.toJS).toDart,
            );
          }
        } catch (_) {
          result.completeError(
            StateError('PDF worker returned an invalid response'),
          );
        }
      }).toJS;
      void fail(web.Event _) {
        if (!result.isCompleted) {
          result.completeError(StateError('PDF worker is unavailable'));
        }
      }

      worker.onerror = fail.toJS;
      worker.onmessageerror = fail.toJS;
      worker.postMessage(
        _PdfRequest(
          version: version.toJS,
          title: request.title.toJS,
          subtitle: request.subtitle?.toJS,
          headers: request.headers.map((value) => value.toJS).toList().toJS,
          rows: rows,
          widths: request.columnWidths
              ?.map((value) => value.toJS)
              .toList()
              .toJS,
          font: request.fontBytes?.toJS,
          outline: outline,
          kind: request.binaryKind?.toJS,
          payload: request.binaryPayload?.toJS,
        ),
      );
      final bytes = await result.future.timeout(const Duration(minutes: 2));
      work.ensureCurrent();
      return bytes;
    } finally {
      _worker?.terminate();
      _worker = null;
      _pending = null;
      _busy = false;
    }
  }

  void dispose() {
    _disposed = true;
    _worker?.terminate();
    _worker = null;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const UiWorkCancelled());
    }
  }
}
