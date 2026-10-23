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
      work.ensureCurrent();
      final url = Uri.parse(
        web.document.baseURI,
      ).resolve('assets/assets/workers/uten_pdf_worker.js');
      final worker = _worker = web.Worker(url.toString().toJS);
      final result = _pending = Completer<Uint8List>();
      worker.onmessage = ((web.MessageEvent event) {
        if (_disposed || result.isCompleted) return;
        try {
          final message = event.data as JSObject;
          if (message.getProperty<JSNumber>('version'.toJS).toDartInt != 1 ||
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
          version: 1.toJS,
          title: request.title.toJS,
          subtitle: request.subtitle?.toJS,
          headers: request.headers.map((value) => value.toJS).toList().toJS,
          rows: rows,
          widths: request.columnWidths
              ?.map((value) => value.toJS)
              .toList()
              .toJS,
          font: request.fontBytes?.toJS,
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
