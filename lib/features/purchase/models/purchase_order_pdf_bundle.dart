import 'dart:typed_data';
import '../../../shared/export/order_document_bundle.dart';
import '../../../shared/print/procurement_order_print_document.dart';
export '../../../shared/export/order_document_bundle.dart';

typedef PurchaseOrderExportLimits = OrderDocumentExportLimits;
typedef PurchaseOrderZipOutput = OrderDocumentZipOutput;
typedef PurchaseOrderBundleResult = OrderDocumentBundleResult;
Future<({String payload, int bytes})> encodePurchaseOrderBundleInput(
  List<Map<String, dynamic>> documents, {
  required bool Function() stillCurrent,
}) => encodeOrderBundleInput(documents, stillCurrent: stillCurrent);
Future<Uint8List> renderPurchaseOrderBundle(
  String payload,
  Uint8List? fontBytes,
) => renderOrderBundle(
  payload,
  fontBytes,
  kind: ProcurementOrderPrintKind.purchase,
);
