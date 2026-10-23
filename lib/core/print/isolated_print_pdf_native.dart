import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../performance/ui_work_budget.dart';
import 'print_pdf_document.dart';

class IsolatedPrintPdfGenerator {
  IsolatedPrintPdfGenerator({this.debugOnIsolateStarted});

  /// Tests can attach an independent exit listener without changing worker work.
  final void Function(Isolate isolate)? debugOnIsolateStarted;
  bool _disposed = false;
  bool _busy = false;
  Isolate? _worker;
  ReceivePort? _messages;
  StreamSubscription<Object?>? _subscription;
  Completer<Uint8List>? _pending;

  Future<Uint8List> generate(PrintPdfRequest request) async {
    if (_disposed) throw const UiWorkCancelled();
    if (_busy) throw StateError('PDF generation is already running');
    _busy = true;
    final messages = _messages = ReceivePort();
    final result = _pending = Completer<Uint8List>();
    // Disposal can happen while spawn is still awaited. Mark the error handled
    // now, while preserving it for the awaited result below.
    result.future.ignore();
    _subscription = messages.listen((Object? message) {
      if (result.isCompleted) return;
      if (message is Uint8List) {
        result.complete(message);
      } else {
        // Errors and unexpected exits never expose document/exception text.
        result.completeError(StateError('PDF isolate failed'));
      }
    });
    try {
      final worker = await Isolate.spawn(
        _runPdf,
        _PdfJob(request, messages.sendPort),
        debugName: 'uten-print-pdf',
        onError: messages.sendPort,
        onExit: messages.sendPort,
      );
      _worker = worker;
      debugOnIsolateStarted?.call(worker);
      if (_disposed) {
        worker.kill(priority: Isolate.immediate);
        if (!result.isCompleted) result.completeError(const UiWorkCancelled());
      }
      final bytes = await result.future.timeout(const Duration(minutes: 2));
      if (_disposed) throw const UiWorkCancelled();
      return bytes;
    } finally {
      _retireWorker();
      _pending = null;
      _busy = false;
    }
  }

  void _retireWorker() {
    _worker?.kill(priority: Isolate.immediate);
    _worker = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _messages?.close();
    _messages = null;
  }

  void dispose() {
    _disposed = true;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const UiWorkCancelled());
    }
    _retireWorker();
  }
}

class _PdfJob {
  const _PdfJob(this.request, this.result);
  final PrintPdfRequest request;
  final SendPort result;
}

void _runPdf(_PdfJob job) => unawaited(_render(job));

Future<void> _render(_PdfJob job) async {
  try {
    final bytes = await renderPrintPdf(job.request);
    Isolate.exit(job.result, bytes);
  } catch (_) {
    Isolate.exit(job.result, false);
  }
}
