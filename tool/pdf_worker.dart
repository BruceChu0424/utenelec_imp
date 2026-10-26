import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'package:uten_imp/core/print/print_pdf_document.dart';
import 'package:uten_imp/features/purchase/models/purchase_order_pdf_bundle.dart';

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
  var version = 1;
  try {
    final data = event.data as JSObject;
    version = data.getProperty<JSNumber>('version'.toJS).toDartInt;
    if (version != 1 && version != 2 && version != 3) {
      throw const FormatException('protocol');
    }
    final subtitle = data.getProperty<JSString?>('subtitle'.toJS);
    final widths = data.getProperty<JSArray<JSNumber>?>('widths'.toJS);
    final font = data.getProperty<JSUint8Array?>('font'.toJS);
    if (version == 3) {
      if (data.getProperty<JSString>('kind'.toJS).toDart !=
          'purchase-order-bundle') {
        throw const FormatException('renderer');
      }
      final bytes = await renderPurchaseOrderBundle(
        data.getProperty<JSString>('payload'.toJS).toDart,
        font?.toDart,
      );
      _reply(version, bytes);
      return;
    }
    final request = version == 2
        ? PrintPdfRequest.orgChart(
            title: data.getProperty<JSString>('title'.toJS).toDart,
            subtitle: subtitle?.toDart,
            fontBytes: font?.toDart,
            lines: data
                .getProperty<JSArray<JSObject>>('outline'.toJS)
                .toDart
                .map(
                  (line) => OrgChartPrintLine(
                    kind: line.getProperty<JSString>('kind'.toJS).toDart,
                    depth: line.getProperty<JSNumber>('depth'.toJS).toDartInt,
                    text: line.getProperty<JSString>('text'.toJS).toDart,
                    detail: line.getProperty<JSString?>('detail'.toJS)?.toDart,
                    bold: line.getProperty<JSBoolean>('bold'.toJS).toDart,
                  ),
                )
                .toList(),
          )
        : PrintPdfRequest(
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
          );
    final bytes = await renderPrintPdf(request);
    _reply(version, bytes);
  } catch (_) {
    // Never send document contents, font data or exception text to the UI.
    _worker.postMessage(_PdfReply(version: version.toJS, error: true.toJS));
  }
}

void _reply(int version, Uint8List bytes) {
  final output = bytes.toJS;
  _worker.postMessage(
    _PdfReply(version: version.toJS, bytes: output),
    <JSObject>[output.getProperty<JSArrayBuffer>('buffer'.toJS)].toJS,
  );
}
