import 'dart:typed_data';

import '../io/file_saver.dart';
import 'pdf_printer_web.dart'
    if (dart.library.io) 'pdf_printer_io.dart'
    as impl;

/// Opens the platform print flow for an already generated PDF.
///
/// Web uses the browser's same-origin PDF viewer directly. This avoids the
/// `printing` Web implementation's runtime pdf.js CDN fallback and inline
/// script injection, both of which are incompatible with mainland/offline
/// deployments and the application's strict CSP.
Future<bool> printPdfBytes(Uint8List bytes, String filename) =>
    impl.printPdfBytes(bytes, sanitizeDownloadFilename(filename));
