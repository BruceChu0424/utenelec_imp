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
        // 端点本身不加方法级 @PreAuthorize：建单/审核权限由两个收货单 Service 的
        // 注解收口（见 servicePermissionsStayOnReceiptServices）。
        assertThat(register.getAnnotation(PreAuthorize.class)).isNull();

        // 断点恢复端点：草稿收货单一键「继续送检」，同样不在端点层自设权限。
        Method complete = WarehouseInboundController.class.getDeclaredMethod(
                "completeArrival", java.util.UUID.class);
        assertThat(complete.getAnnotation(PostMapping.class).value())
                .containsExactly("/arrivals/{receiptId}/complete");
        assertThat(complete.getAnnotation(PreAuthorize.class)).isNull();
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
        // 仓库侧字段面：只有数量/库位语义 + 人员/仓库/日期；不得出现价格与币族字段
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
                "unitRate", "sourceDocNo");
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
}
