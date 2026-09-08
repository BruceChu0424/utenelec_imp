package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.ProcurementArrivalBlockedException;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;

import java.lang.reflect.Method;
import java.lang.reflect.RecordComponent;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 到货登记一步完成（登记 + 送检审核）的契约：端点挂载、超量异常不回滚、
 * 权限由收货单 Service 自身 @PreAuthorize 收口（create + approve 两段都不得裸奔）。
 */
class WarehouseArrivalRegistrationContractTest {

    @Test
    void registerEndpointIsMountedUnderWarehouseInbound() throws Exception {
        RequestMapping mapping = WarehouseInboundController.class
                .getAnnotation(RequestMapping.class);
        assertThat(mapping.value())
                .containsExactly("/api/warehouse/inbound");

        Method register = WarehouseInboundController.class.getDeclaredMethod(
                "registerArrival", WarehouseArrivalRegisterRequest.class);
        assertThat(register.getAnnotation(PostMapping.class).value())
                .containsExactly("/arrivals");
        // 仓库任务入口先要求页面阅读+入仓动作；下层两个收货单 Service 仍保留
        // create/approve 的精确文档权限，形成双层门禁。
        assertThat(register.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse_inbound:view')"
                        + " and hasAuthority('warehouse_inbound:stock_in')");

        // 断点恢复端点：草稿收货单一键「继续送检」，同样不在端点层自设权限。
        Method complete = WarehouseInboundController.class.getDeclaredMethod(
                "completeArrival", java.util.UUID.class);
        assertThat(complete.getAnnotation(PostMapping.class).value())
                .containsExactly("/arrivals/{receiptId}/complete");
        assertThat(complete.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('warehouse_inbound:view')"
                        + " and hasAuthority('warehouse_inbound:stock_in')");
    }

    @Test
    void completeSharesTheNoRollbackRegistrationTransaction() throws Exception {
        Method complete = WarehouseArrivalRegistrationService.class
                .getDeclaredMethod("complete", java.util.UUID.class);
        Transactional tx = complete.getAnnotation(Transactional.class);
        assertThat(tx).isNotNull();
        assertThat(tx.noRollbackFor())
                .containsExactly(ProcurementArrivalBlockedException.class);
    }

    @Test
    void blockedExceptionMustNotRollbackTheRegistrationTransaction() throws Exception {
        Method register = WarehouseArrivalRegistrationService.class
                .getDeclaredMethod(
                        "register", WarehouseArrivalRegisterRequest.class);
        Transactional tx = register.getAnnotation(Transactional.class);
        assertThat(tx).isNotNull();
        assertThat(tx.noRollbackFor())
                .containsExactly(ProcurementArrivalBlockedException.class);
    }

    @Test
    void servicePermissionsStayOnReceiptServices() throws Exception {
        // 仓库经 purchase_receipt:edit / subcontract_receipt:edit（V296）按 V328 蕴含
        // create+approve；一步登记复用两段 Service，注解缺一不可。
        for (Class<?> service : Arrays.asList(
                com.uten.imp.features.purchase.receipt.PurchaseReceiptService.class,
                com.uten.imp.features.subcontract.receipt.SubcontractReceiptService.class)) {
            Method create = service.getDeclaredMethod(
                    "create", Class.forName(service.getPackageName()
                            + ".dto.ReceiptSaveRequest"));
            Method approve = service.getDeclaredMethod("approve", java.util.UUID.class);
            assertThat(create.getAnnotation(PreAuthorize.class))
                    .as("%s.create 必须自带权限注解", service.getSimpleName())
                    .isNotNull();
            assertThat(approve.getAnnotation(PreAuthorize.class))
                    .as("%s.approve 必须自带权限注解", service.getSimpleName())
                    .isNotNull();
        }
    }

    @Test
    void requestContractKeepsWarehouseSurfaceMinimal() {
        // 仓库侧字段面：只有数量/可选实际总重量/库位语义 + 人员/仓库/日期；不得出现价格与币族字段
        //（币族由服务端按来源订货单权威回填，仓库全程不可见）。
        var components = Arrays.stream(
                        WarehouseArrivalRegisterRequest.class.getRecordComponents())
                .map(RecordComponent::getName)
                .toList();
        assertThat(components).containsExactlyInAnyOrder(
                "idempotencyKey", "orderType", "billDate", "supplierId", "warehouseId",
                "purchaserId", "receiverEmployeeId", "remark", "items");
        var lineComponents = Arrays.stream(
                        WarehouseArrivalRegisterRequest.ArrivalLine.class
                                .getRecordComponents())
                .map(RecordComponent::getName)
                .toList();
        assertThat(lineComponents).containsExactlyInAnyOrder(
                "goodsId", "qty", "orderItemId", "colorId", "unitId",
                        "unitRate", "weight", "sourceDocNo", "replacementIntent");
    }

