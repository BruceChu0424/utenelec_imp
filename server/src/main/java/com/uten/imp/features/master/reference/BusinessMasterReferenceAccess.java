package com.uten.imp.features.master.reference;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.application.port.CurrentStaffAuthorityPort;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.Set;

/** Auxiliary references follow the existing business capability, never grant master-data access. */
@Component
@RequiredArgsConstructor
public class BusinessMasterReferenceAccess {
    private final CurrentStaffAuthorityPort staff;
    private static final Set<String> DOCUMENT_ACTIONS = Set.of("view", "create", "edit", "approve", "confirm", "execute",
            "stock_in", "issue", "assign", "generate", "notify", "submit", "request", "count", "choose", "setup", "reopen");
    private static final Set<String> SUPPLIER_CONTEXTS = Set.of(
            "purchase_order", "purchase_request", "purchase_receipt", "purchase_return",
            "subcontract_order", "subcontract_receipt", "subcontract_return", "subcontract_material_issue",
            "subcontract_material_return", "subcontract_waste", "supplier_settlement", "supplier_credit",
            "finance_receipt", "finance_payment", "finance_expense", "finance_other_income", "finance_bank_transfer",
            "finance_statement", "finance_asset", "warehouse_inbound");
    private static final Set<String> CLIENT_CONTEXTS = Set.of(
            "sales_quote", "sales_order", "sales_shipment", "sales_other_shipment", "sales_return",
            "finance_receipt", "finance_payment", "finance_expense", "finance_other_income", "finance_bank_transfer",
            "finance_statement", "client_settlement", "warehouse_sales_outbound");
    private static final Set<String> GOODS_CONTEXTS = Set.of(
            "sales_quote", "sales_order", "sales_shipment", "sales_other_shipment", "sales_return",
            "purchase_order", "purchase_request", "purchase_receipt", "purchase_return",
            "subcontract_order", "subcontract_receipt", "subcontract_return", "subcontract_material_issue",
            "subcontract_material_return", "subcontract_waste", "production_plan", "production_material_analysis",
            "production_material", "production_execution", "production_daily_report", "workshop_material",
            "warehouse_inbound", "warehouse_sales_outbound", "warehouse_other_inbound", "warehouse_other_outbound",
            "warehouse_transfer", "stock_doc", "stock_count", "goods", "mould", "mould_category", "production_material_discovery");

    public void require(String resource) {
        if (!canRead(resource)) {
            throw new ApiException(ErrorCode.FORBIDDEN, "没有此业务所需的资料选择权限");
        }
    }

    public boolean canRead(String resource) {
        return allowed(resource, staff.currentStaffPermissions());
    }

    public boolean canReadMasterGoods() {
        return staff.currentStaffPermissions().contains("goods:view");
    }

    public static boolean allowed(String resource, Set<String> granted) {
        return switch (resource) {
            case "supplier" -> granted.contains("supplier:view") || granted.contains("application:apply")
                    || granted.contains("application:apply:prepayment") || granted.contains("application:apply:supplier_payment")
                    || document(granted, SUPPLIER_CONTEXTS);
            case "client" -> granted.contains("client:view") || document(granted, CLIENT_CONTEXTS);
            case "goods" -> granted.contains("goods:view") || granted.contains("stock:view")
                    || granted.contains("stock:count:submit") || granted.contains("stock:count:finance_review")
                    || granted.contains("stock:count:warehouse_review") || granted.contains("goods:cost:edit")
                    || document(granted, GOODS_CONTEXTS);
            case "unit" -> granted.contains("unit:view") || allowed("goods", granted);
            case "warehouse" -> granted.contains("warehouse:view") || allowed("goods", granted);
            case "terms" -> granted.contains("currency:view") || granted.contains("payment_style:view")
                    || allowed("supplier", granted) || allowed("client", granted) || allowed("account", granted)
                    || granted.contains("employee:compensation:edit") || granted.contains("payroll:generate");
            case "department" -> granted.contains("department:view") || granted.contains("department:manager_assign")
                    || granted.contains("employee:view") || granted.contains("mould:edit")
                    || allowed("supplier", granted) || allowed("client", granted) || allowed("goods", granted)
                    || allowed("account", granted);
            case "account" -> granted.contains("account:view") || granted.contains("expense:pay")
                    || granted.contains("subcontract_loss_claim:fulfill") || granted.contains("subcontract_loss_claim:view")
                    || document(granted, Set.of(
                    "finance_receipt", "finance_payment", "finance_expense", "finance_other_income",
                    "finance_bank_transfer", "finance_statement", "finance_asset", "expense"));
            default -> false;
        };
    }

    private static boolean document(Set<String> granted, Set<String> contexts) {
        return contexts.stream().anyMatch(context -> DOCUMENT_ACTIONS.stream()
                .anyMatch(action -> granted.contains(context + ":" + action)));
    }
}
