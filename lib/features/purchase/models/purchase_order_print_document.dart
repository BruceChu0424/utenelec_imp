// Compatibility names for existing purchase paper callers; the authoritative
// snapshot contract and exact decimal presentation are shared with subcontract.
import '../../../shared/print/procurement_order_print_document.dart';
export '../../../shared/print/procurement_order_print_document.dart';

typedef PurchaseOrderPrintDocument = ProcurementOrderPrintDocument;
typedef PurchaseOrderPrintLine = ProcurementOrderPrintLine;
String purchaseOrderRmbCapital(String? exact) =>
    procurementOrderRmbCapital(exact);
