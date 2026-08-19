package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.annotation.JsonSerialize;
import com.fasterxml.jackson.databind.ser.std.ToStringSerializer;
import com.uten.imp.application.port.ProcurementArrivalBlockedException;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.ArrivalExceptionTask;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.RecordComponent;
import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.OffsetDateTime;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

class ProcurementArrivalWorkflowContractTest {

    @Test
    void ownerSurfaceIsReturnOnlyAndUsesNarrowPermission() {
        RequestMapping mapping = ProcurementArrivalExceptionController.class
                .getAnnotation(RequestMapping.class);
        assertThat(mapping.value())
                .containsExactly("/api/procurement/arrival-exceptions");
        assertThat(ProcurementArrivalExceptionController.class
                .getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('supplier_return_task:handle')");
        assertThat(Arrays.stream(
                        ProcurementArrivalExceptionController.class
                                .getDeclaredMethods())
                .map(Method::getName))
                .containsExactlyInAnyOrder(
                        "tasks", "count", "detail", "completeReturn")
                .doesNotContain("decide");
    }

    @Test
    void financeSurfaceOwnsAllThreeDecisionActions() throws Exception {
        RequestMapping mapping =
                FinanceProcurementArrivalExceptionController.class
                        .getAnnotation(RequestMapping.class);
        assertThat(mapping.value())
                .containsExactly("/api/finance/procurement-arrival-exceptions");

        Method decision =
                FinanceProcurementArrivalExceptionController.class
                        .getDeclaredMethod(
                                "decide",
                                UUID.class,
                                ProcurementArrivalContracts
                                        .ArrivalDecisionRequest.class);
        assertThat(decision.getAnnotation(PostMapping.class).value())
                .containsExactly("/{id}/decision");
        assertThat(decision.getAnnotation(PreAuthorize.class).value())
                .contains("finance_order_approval:view")
                .contains("finance_order_approval:review");

        Method tasks =
                FinanceProcurementArrivalExceptionController.class
                        .getDeclaredMethod("tasks", int.class, int.class);
        assertThat(tasks.getAnnotation(GetMapping.class).value())
                .containsExactly("/tasks");
    }

    @Test
    void durableExceptionSurvivesTheExpected409Boundary() throws Exception {
        assertCommitsBlockedException(
                ProcurementArrivalControlService.class.getDeclaredMethod(
                        "validateBeforeApproval", String.class, UUID.class));
        assertCommitsBlockedException(
                PurchaseReceiptService.class.getDeclaredMethod(
                        "approve", UUID.class));
        assertCommitsBlockedException(
                SubcontractReceiptService.class.getDeclaredMethod(
                        "approve", UUID.class));
    }

    @Test
    void customApprovalIsStrictAfterFourDecimalNormalization()
            throws Exception {
        Method helper = ProcurementArrivalControlService.class
                .getDeclaredMethod(
                        "requireCustomApprovedExcess",
                        BigDecimal.class,
                        BigDecimal.class);
        helper.setAccessible(true);

        assertThat(helper.invoke(
                null, new BigDecimal("5.00004"), new BigDecimal("10.0000")))
                .isEqualTo(new BigDecimal("5"));
        assertInvalidCustom(helper, "0", "10");
        assertInvalidCustom(helper, "0.00001", "10");
        assertInvalidCustom(helper, "10", "10");
        assertInvalidCustom(helper, "9.99999", "10");
        assertInvalidCustom(helper, "1", "0");
    }

    @Test
    void amountSnapshotsSerializeAsDecimalStringsWithoutWebDoubleLoss()
            throws Exception {
        for (String field : List.of(
                "unitPrice",
                "declaredAmountOriginal",
                "declaredAmountLocal",
                "excessAmountLocal")) {
            RecordComponent component = Arrays.stream(
                            ArrivalExceptionTask.class.getRecordComponents())
                    .filter(candidate -> candidate.getName().equals(field))
                    .findFirst()
                    .orElseThrow();
            JsonSerialize annotation =
                    component.getAccessor().getAnnotation(JsonSerialize.class);
            assertThat(annotation).isNotNull();
            assertThat(annotation.using())
                    .isEqualTo(ToStringSerializer.class);
        }

        Object[] values = Arrays.stream(
                        ArrivalExceptionTask.class.getRecordComponents())
                .map(ProcurementArrivalWorkflowContractTest::sampleValue)
                .toArray();
        ArrivalExceptionTask task = (ArrivalExceptionTask)
                ArrivalExceptionTask.class.getDeclaredConstructors()[0]
                        .newInstance(values);
        JsonNode json = new ObjectMapper().findAndRegisterModules().valueToTree(task);

        assertThat(json.get("unitPrice").isTextual()).isTrue();
        assertThat(json.get("unitPrice").textValue())
                .isEqualTo("12345678901234.5678");
        assertThat(json.get("declaredAmountLocal").isTextual()).isTrue();
        assertThat(json.get("declaredQty").isNumber()).isTrue();
    }

    @Test
    void migrationPinsReceiptBoundAllowanceAndDatabaseGuards()
            throws Exception {
        String migration = source(
                "src/main/resources/db/migration/"
                        + "V201__procurement_arrival_exception_control.sql");

        assertThat(migration)
                .contains("'PENDING_FINANCE'")
                .contains("'APPROVE_ALL', 'APPROVE_CUSTOM', 'REJECT_EXCESS'")
                .contains("current_setting('app.procurement_arrival_receipt_id'")
                .contains("exception.receipt_id = v_current_receipt::UUID")
                .contains("exception.status = 'RECEIPT_ADJUSTED'")
                .contains("arrival_overage_posted_qty")
                .contains("CASE WHEN TG_OP = 'INSERT' THEN 0")
                .contains("BEFORE UPDATE OR DELETE ON purchase_receipt_items")
                .contains("BEFORE UPDATE OR DELETE ON subcontract_receipt_items")
                .contains("NULLIF(btrim(finance_reason), '') IS NOT NULL")
                .contains("permission.code IN ('purchase_order:view', 'subcontract_order:view')")
                .contains("permission.code = 'subcontract_receipt:edit'")
                .doesNotContain("PENDING_OWNER")
                .doesNotContain("SUPPLEMENT_REQUIRED")
                .doesNotContain("REQUEST_ALL")
                .doesNotContain("PENDING_SUPPLEMENT");
    }

    @Test
    void serviceRecomputesStaleCapacityAndAdjustsAmountsBeforePosting()
            throws Exception {
        String service = source(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "ProcurementArrivalControlService.java");

        assertThat(service)
                .contains("approvedRemaining = capacity.available()")
                .contains("SET approved_remaining_qty = ?")
                .contains("detectionApprovedRemainingQty")
                .contains("decisionApprovedRemainingQty")
                .contains("amount_original * ? / NULLIF(?, 0)")
                .contains("amount_local * ? / NULLIF(?, 0)")
                .contains("LEAST(check_qty, ?)")
                .contains("girth_qty * ? / NULLIF(?, 0)")
                .contains("arrival_overage_posted_qty =")
                .contains("status = 'RECEIPT_ADJUSTED'")
                .contains("status = 'PENDING_FINANCE'");
    }

    @Test
    void returnAndNotificationHooksMatchFinalOwnership() throws Exception {
        String subcontractReturn = source(
                "src/main/java/com/uten/imp/features/subcontract/ret/"
                        + "SubcontractReturnService.java");
        assertThat(subcontractReturn)
                .contains("ProcurementArrivalControlPort arrivalControl")
                .contains("arrivalControl.refreshAfterReturn("
                        + "ProcurementArrivalControlPort.SUBCONTRACT")
                .contains("SubcontractReturnItem::getOrderItemId");

        String notices = source(
                "src/main/java/com/uten/imp/features/notice/"
                        + "ChainNoticeService.java");
        assertThat(notices)
                .contains("financeReviewerUserIds()")
                .contains("sendToUser(reviewer, TYPE_URGENT")
                .contains("departmentUserIds(\"SUB_WH\")")
                .contains("notifyUser(ownerUser, TYPE_TASK")
                .doesNotContain("到货超量待决定")
                .doesNotContain("原下单人已决定接收");
    }

    @Test
    void stockInNotifiesPurchaseDeptWhenReturnStillPending() throws Exception {
        // 修复：一键入库（recordApproval）原本不发 outbox 事件 → 采购/委外收不到「已入库、余量待退」。
        // 锁定补全：仅当本异常仍有待退（→RECEIPT_POSTED）时发 PROCUREMENT_ARRIVAL_RECEIPT_POSTED，
        // 并由 ChainNoticeService 把入库/退货事件广播到采购部 SUB_PURCHASE（委外单也归采购部）。
        String service = source(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "ProcurementArrivalControlService.java");
        assertThat(service)
                .contains("EVENT_RECEIPT_POSTED = \"PROCUREMENT_ARRIVAL_RECEIPT_POSTED\"")
                .contains("hasPendingReturnTask")
                .contains("publish(EVENT_RECEIPT_POSTED, allowance.id(), allowance.version() + 1)");

        String notices = source(
                "src/main/java/com/uten/imp/features/notice/"
                        + "ChainNoticeService.java");
        assertThat(notices)
                .contains("\"PROCUREMENT_ARRIVAL_RECEIPT_POSTED\"")
                .contains("EVENT_PROCUREMENT_ARRIVAL_RECEIPT_POSTED ->")
                .contains("broadcastToPurchaseDept")
                .contains("departmentUserIds(\"SUB_PURCHASE\")")
                .contains("到货已入库，余量待退");
    }

    private static void assertCommitsBlockedException(Method method) {
        Transactional transactional =
                method.getAnnotation(Transactional.class);
        assertThat(transactional).isNotNull();
        assertThat(transactional.noRollbackFor())
                .contains(ProcurementArrivalBlockedException.class);
    }

    private static void assertInvalidCustom(
            Method helper, String requested, String limit) {
        InvocationTargetException thrown =
                assertThrows(
                        InvocationTargetException.class,
                        () -> helper.invoke(
                                null,
                                new BigDecimal(requested),
                                new BigDecimal(limit)));
        assertThat(thrown.getCause()).isInstanceOf(ApiException.class);
    }

    private static Object sampleValue(RecordComponent component) {
        if (component.getType() == UUID.class) {
            return UUID.randomUUID();
        }
        if (component.getType() == String.class) {
            return component.getName();
        }
        if (component.getType() == BigDecimal.class) {
            return new BigDecimal("12345678901234.5678");
        }
        if (component.getType() == long.class) {
            return 1L;
        }
        // boolean 组件（如 priceMasked）：反射构造不能传 null（拆箱 NPE）。
        if (component.getType() == boolean.class) {
            return false;
        }
        if (component.getType() == OffsetDateTime.class) {
            return OffsetDateTime.parse("2026-08-02T12:00:00+08:00");
        }
        if (component.getType() == List.class) {
            return List.of();
        }
        return null;
    }

    private static String source(String path) throws Exception {
        return Files.readString(Path.of(path));
    }
}
