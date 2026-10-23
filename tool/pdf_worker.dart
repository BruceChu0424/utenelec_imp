import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'package:uten_imp/core/print/print_pdf_document.dart';

@JS('self')
external web.DedicatedWorkerGlobalScope get _worker;

extension type _PdfReply._(JSObject _) implements JSObject {
  external factory _PdfReply({
    required JSNumber version,
    JSUint8Array? bytes,
    JSBoolean? error,
  });
}

void main() {
  _worker.onmessage = ((web.MessageEvent event) {
    unawaited(_generate(event));
  }).toJS;
}

Future<void> _generate(web.MessageEvent event) async {
  try {
    final data = event.data as JSObject;
    if (data.getProperty<JSNumber>('version'.toJS).toDartInt != 1) {
      throw const FormatException('protocol');
    }
    final subtitle = data.getProperty<JSString?>('subtitle'.toJS);
    final widths = data.getProperty<JSArray<JSNumber>?>('widths'.toJS);
    final font = data.getProperty<JSUint8Array?>('font'.toJS);
    final bytes = await renderPrintPdf(
      PrintPdfRequest(
        title: data.getProperty<JSString>('title'.toJS).toDart,
        subtitle: subtitle?.toDart,
        headers: data
            .getProperty<JSArray<JSString>>('headers'.toJS)
            .toDart
            .map((value) => value.toDart)
            .toList(),
        rows: data
            .getProperty<JSArray<JSArray<JSString>>>('rows'.toJS)
            .toDart
            .map((row) => row.toDart.map((value) => value.toDart).toList())
            .toList(),
        columnWidths: widths?.toDart
            .map((value) => value.toDartDouble)
            .toList(),
        fontBytes: font?.toDart,
      ),
    );
    final output = bytes.toJS;
    _worker.postMessage(
      _PdfReply(version: 1.toJS, bytes: output),
      <JSObject>[output.getProperty<JSArrayBuffer>('buffer'.toJS)].toJS,
    );
  } catch (_) {
    // Never send document contents, font data or exception text to the UI.
    _worker.postMessage(_PdfReply(version: 1.toJS, error: true.toJS));
  }
}
