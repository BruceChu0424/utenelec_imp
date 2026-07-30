import 'dart:typed_data';

import 'package:printing/printing.dart';

Future<bool> printPdfBytes(Uint8List bytes, String filename) {
  return Printing.layoutPdf(onLayout: (_) async => bytes, name: filename);
}
