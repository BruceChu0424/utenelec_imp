package com.uten.imp.features.org.employee;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;

/** Internal resource contexts reuse existing authorities; never new grantable permission codes. */
public enum BusinessEmployeeReferencePurpose {
    WAREHOUSE_ARRIVAL_RECEIVER(List.of(Set.of("warehouse_inbound:view","warehouse_inbound:stock_in")),Set.of("warehouse_inbound:view")),
    WAREHOUSE_SUBCONTRACT_OPERATOR(List.of(Set.of("subcontract_outbound:view","subcontract_outbound:execute","subcontract_material_issue:view","subcontract_material_issue:edit")),Set.of("subcontract_outbound:view","subcontract_material_issue:view")),
    WORKSHOP_MATERIAL_ISSUER(List.of(Set.of("workshop_material:issue")),Set.of("workshop_material:view")),
    PURCHASE_REQUEST_PERSON(List.of(),Set.of("purchase_request:view")),
    PURCHASE_ORDER_PERSON(List.of(Set.of("purchase_order:create"),Set.of("purchase_order:edit")),Set.of("purchase_order:view")),
    PURCHASE_RECEIPT_PERSON(List.of(Set.of("purchase_receipt:create"),Set.of("purchase_receipt:edit")),Set.of("purchase_receipt:view")),
    PURCHASE_RETURN_PERSON(List.of(Set.of("purchase_return:create"),Set.of("purchase_return:edit")),Set.of("purchase_return:view")),
    SUBCONTRACT_INQUIRY_PERSON(List.of(),Set.of("subcontract_inquiry:view")),
    SUBCONTRACT_APPLICATION_PERSON(List.of(),Set.of("subcontract_application:view")),
    SUBCONTRACT_ORDER_PERSON(List.of(Set.of("subcontract_order:create"),Set.of("subcontract_order:edit")),Set.of("subcontract_order:view")),
    SUBCONTRACT_RECEIPT_PERSON(List.of(Set.of("subcontract_receipt:create"),Set.of("subcontract_receipt:edit")),Set.of("subcontract_receipt:view")),
    SUBCONTRACT_MATERIAL_ISSUE_PERSON(List.of(Set.of("subcontract_material_issue:edit")),Set.of("subcontract_material_issue:view")),
    SUBCONTRACT_RETURN_PERSON(List.of(Set.of("subcontract_return:create"),Set.of("subcontract_return:edit")),Set.of("subcontract_return:view")),
    SUBCONTRACT_MATERIAL_RETURN_PERSON(List.of(Set.of("subcontract_material_return:create"),Set.of("subcontract_material_return:edit")),Set.of("subcontract_material_return:view")),
    SUBCONTRACT_WASTE_PERSON(List.of(Set.of("subcontract_waste:create"),Set.of("subcontract_waste:edit")),Set.of("subcontract_waste:view")),
    SALES_QUOTE_PERSON(List.of(Set.of("sales_quote:create"),Set.of("sales_quote:edit")),Set.of("sales_quote:view")),
    SALES_ORDER_PERSON(List.of(Set.of("sales_order:create"),Set.of("sales_order:edit")),Set.of("sales_order:view")),
    SALES_SHIPMENT_PERSON(List.of(Set.of("sales_shipment:create"),Set.of("sales_shipment:edit")),Set.of("sales_shipment:view")),
    SALES_OTHER_SHIPMENT_PERSON(List.of(Set.of("sales_other_shipment:create"),Set.of("sales_other_shipment:edit")),Set.of("sales_other_shipment:view")),
    SALES_RETURN_PERSON(List.of(Set.of("sales_return:create"),Set.of("sales_return:edit")),Set.of("sales_return:view")),
    FINANCE_RECEIPT_PERSON(List.of(Set.of("finance_receipt:create"),Set.of("finance_receipt:edit")),Set.of("finance_receipt:view")),
    FINANCE_PAYMENT_PERSON(List.of(Set.of("finance_payment:create"),Set.of("finance_payment:edit")),Set.of("finance_payment:view")),
    FINANCE_EXPENSE_PERSON(List.of(Set.of("finance_expense:create"),Set.of("finance_expense:edit")),Set.of("finance_expense:view")),
    FINANCE_OTHER_INCOME_PERSON(List.of(Set.of("finance_other_income:create"),Set.of("finance_other_income:edit")),Set.of("finance_other_income:view")),
    FINANCE_BANK_TRANSFER_PERSON(List.of(Set.of("finance_bank_transfer:create"),Set.of("finance_bank_transfer:edit")),Set.of("finance_bank_transfer:view")),
    FINANCE_ASSET_CUSTODIAN(List.of(Set.of("finance_asset:edit")),Set.of("finance_asset:view")),
    FINANCE_AUXILIARY_PARTY(List.of(Set.of("payment_style:edit","finance_report:view","finance:view:all")),Set.of()),
    FINANCE_EXPENSE_ATTRIBUTION(List.of(Set.of("payment_style:edit","finance_report:view","finance:view:all")),Set.of()),
    FINANCE_APPLICATION_REVIEWER(List.of(Set.of("expense:settings")),Set.of()),
    SUPPLIER_OWNER(List.of(Set.of("supplier:create"),Set.of("supplier:edit")),Set.of("supplier:view")),
    MOULD_CUSTODIAN(List.of(Set.of("mould_category:create"),Set.of("mould_category:edit")),Set.of("mould_category:view")),
    PRODUCTION_PLAN_OWNER(List.of(Set.of("production_material_analysis:create"),Set.of("production_plan:create"),Set.of("production_plan:edit")),Set.of("production_plan:view")),
    PRODUCTION_SEGMENT_OWNER(List.of(Set.of("production_execution:assign")),Set.of("production_plan:view")),
    PRODUCTION_REPORT_WORKER(List.of(Set.of("production_daily_report:create"),Set.of("production_daily_report:edit")),Set.of("production_daily_report:view")),
    PRODUCTION_MATERIAL_OWNER(List.of(Set.of("production_material_analysis:view","production_material_analysis:generate"),Set.of("production_material_analysis:view","production_material_analysis:notify")),Set.of("production_material_analysis:view")),
    SALES_ORDER_SELLER_FILTER(List.of(Set.of("sales_order:view")),Set.of("sales_order:view")),
    DEPARTMENT_MANAGER(List.of(Set.of("department:manager_assign")),Set.of("department:view"));

