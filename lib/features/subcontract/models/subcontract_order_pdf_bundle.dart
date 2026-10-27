import 'dart:typed_data';
import '../../../shared/export/order_document_bundle.dart';
import '../../../shared/print/procurement_order_print_document.dart';

Future<Uint8List> renderSubcontractOrderBundle(
  String payload,
  Uint8List? fontBytes,
) => renderOrderBundle(
  payload,
  fontBytes,
  kind: ProcurementOrderPrintKind.subcontract,
);
