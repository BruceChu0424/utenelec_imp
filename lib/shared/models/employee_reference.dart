/// Minimal personnel identity for an already-authorized business operation.
/// Account/employment status are facts, not a substitute for command eligibility.
enum EmployeeReferencePurpose {
  warehouseArrivalReceiver('WAREHOUSE_ARRIVAL_RECEIVER'),
  warehouseSubcontractOperator('WAREHOUSE_SUBCONTRACT_OPERATOR'),
  workshopMaterialIssuer('WORKSHOP_MATERIAL_ISSUER'),
  purchaseRequestPerson('PURCHASE_REQUEST_PERSON'),
  purchaseOrderPerson('PURCHASE_ORDER_PERSON'),
  purchaseReceiptPerson('PURCHASE_RECEIPT_PERSON'),
  purchaseReturnPerson('PURCHASE_RETURN_PERSON'),
  subcontractInquiryPerson('SUBCONTRACT_INQUIRY_PERSON'),
  subcontractApplicationPerson('SUBCONTRACT_APPLICATION_PERSON'),
  subcontractOrderPerson('SUBCONTRACT_ORDER_PERSON'),
  subcontractReceiptPerson('SUBCONTRACT_RECEIPT_PERSON'),
  subcontractMaterialIssuePerson('SUBCONTRACT_MATERIAL_ISSUE_PERSON'),
  subcontractReturnPerson('SUBCONTRACT_RETURN_PERSON'),
  subcontractMaterialReturnPerson('SUBCONTRACT_MATERIAL_RETURN_PERSON'),
  subcontractWastePerson('SUBCONTRACT_WASTE_PERSON'),
  salesQuotePerson('SALES_QUOTE_PERSON'),
  salesOrderPerson('SALES_ORDER_PERSON'),
  salesShipmentPerson('SALES_SHIPMENT_PERSON'),
  salesOtherShipmentPerson('SALES_OTHER_SHIPMENT_PERSON'),
  salesReturnPerson('SALES_RETURN_PERSON'),
  financeReceiptPerson('FINANCE_RECEIPT_PERSON'),
  financePaymentPerson('FINANCE_PAYMENT_PERSON'),
  financeExpensePerson('FINANCE_EXPENSE_PERSON'),
  financeOtherIncomePerson('FINANCE_OTHER_INCOME_PERSON'),
  financeBankTransferPerson('FINANCE_BANK_TRANSFER_PERSON'),
  financeAssetCustodian('FINANCE_ASSET_CUSTODIAN'),
  financeAuxiliaryParty('FINANCE_AUXILIARY_PARTY'),
  financeExpenseAttribution('FINANCE_EXPENSE_ATTRIBUTION'),
  financeApplicationReviewer('FINANCE_APPLICATION_REVIEWER'),
  supplierOwner('SUPPLIER_OWNER'),
  mouldCustodian('MOULD_CUSTODIAN'),
  productionPlanOwner('PRODUCTION_PLAN_OWNER'),
  productionSegmentOwner('PRODUCTION_SEGMENT_OWNER'),
  productionReportWorker('PRODUCTION_REPORT_WORKER'),
  productionMaterialOwner('PRODUCTION_MATERIAL_OWNER'),
  salesOrderSellerFilter('SALES_ORDER_SELLER_FILTER'),
  departmentManager('DEPARTMENT_MANAGER');

  const EmployeeReferencePurpose(this.apiValue);
  final String apiValue;
}

class EmployeeReference {
  const EmployeeReference({
    required this.id,
    required this.code,
    required this.fullName,
    required this.departmentId,
    required this.departmentName,
    required this.status,
    required this.accountStatus,
    required this.positionName,
  });

  final String id;
  final String code;
  final String fullName;
  final String? departmentId;
  final String? departmentName;
  final String status;
  final String? accountStatus;
  final String? positionName;

  factory EmployeeReference.fromJson(Map<String, dynamic> json) =>
      EmployeeReference(
        id: json['id'] as String,
        code: json['code'] as String,
        fullName: json['fullName'] as String,
        departmentId: json['departmentId'] as String?,
        departmentName: json['departmentName'] as String?,
        status: json['status'] as String,
        accountStatus: json['accountStatus'] as String?,
        positionName: json['positionName'] as String?,
      );
}
