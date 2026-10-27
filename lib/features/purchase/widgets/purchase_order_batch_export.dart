import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../core/network/api_client.dart';
import '../../../core/print/isolated_print_pdf.dart';
import '../../../shared/export/order_documents_export.dart';
import '../../../shared/print/procurement_order_print_document.dart';
import '../models/purchase_order_pdf_bundle.dart';
export '../../../shared/export/order_documents_export.dart'
    show OperationsWorkbenchBatchDocExport;

Future<void> exportPurchaseOrderDocumentsBatch(
  BuildContext context, {
  required ApiClient apiClient,
  required List<({String id, String number})> documents,
  void Function(int done, int total)? onProgress,
  bool Function()? stillCurrent,
  Future<String> Function(
    Uint8List bytes,
    String filename, {
    bool Function()? stillCurrent,
  })?
  saver,
  Future<Uint8List> Function(PrintPdfRequest request)? generate,
}) => exportOrderDocumentsBatch(
  context,
  apiClient: apiClient,
  kind: ProcurementOrderPrintKind.purchase,
  renderer: renderPurchaseOrderBundle,
  documents: documents,
  onProgress: onProgress,
  stillCurrent: stillCurrent,
  saver: saver,
  generate: generate,
);
