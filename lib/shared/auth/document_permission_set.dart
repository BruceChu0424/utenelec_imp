import 'permissions.dart';

/// Standard button-level permission contract for business documents.
///
/// A config owns only the stable code mapping. List/detail/edit pages consume
/// the same mapping instead of inferring actions from an `:edit` suffix.
enum DocumentPermissionAction { view, create, edit, delete, approve, reverse }

final class DocumentPermissionSet {
  const DocumentPermissionSet({
    required this.view,
    this.create,
    this.edit,
    this.delete,
    this.approve,
    this.reverse,
  });

  final String view;
  final String? create;
  final String? edit;
  final String? delete;
  final String? approve;
  final String? reverse;

  String? codeFor(DocumentPermissionAction action) => switch (action) {
    DocumentPermissionAction.view => view,
    DocumentPermissionAction.create => create,
    DocumentPermissionAction.edit => edit,
    DocumentPermissionAction.delete => delete,
    DocumentPermissionAction.approve => approve,
    DocumentPermissionAction.reverse => reverse,
  };

  bool allows(Iterable<String> granted, DocumentPermissionAction action) {
    final code = codeFor(action);
    return code != null && granted.contains(code);
  }

  Iterable<String> get actionCodes sync* {
    yield view;
    if (create case final code?) yield code;
    if (edit case final code?) yield code;
    if (delete case final code?) yield code;
    if (approve case final code?) yield code;
    if (reverse case final code?) yield code;
  }
}

/// Single Dart source for stable document action-code mappings.
///
/// Names, descriptions, action labels and page membership come from the
/// database. This map only names executable authorities for routes/buttons.
abstract final class DocumentPermissionCatalog {
  static const salesQuote = DocumentPermissionSet(
    view: Perm.salesQuoteView,
    create: Perm.salesQuoteCreate,
    edit: Perm.salesQuoteEdit,
    delete: Perm.salesQuoteDelete,
    approve: Perm.salesQuoteApprove,
    reverse: Perm.salesQuoteReverse,
  );
  static const salesOrder = DocumentPermissionSet(
    view: Perm.salesOrderView,
    create: Perm.salesOrderCreate,
    edit: Perm.salesOrderEdit,
    delete: Perm.salesOrderDelete,
    approve: Perm.salesOrderApprove,
    reverse: Perm.salesOrderReverse,
  );
  static const salesShipment = DocumentPermissionSet(
    view: Perm.salesShipmentView,
    create: Perm.salesShipmentCreate,
    edit: Perm.salesShipmentEdit,
    delete: Perm.salesShipmentDelete,
    approve: Perm.salesShipmentApprove,
    reverse: Perm.salesShipmentReverse,
  );
  static const salesOtherShipment = DocumentPermissionSet(
    view: Perm.salesOtherShipmentView,
    create: Perm.salesOtherShipmentCreate,
    edit: Perm.salesOtherShipmentEdit,
    delete: Perm.salesOtherShipmentDelete,
    approve: Perm.salesOtherShipmentApprove,
    reverse: Perm.salesOtherShipmentReverse,
  );
  static const salesReturn = DocumentPermissionSet(
    view: Perm.salesReturnView,
    create: Perm.salesReturnCreate,
    edit: Perm.salesReturnEdit,
    delete: Perm.salesReturnDelete,
    approve: Perm.salesReturnApprove,
    reverse: Perm.salesReturnReverse,
  );
  static const salesBySegment = <String, DocumentPermissionSet>{
    'quotes': salesQuote,
    'orders': salesOrder,
    'shipments': salesShipment,
    'other-shipments': salesOtherShipment,
    'returns': salesReturn,
  };

  static const purchaseRequest = DocumentPermissionSet(
    view: Perm.purchaseRequestView,
  );
  static const purchaseOrder = DocumentPermissionSet(
    view: Perm.purchaseOrderView,
    create: Perm.purchaseOrderCreate,
    edit: Perm.purchaseOrderEdit,
    delete: Perm.purchaseOrderDelete,
    reverse: Perm.purchaseOrderReverse,
  );
  static const purchaseReceipt = DocumentPermissionSet(
    view: Perm.purchaseReceiptView,
    create: Perm.purchaseReceiptCreate,
    edit: Perm.purchaseReceiptEdit,
    delete: Perm.purchaseReceiptDelete,
    approve: Perm.purchaseReceiptApprove,
    reverse: Perm.purchaseReceiptReverse,
  );
  static const purchaseReturn = DocumentPermissionSet(
    view: Perm.purchaseReturnView,
    create: Perm.purchaseReturnCreate,
    edit: Perm.purchaseReturnEdit,
    delete: Perm.purchaseReturnDelete,
    approve: Perm.purchaseReturnApprove,
    reverse: Perm.purchaseReturnReverse,
  );
  static const purchaseBySegment = <String, DocumentPermissionSet>{
    'requests': purchaseRequest,
    'orders': purchaseOrder,
    'receipts': purchaseReceipt,
    'returns': purchaseReturn,
  };