    private final List<Set<String>> candidateAuthorityGroups;
    private final Set<String> echoAuthorities;
    BusinessEmployeeReferencePurpose(List<Set<String>> candidates,Set<String> echoAuthorities) {
        this.candidateAuthorityGroups=List.copyOf(candidates);
        this.echoAuthorities=Set.copyOf(echoAuthorities);
    }
    /** Alternatives are OR; authorities inside one alternative are AND. Empty means no candidate operation. */
    public List<Set<String>> candidateAuthorityGroups() {return candidateAuthorityGroups;}
    public Set<String> echoAuthorities() {return echoAuthorities;}
    /** Informational union; authorization must retain candidateAuthorityGroups' AND/OR structure. */
    public Set<String> authorities() {return candidateAuthorityGroups.stream().flatMap(Set::stream).collect(Collectors.toUnmodifiableSet());}
    public boolean mayListCandidates(Set<String> current) {return candidateAuthorityGroups.stream().anyMatch(current::containsAll);}
    public boolean mayEcho(Set<String> current) {return mayListCandidates(current)||echoAuthorities.stream().anyMatch(current::contains);}
    public static BusinessEmployeeReferencePurpose parse(String value) {
        try {return valueOf(value==null?"":value);}
        catch(IllegalArgumentException invalid) {throw new ApiException(ErrorCode.VALIDATION_FAILED,"人员引用业务场景无效");}
    }
}