    @Test
    void actualTotalWeightIsCopiedIntoBothReceiptTypesAndHashed()
            throws Exception {
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "WarehouseArrivalRegistrationService.java");
        Path source = Files.exists(direct) ? direct : Path.of("server").resolve(direct);
        String java = Files.readString(source);

        assertThat(java).contains("item.setWeight(line.weight())");
        assertThat(java.split("item\\.setWeight\\(line\\.weight\\(\\)\\)", -1))
                .hasSize(3);
        assertThat(java).contains(
                "decimalText(item.weight())");
    }

    @Test
    void approvedTaxRateIsInheritedIntoBothReceiptTypesAndDraftRecovery() throws Exception {
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "WarehouseArrivalRegistrationService.java");
        Path source = Files.exists(direct) ? direct : Path.of("server").resolve(direct);
        String java = Files.readString(source);

        assertThat(java).contains("order_doc.exchange_rate, order_doc.tax_rate");
        assertThat(java.split("req\\.setTaxRate\\(header\\.taxRate\\(\\)\\)", -1))
                .hasSize(3);
        assertThat(java).contains(
                "SET supplier_id = ?, currency_id = ?, exchange_rate = ?, tax_rate = ?");
    }

    @Test
    void subcontractRegistrationRequiresARealApprovedTargetOutbound() throws Exception {
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "WarehouseArrivalRegistrationService.java");
        Path source = Files.exists(direct) ? direct : Path.of("server").resolve(direct);
        String java = Files.readString(source);

        assertThat(java)
                .contains("requireSubcontractOutboundReleased")
                .contains("subcontract_material_issue_items issue_item")
                .contains("issue.status = 1")
                .contains("'DIRECT_OUTBOUND','MAKE_THEN_OUTBOUND'")
                .contains("NOT EXISTS (")
                .contains("new_flow_plan.flow_mode IN")
                .contains("委外目标件尚未真实审核出仓，不能登记回厂");
        assertThat(java.split("requireSubcontractOutboundReleased\\(", -1))
                .hasSize(4);
    }

    @Test
    void subcontractReceiptChecksPhysicalOutboundCapacityBeforeFinancialOverage()
            throws Exception {
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/subcontract/receipt/"
                        + "SubcontractReceiptService.java");
        Path source = Files.exists(direct) ? direct : Path.of("server").resolve(direct);
        String java = Files.readString(source);

        assertThat(java).containsSubsequence(
                "requireTargetOutboundCapacity(items, id);",
                "arrivalControl.validateBeforeApproval(");
        assertThat(java)
                .contains("lockAndRequireDraftOutboundCapacity(req.getItems(), null, List.of())")
                .contains("FOR UPDATE OF order_item")
                .contains("active_draft_base")
                .contains("真实出仓可回厂额度不足，或额度已被其它回厂草稿占用")
                .contains("issue.status = 1 AND issue.is_deleted = FALSE")
                .contains("receivedBase.add(entry.getValue())")
                .contains("issuedBase.add(returnedFailureBase)")
                .contains("委外目标件尚未足额出仓且无足够IQC失败返修额度");
    }

    @Test
    void outcomeConstantsMatchWireContract() {
        assertThat(WarehouseArrivalRegistrationService.OUTCOME_INSPECTED)
                .isEqualTo("SUBMITTED_FOR_INSPECTION");
        assertThat(WarehouseArrivalRegistrationService.OUTCOME_QUARANTINED)
                .isEqualTo("EXCESS_QUARANTINED");
    }

    @Test
    void expectationContractExposesPipelineStepsForResume() {
        var components = Arrays.stream(
                        ProcurementArrivalContracts.InboundExpectationTask.class
                                .getRecordComponents())
                .map(RecordComponent::getName)
                .toList();
        // 流水线三要素：草稿收货单（继续送检）/ 待品质放行 / 未结到货异常（超量待财务）。
        assertThat(components).contains(
                "draftReceiptIds", "pendingInspectionReceipts", "openArrivalExceptions");
    }

    @Test
    void expectationCreateActionRequiresCapacityAndStockInPermission() throws Exception {
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "ProcurementArrivalControlService.java");
        Path source = Files.exists(direct) ? direct : Path.of("server").resolve(direct);
        String java = Files.readString(source);

        assertThat(java)
                .contains("remainingQty.compareTo(registeredQty) > 0")
                .contains("warehouse_inbound:stock_in")
                .contains("boolean canCreateReceipt")
                .contains("? List.of(");
    }
}