  static const subcontractInquiry = DocumentPermissionSet(
    view: Perm.subcontractInquiryView,
    create: Perm.subcontractInquiryCreate,
    edit: Perm.subcontractInquiryEdit,
    delete: Perm.subcontractInquiryDelete,
    approve: Perm.subcontractInquiryApprove,
    reverse: Perm.subcontractInquiryReverse,
  );
  static const subcontractApplication = DocumentPermissionSet(
    view: Perm.subcontractApplicationView,
  );
  static const subcontractOrder = DocumentPermissionSet(
    view: Perm.subcontractOrderView,
    create: Perm.subcontractOrderCreate,
    edit: Perm.subcontractOrderEdit,
    delete: Perm.subcontractOrderDelete,
    reverse: Perm.subcontractOrderReverse,
  );
  static const subcontractReceipt = DocumentPermissionSet(
    view: Perm.subcontractReceiptView,
    create: Perm.subcontractReceiptCreate,
    edit: Perm.subcontractReceiptEdit,
    delete: Perm.subcontractReceiptDelete,
    approve: Perm.subcontractReceiptApprove,
    reverse: Perm.subcontractReceiptReverse,
  );
  static const subcontractMaterialIssue = DocumentPermissionSet(
    view: Perm.subcontractMaterialIssueView,
    edit: Perm.subcontractMaterialIssueEdit,
    delete: Perm.subcontractMaterialIssueDelete,
    approve: Perm.subcontractMaterialIssueApprove,
    reverse: Perm.subcontractMaterialIssueReverse,
  );
  static const subcontractReturn = DocumentPermissionSet(
    view: Perm.subcontractReturnView,
    create: Perm.subcontractReturnCreate,
    edit: Perm.subcontractReturnEdit,
    delete: Perm.subcontractReturnDelete,
    approve: Perm.subcontractReturnApprove,
    reverse: Perm.subcontractReturnReverse,
  );
  static const subcontractMaterialReturn = DocumentPermissionSet(
    view: Perm.subcontractMaterialReturnView,
    create: Perm.subcontractMaterialReturnCreate,
    edit: Perm.subcontractMaterialReturnEdit,
    delete: Perm.subcontractMaterialReturnDelete,
    approve: Perm.subcontractMaterialReturnApprove,
    reverse: Perm.subcontractMaterialReturnReverse,
  );
  static const subcontractWaste = DocumentPermissionSet(
    view: Perm.subcontractWasteView,
    create: Perm.subcontractWasteCreate,
    edit: Perm.subcontractWasteEdit,
    delete: Perm.subcontractWasteDelete,
    approve: Perm.subcontractWasteApprove,
    reverse: Perm.subcontractWasteReverse,
  );
  static const subcontractBySegment = <String, DocumentPermissionSet>{
    'inquiries': subcontractInquiry,
    'applications': subcontractApplication,
    'orders': subcontractOrder,
    'receipts': subcontractReceipt,
    'material-issues': subcontractMaterialIssue,
    'returns': subcontractReturn,
    'material-returns': subcontractMaterialReturn,
    'wastes': subcontractWaste,
  };

  static const financeReceipt = DocumentPermissionSet(
    view: Perm.financeReceiptView,
    create: Perm.financeReceiptCreate,
    edit: Perm.financeReceiptEdit,
    delete: Perm.financeReceiptDelete,
    approve: Perm.financeReceiptApprove,
    reverse: Perm.financeReceiptReverse,
  );
  static const financePayment = DocumentPermissionSet(
    view: Perm.financePaymentView,
    create: Perm.financePaymentCreate,
    edit: Perm.financePaymentEdit,
    delete: Perm.financePaymentDelete,
    approve: Perm.financePaymentApprove,
    reverse: Perm.financePaymentReverse,
  );
  static const financeExpense = DocumentPermissionSet(
    view: Perm.financeExpenseView,
    create: Perm.financeExpenseCreate,
    edit: Perm.financeExpenseEdit,
    delete: Perm.financeExpenseDelete,
    approve: Perm.financeExpenseApprove,
    reverse: Perm.financeExpenseReverse,
  );
  static const financeOtherIncome = DocumentPermissionSet(
    view: Perm.financeOtherIncomeView,
    create: Perm.financeOtherIncomeCreate,
    edit: Perm.financeOtherIncomeEdit,
    delete: Perm.financeOtherIncomeDelete,
    approve: Perm.financeOtherIncomeApprove,
    reverse: Perm.financeOtherIncomeReverse,
  );
  static const financeBankTransfer = DocumentPermissionSet(
    view: Perm.financeBankTransferView,
    create: Perm.financeBankTransferCreate,
    edit: Perm.financeBankTransferEdit,
    delete: Perm.financeBankTransferDelete,
    approve: Perm.financeBankTransferApprove,
    reverse: Perm.financeBankTransferReverse,
  );
  static const financeBySegment = <String, DocumentPermissionSet>{
    'receipts': financeReceipt,
    'payments': financePayment,
    'expenses': financeExpense,
    'incomes': financeOtherIncome,
    'bank-transfers': financeBankTransfer,
  };

  static const stockDocument = DocumentPermissionSet(
    view: Perm.stockDocView,
    create: Perm.stockDocCreate,
    edit: Perm.stockDocEdit,
    delete: Perm.stockDocDelete,
    approve: Perm.stockDocApprove,
    reverse: Perm.stockDocReverse,
  );
  static const stockBySegment = <String, DocumentPermissionSet>{
    'TRANSFER': stockDocument,
    'OTHER_IN': stockDocument,
    'OTHER_OUT': stockDocument,
    'DRAW': stockDocument,
    'WDRAW': stockDocument,
    'FINISHED_IN': stockDocument,
    'FINISHED_OUT': stockDocument,
    'CHECK': stockDocument,
  };

  static const productionDailyReport = DocumentPermissionSet(
    view: Perm.productionDailyReportView,
    create: Perm.productionDailyReportCreate,
    edit: Perm.productionDailyReportEdit,
    delete: Perm.productionDailyReportDelete,
    approve: Perm.productionDailyReportApprove,
    reverse: Perm.productionDailyReportReverse,
  );
  static const productionBySegment = <String, DocumentPermissionSet>{
    'daily-reports': productionDailyReport,
  };
}
