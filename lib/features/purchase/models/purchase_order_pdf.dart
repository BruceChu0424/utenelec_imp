import 'dart:typed_data';
import 'package:pdf/widgets.dart' as pw;
import '../../../shared/print/procurement_order_pdf.dart';
import 'purchase_order_print_document.dart';

Future<Uint8List> renderPurchaseOrderPdf(
  PurchaseOrderPrintDocument document, {
  required pw.Font font,
}) => renderProcurementOrderPdf(
  document,
  font: font,
  kind: ProcurementOrderPrintKind.purchase,
);
