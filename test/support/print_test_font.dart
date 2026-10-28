import 'package:flutter/services.dart';
import 'package:pdf/widgets.dart' as pw;

// Match the production print entry points, including their Chinese glyphs.
// Load before starting performance timers so asset I/O is not a layout sample.
Future<Uint8List> loadPrintTestFontBytes() async {
  final data = await rootBundle.load('assets/fonts/NotoSansSCFull.ttf');
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

Future<pw.Font> loadPrintTestFont() async =>
    pw.Font.ttf(ByteData.sublistView(await loadPrintTestFontBytes()));
