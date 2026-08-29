package com.uten.imp.security;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimPolicy;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.subcontract.SubcontractDocumentAccessPolicy;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import org.aopalliance.intercept.MethodInvocation;
import org.junit.jupiter.api.Test;
import org.mockito.Answers;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.authorization.AuthorizationDecision;
import org.springframework.security.authorization.method.PreAuthorizeAuthorizationManager;
import org.springframework.test.util.ReflectionTestUtils;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.Arrays;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class DocumentActionPermissionContractTest {

    private static final List<StandardDocument> STANDARD_DOCUMENTS = List.of(
            doc("com.uten.imp.features.sales.quote.SalesQuoteController",
                    "com.uten.imp.features.sales.quote.SalesQuoteService", "sales_quote"),
            doc("com.uten.imp.features.sales.order.SalesOrderController",
                    "com.uten.imp.features.sales.order.SalesOrderService", "sales_order"),
            doc("com.uten.imp.features.sales.shipment.SalesShipmentController",
                    "com.uten.imp.features.sales.shipment.SalesShipmentService", "sales_shipment"),
            doc("com.uten.imp.features.sales.other_shipment.SalesOtherShipmentController",
                    "com.uten.imp.features.sales.other_shipment.SalesOtherShipmentService",
                    "sales_other_shipment"),
            doc("com.uten.imp.features.sales.ret.SalesReturnController",
                    "com.uten.imp.features.sales.ret.SalesReturnService", "sales_return"),
            doc("com.uten.imp.features.purchase.receipt.PurchaseReceiptController",
                    "com.uten.imp.features.purchase.receipt.PurchaseReceiptService",
                    "purchase_receipt"),
            doc("com.uten.imp.features.purchase.ret.PurchaseReturnController",
                    "com.uten.imp.features.purchase.ret.PurchaseReturnService", "purchase_return"),
            doc("com.uten.imp.features.subcontract.inquiry.SubcontractInquiryController",
                    "com.uten.imp.features.subcontract.inquiry.SubcontractInquiryService",
                    "subcontract_inquiry"),
            doc("com.uten.imp.features.subcontract.receipt.SubcontractReceiptController",
                    "com.uten.imp.features.subcontract.receipt.SubcontractReceiptService",
                    "subcontract_receipt"),
            doc("com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueController",
                    "com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService",
                    "subcontract_material_issue"),
            doc("com.uten.imp.features.subcontract.ret.SubcontractReturnController",
                    "com.uten.imp.features.subcontract.ret.SubcontractReturnService",
                    "subcontract_return"),
            doc("com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnController",
                    "com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService",
                    "subcontract_material_return"),
            doc("com.uten.imp.features.subcontract.waste.SubcontractWasteController",
                    "com.uten.imp.features.subcontract.waste.SubcontractWasteService",
                    "subcontract_waste"),
            doc("com.uten.imp.features.finance.receipt.FinanceReceiptController",
                    "com.uten.imp.features.finance.receipt.FinanceReceiptService",
                    "finance_receipt"),
            doc("com.uten.imp.features.finance.payment.FinancePaymentController",
                    "com.uten.imp.features.finance.payment.FinancePaymentService",
                    "finance_payment"),
            doc("com.uten.imp.features.finance.expense.FinanceExpenseController",
                    "com.uten.imp.features.finance.expense.FinanceExpenseService",
                    "finance_expense"),
            doc("com.uten.imp.features.finance.other_income.FinanceOtherIncomeController",
                    "com.uten.imp.features.finance.other_income.FinanceOtherIncomeService",
                    "finance_other_income"),
            doc("com.uten.imp.features.finance.bank_transfer.FinanceBankTransferController",
                    "com.uten.imp.features.finance.bank_transfer.FinanceBankTransferService",
                    "finance_bank_transfer"),
            doc("com.uten.imp.features.stock.StockDocController",
                    "com.uten.imp.features.stock.StockDocService", "stock_doc"),
            doc("com.uten.imp.features.production.dailyreport.ProductionDailyReportController",
                    "com.uten.imp.features.production.dailyreport.ProductionDailyReportService",
                    "production_daily_report"));

    @Test
    void standardLifecycleUsesOneExactActionAtControllerAndService() {
        for (StandardDocument document : STANDARD_DOCUMENTS) {
            assertGate(document.controller(), "create",
                    authority(document.prefix() + ":create"));
            assertGate(document.service(), "create",
                    authority(document.prefix() + ":create"));
            assertGate(document.controller(), "update",
                    authority(document.prefix() + ":edit"));
            assertGate(document.service(), "update",
                    authority(document.prefix() + ":edit"));
            assertGate(document.controller(), "delete",
                    authority(document.prefix() + ":delete"));
            assertGate(document.service(), "delete",
                    authority(document.prefix() + ":delete"));
            assertGate(document.controller(), "approve",
                    authority(document.prefix() + ":approve"));
            assertGate(document.service(), "approve",
                    authority(document.prefix() + ":approve"));
            assertGate(document.controller(), "reverse",
                    authority(document.prefix() + ":reverse"));
            assertGate(document.service(), "reverse",
                    authority(document.prefix() + ":reverse"));
        }
    }

    @Test
    void conversionsOrdersAndSpecialActionsKeepTheirExactMultiLayerGates() {
        String convert = authority("sales_quote:convert")
                + " and " + authority("sales_order:create");
        assertGate(type("com.uten.imp.features.sales.quote.SalesQuoteController"),
                "convert", convert);
        assertGate(type("com.uten.imp.features.sales.quote.SalesQuoteService"),
                "convertToOrder", convert);
        assertGate(type("com.uten.imp.features.sales.order.SalesOrderService"),
                "createFromQuote", convert);

        Class<?> salesOrderController =
                type("com.uten.imp.features.sales.order.SalesOrderController");
        Class<?> salesOrderService =
                type("com.uten.imp.features.sales.order.SalesOrderService");
        assertGate(salesOrderController, "setStopped", authority("sales_order:stop"));
        assertGate(salesOrderService, "toggleStopped", authority("sales_order:stop"));
        assertGate(salesOrderController, "changeQty", authority("sales_order:change_qty"));
        assertGate(salesOrderService, "changeQty", authority("sales_order:change_qty"));
        assertGate(salesOrderController, "cancel", authority("sales_order:cancel"));
        assertGate(salesOrderService, "cancel", authority("sales_order:cancel"));

        String purchaseCreate = authority("purchase_order:create")
                + " and " + authority("purchase_order:decompose");
        for (String method : List.of("create", "createBatch")) {
            assertGate(type("com.uten.imp.features.purchase.order.PurchaseOrderController"),
                    method, purchaseCreate);
            assertGate(type("com.uten.imp.features.purchase.order.PurchaseOrderService"),
                    method, purchaseCreate);
        }

        for (String method : List.of("create", "createBatch")) {
            assertGate(type("com.uten.imp.features.subcontract.order.SubcontractOrderController"),
                    method, authority("subcontract_order:create"));
            assertGate(type("com.uten.imp.features.subcontract.order.SubcontractOrderService"),
                    method, authority("subcontract_order:create"));
        }

        assertGate(type("com.uten.imp.features.stock.StockDocController"),
                "issue", authority("stock_doc:issue"));
        assertGate(type("com.uten.imp.features.stock.StockDocService"),
                "issue", authority("stock_doc:issue"));
        assertGate(type("com.uten.imp.features.stock.StockDocController"),
                "reverseIssue", authority("stock_doc:reverse_issue"));
        assertGate(type("com.uten.imp.features.stock.StockDocService"),
                "reverseIssue", authority("stock_doc:reverse_issue"));
        assertGate(type("com.uten.imp.features.finance.expense.FinanceExpenseController"),
                "glConfirm", authority("finance_expense:gl_confirm"));
        assertGate(type("com.uten.imp.features.finance.expense.FinanceExpenseService"),
                "glConfirm", authority("finance_expense:gl_confirm"));
        String stockIn = authority("warehouse_inbound:view")
                + " and " + authority("warehouse_inbound:stock_in");
        assertGate(type("com.uten.imp.features.warehouse.inbound.WarehouseInboundController"),
                "stockInAccepted", stockIn);
        assertGate(type("com.uten.imp.features.warehouse.inbound.ProcurementArrivalControlService"),
                "stockInWithDecisionSession", authority("warehouse_inbound:stock_in"));
        assertGate(type("com.uten.imp.features.purchase.receipt.PurchaseReceiptService"),
                "approveFromWarehouseDecision", authority("warehouse_inbound:stock_in"));
        assertGate(type("com.uten.imp.features.subcontract.receipt.SubcontractReceiptService"),
                "approveFromWarehouseDecision", authority("warehouse_inbound:stock_in"));
    }

    @Test
    void productionCommandsRequireTheirExactActionAndRejectLegacyPlanEdit() {
        Class<?> execution = type(
                "com.uten.imp.features.production.execution."
                        + "ProductionExecutionSegmentController");
        assertExactGateRejectsLegacy(
                execution, "assign", "production_execution:assign");
        assertExactGateRejectsLegacy(
                execution, "releaseDefer", "production_execution:release_defer");
        assertExactGateRejectsLegacy(
                execution, "dispatch", "production_execution:dispatch");
        assertExactGateRejectsLegacy(
                execution, "start", "production_execution:start");
        assertExactGateRejectsLegacy(
                execution, "cancel", "production_execution:cancel");
        assertExactGateRejectsLegacy(
                execution, "reverse", "production_execution:reverse");

        Class<?> mrp = type("com.uten.imp.features.production.mrp.MrpController");
        assertExactGateRejectsLegacy(
                mrp, "generate", "production_mrp:generate_purchase");
        assertExactGateRejectsLegacy(
                mrp, "generatePlanningPackage",
                "production_planning_package:generate");
        assertExactGateRejectsLegacy(
                mrp, "generatePlanningPackageFullTree",
                "production_planning_package:generate");
        assertExactGateRejectsLegacy(
                mrp, "savePlanningDraft",
                "production_planning_package:draft_edit");
        assertExactGateRejectsLegacy(
                mrp, "cancelPlanningPackage",
                "production_planning_package:cancel");
        assertExactGateRejectsLegacy(
                mrp, "reversePlanningPackage",
                "production_planning_package:reverse");

        Class<?> material = type(
                "com.uten.imp.features.stock.allocation."
                        + "ProductionMaterialSettlementController");
        assertExactGateRejectsLegacy(
                material, "settle", "production_material:settle");
        assertExactGateRejectsLegacy(
                material, "reverseSettlement", "production_material:reverse");
        assertExactGateRejectsLegacy(
                material, "close", "production_material:close");
    }


    @Test
    void fulfillmentClaimsSplitEditAndApproveWithoutLegacyUmbrella() {
        assertThat(TaskClaimPolicy.of("FULFILLMENT_TASK_EDIT").claimPermission())
                .isEqualTo("stock_doc:edit");
        assertThat(TaskClaimPolicy.of("FULFILLMENT_TASK_APPROVE").claimPermission())
                .isEqualTo("stock_doc:approve");
        assertThatThrownBy(() -> TaskClaimPolicy.of("FULFILLMENT_TASK"))
                .isInstanceOf(ApiException.class);
    }


    @Test
    void financeApproveAndRejectAreIndependentAtEveryCommandLayer() {
        assertDecisionGate(
                "com.uten.imp.features.purchase.order.PurchaseOrderController",
                "com.uten.imp.features.purchase.order.PurchaseOrderFinanceDecisionCommandService");
        assertDecisionGate(
                "com.uten.imp.features.subcontract.order.SubcontractOrderController",
                "com.uten.imp.features.subcontract.order.SubcontractOrderFinanceDecisionCommandService");
        assertGate(type("com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService"),
                "approve", authority("finance_order_approval:approve"));
        assertGate(type("com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService"),
                "reject", authority("finance_order_approval:reject"));
        assertGate(type("com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService"),
                "approveBatch", authority("finance_order_approval:approve"));
        assertGate(type("com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService"),
                "rejectBatch", authority("finance_order_approval:reject"));
    }

    @Test
    void purchaseCreationRejectsEitherSingleHalfOfTheRequiredGate() throws Exception {
        Method create = type("com.uten.imp.features.purchase.order.PurchaseOrderService")
                .getMethod(
                        "create",
                        type("com.uten.imp.features.purchase.order.dto.OrderSaveRequest"));

        assertThat(authorize(create, "purchase_order:create").isGranted()).isFalse();
        assertThat(authorize(create, "purchase_order:decompose").isGranted()).isFalse();
        assertThat(authorize(
                create,
                "purchase_order:create",
                "purchase_order:decompose").isGranted()).isTrue();
    }

    @Test
    void subcontractManualCreateNeedsNoDecomposeButSourcedCreateDoes() {
        SubcontractDocumentAccessPolicy access =
                mock(SubcontractDocumentAccessPolicy.class);
        AtomicReference<Set<String>> grants =
                new AtomicReference<>(Set.of("subcontract_order:create"));
        when(access.hasAuthority(anyString()))
                .thenAnswer(invocation -> grants.get().contains(invocation.getArgument(0)));

        SubcontractOrderService service =
                mock(SubcontractOrderService.class, Answers.CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service, "access", access);

        OrderItemLine manualLine = new OrderItemLine();
        OrderSaveRequest manual = new OrderSaveRequest();
        manual.setItems(List.of(manualLine));
        assertThatCode(() -> ReflectionTestUtils.invokeMethod(
                service, "requireDecompositionAuthorityIfNeeded", manual))
                .doesNotThrowAnyException();

        OrderItemLine sourcedLine = new OrderItemLine();
        sourcedLine.setApplicationItemId(UUID.randomUUID());
        OrderSaveRequest sourced = new OrderSaveRequest();
        sourced.setItems(List.of(sourcedLine));
        assertThatThrownBy(() -> ReflectionTestUtils.invokeMethod(
                service, "requireDecompositionAuthorityIfNeeded", sourced))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("分解订货单");

        grants.set(Set.of(
                "subcontract_order:create",
                "subcontract_order:decompose"));
        assertThatCode(() -> ReflectionTestUtils.invokeMethod(
                service, "requireDecompositionAuthorityIfNeeded", sourced))
                .doesNotThrowAnyException();
    }

    @Test
    void salesWritableAcceptsObjectActionsButRejectsCreateOnly() {
        List<WritableDocument> documents = List.of(
                writable("com.uten.imp.features.sales.quote.SalesQuoteService",
                        "sales_quote:delete", "sales_quote:create"),
                writable("com.uten.imp.features.sales.order.SalesOrderService",
                        "sales_order:approve", "sales_order:create"),
                writable("com.uten.imp.features.sales.shipment.SalesShipmentService",
                        "sales_shipment:reverse", "sales_shipment:create"),
                writable("com.uten.imp.features.sales.other_shipment.SalesOtherShipmentService",
                        "sales_other_shipment:approve", "sales_other_shipment:create"),
                writable("com.uten.imp.features.sales.ret.SalesReturnService",
                        "sales_return:disposition", "sales_return:create"));

        for (WritableDocument document : documents) {
            SalesDocumentAccessPolicy access = mock(SalesDocumentAccessPolicy.class);
            AtomicReference<Set<String>> grants =
                    new AtomicReference<>(Set.of(document.objectAction()));
            when(access.hasAuthority(anyString()))
                    .thenAnswer(invocation -> grants.get().contains(invocation.getArgument(0)));
            Object service = mock(document.service(), Answers.CALLS_REAL_METHODS);
            ReflectionTestUtils.setField(service, "accessPolicy", access);

            assertThat((Boolean) ReflectionTestUtils.invokeMethod(
                    service, "hasObjectActionAuthority")).isTrue();
            grants.set(Set.of(document.createAction()));
            assertThat((Boolean) ReflectionTestUtils.invokeMethod(
                    service, "hasObjectActionAuthority")).isFalse();
        }
    }

    private static void assertDecisionGate(
            String controllerName, String commandServiceName) {
        assertGate(type(controllerName), "approve",
                authority("finance_order_approval:approve"));
        assertGate(type(commandServiceName), "approve",
                authority("finance_order_approval:approve"));
        assertGate(type(controllerName), "reject",
                authority("finance_order_approval:reject"));
        assertGate(type(commandServiceName), "reject",
                authority("finance_order_approval:reject"));
    }

    private static void assertExactGateRejectsLegacy(
            Class<?> type, String methodName, String permission) {
        assertGate(type, methodName, authority(permission));
        Method method = Arrays.stream(type.getDeclaredMethods())
                .filter(candidate -> Modifier.isPublic(candidate.getModifiers()))
                .filter(candidate -> candidate.getName().equals(methodName))
                .findFirst()
                .orElseThrow();
        assertThat(authorize(method, permission).isGranted())
                .as(type.getSimpleName() + "." + methodName + " exact authority")
                .isTrue();
        assertThat(authorize(method, "production_plan:edit").isGranted())
                .as(type.getSimpleName() + "." + methodName + " legacy edit")
                .isFalse();
    }


    private static void assertGate(
            Class<?> type, String methodName, String expected) {
        List<Method> matches = Arrays.stream(type.getDeclaredMethods())
                .filter(method -> Modifier.isPublic(method.getModifiers()))
                .filter(method -> method.getName().equals(methodName))
                .toList();
        assertThat(matches)
                .as(type.getSimpleName() + "." + methodName)
                .hasSize(1);
        PreAuthorize annotation = matches.getFirst().getAnnotation(PreAuthorize.class);
        assertThat(annotation)
                .as(type.getSimpleName() + "." + methodName + " @PreAuthorize")
                .isNotNull();
        // 允许在精确权限之上用 "and ..." 追加收紧条件（如客户预收可见性），
        // 但不得替换、省略或用 or 放宽基础动作权限。
        assertThat(annotation.value())
                .as(type.getSimpleName() + "." + methodName + " gate")
                .satisfiesAnyOf(
                        actual -> assertThat(actual).isEqualTo(expected),
                        actual -> assertThat(actual)
                                .startsWith(expected + " and "));
    }

    private static AuthorizationDecision authorize(
            Method method, String... authorities) {
        TestingAuthenticationToken authentication =
                new TestingAuthenticationToken("permission-user", null, authorities);
        authentication.setAuthenticated(true);
        MethodInvocation invocation = mock(MethodInvocation.class);
        when(invocation.getMethod()).thenReturn(method);
        when(invocation.getThis()).thenReturn(mock(method.getDeclaringClass()));
        when(invocation.getArguments()).thenReturn(new Object[]{mock(method.getParameterTypes()[0])});
        return new PreAuthorizeAuthorizationManager()
                .check(() -> authentication, invocation);
    }

    private static StandardDocument doc(
            String controller, String service, String prefix) {
        return new StandardDocument(type(controller), type(service), prefix);
    }

    private static WritableDocument writable(
            String service, String objectAction, String createAction) {
        return new WritableDocument(type(service), objectAction, createAction);
    }

    private static Class<?> type(String className) {
        try {
            return Class.forName(className);
        } catch (ClassNotFoundException error) {
            throw new AssertionError(error);
        }
    }

    private static String authority(String permission) {
        return "hasAuthority('" + permission + "')";
    }

    private record StandardDocument(
            Class<?> controller, Class<?> service, String prefix) {
    }

    private record WritableDocument(
            Class<?> service, String objectAction, String createAction) {
    }
}
