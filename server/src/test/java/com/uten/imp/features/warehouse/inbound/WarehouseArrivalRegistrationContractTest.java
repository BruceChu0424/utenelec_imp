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
import java.util.Set;
import java.util.UUID;

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
        // V596 先入库后质检：只多一个布尔开关，仍然没有价格/币族字段。
        // V636 / ADR-098 委外回厂短交确认：再多一个布尔确认位(仓库看过 409 弹窗后原样重发)，同样不是金额。
        assertThat(components).containsExactlyInAnyOrder(
                "idempotencyKey", "orderType", "billDate", "supplierId", "warehouseId",
                "purchaserId", "receiverEmployeeId", "remark", "items", "stockInBeforeInspection",
                "shortDeliveryAcknowledged");
        var lineComponents = Arrays.stream(
                        WarehouseArrivalRegisterRequest.ArrivalLine.class
                                .getRecordComponents())
                .map(RecordComponent::getName)
                .toList();
        // V596：行级只多一个上架库位(库位语义字段，非金额)。
        // ADR-135：再多一个「数量按称重推算」布尔位(称重计数按称重改数量时为真, 该行不进单重学习)。
        assertThat(lineComponents).containsExactlyInAnyOrder(
                "goodsId", "qty", "orderItemId", "colorId", "unitId",
                        "unitRate", "weight", "sourceDocNo", "replacementIntent", "preStockPlace",
                        "qtyFromWeight");
    }

    @Test
    void actualTotalWeightIsCopiedIntoBothReceiptTypesAndHashed()
            throws Exception {
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "WarehouseArrivalRegistrationService.java");
        Path source = Files.exists(direct) ? direct : Path.of("server").resolve(direct);
        String java = Files.readString(source);

        // 两种收货单都只写「服务端核过的重量」: 0 视为没称, 按重量计的行丢弃(库存账精确换算)。
        assertThat(java).contains("List<BigDecimal> weights = capturedWeights(request.items());");
        assertThat(java.split("item\\.setWeight\\(weights\\.get\\(autoLine - 1\\)\\)", -1))
                .hasSize(3);
        assertThat(java).doesNotContain("item.setWeight(line.weight())");
        assertThat(java).contains("profile.mass_unit_code IS NOT NULL");
        // 指纹仍按客户端原值: 重量 + 勾选「数量按称重推算」时的标记。
        assertThat(java).contains("decimalText(item.weight())")
                .contains("appendHash(canonical, \"qtyFromWeight\");");
    }

    @Test
    void weighedArrivalLinesFeedReceiptObservationsInTheSameTransaction() throws Exception {
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "WarehouseArrivalRegistrationService.java");
        Path source = Files.exists(direct) ? direct : Path.of("server").resolve(direct);
        String java = Files.readString(source);

        // 建好收货单、送检审核之前记 RECEIPT 观测(超量隔离保留草稿时观测同样留下)。
        assertThat(java).containsSubsequence(
                "createFromWarehouseArrival(",
                "recordReceiptObservations(orderType, receiptId, receiptLines, request, header.supplierId());",
                "approveAsArrival(orderType, receiptId, billNo);");
        assertThat(java).contains("SourceKind.RECEIPT")
                .contains("RECEIPT_CAPTURE_PREFIX + line.id()")
                .contains("line.qty().multiply(rate)");
        assertThat(WarehouseArrivalRegistrationService.RECEIPT_CAPTURE_PREFIX).isEqualTo("RECEIPT:");

        // 收货红冲 = 到货登记作废: 观测按同一幂等键红冲。
        Path controlDirect = Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "ProcurementArrivalControlService.java");
        Path control = Files.exists(controlDirect) ? controlDirect : Path.of("server").resolve(controlDirect);
        assertThat(Files.readString(control))
                .contains("reverseReceiptWeightObservations(orderType, receiptId);")
                .contains("WarehouseArrivalRegistrationService.RECEIPT_CAPTURE_PREFIX + itemId");
    }

    @Test
    void massUnitLinesAreExactOnlyByGoodsBaseUnitOrOwnLineUnit() {
        UUID kgGoods = UUID.randomUUID();
        UUID pieceGoods = UUID.randomUUID();
        UUID kgUnit = UUID.randomUUID();
        var mass = new WarehouseArrivalRegistrationService.MassUnits(Set.of(kgGoods), Set.of(kgUnit));

        assertThat(mass.exact(kgGoods, null)).isTrue();
        assertThat(mass.exact(pieceGoods, kgUnit)).isTrue();
        assertThat(mass.exact(pieceGoods, null)).isFalse();
        assertThat(mass.exact(pieceGoods, UUID.randomUUID())).isFalse();
        assertThat(WarehouseArrivalRegistrationService.MassUnits.NONE.exact(kgGoods, kgUnit)).isFalse();
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
    void subcontractRegistrationRequiresMaterialActuallySentToTheSupplier() throws Exception {
        Path direct = Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "WarehouseArrivalRegistrationService.java");
        Path source = Files.exists(direct) ? direct : Path.of("server").resolve(direct);
        String java = Files.readString(source);

        // ADR-143 §三.6: 登记回厂要求委外商用已发直属物料至少能做成一点委外件;
        // 没有计划行的明细可回厂套数按 0 计(§二.3 缺 BOM 不能下单, fail-closed, 没有自备料豁免)。
        assertThat(java)
                .contains("requireSubcontractOutboundReleased")
                .contains("fn_subcontract_returnable_qty(order_item.id)")
                .contains("COALESCE(supplied.returnable_qty, 0) > 0")
                .contains("请先在委外任务中心领料并由仓库发出直属物料")
                .doesNotContain("returnable_qty IS NULL")
                .doesNotContain("自备料")
                .doesNotContain("flow_mode")
                .doesNotContain("前置自制");
        assertThat(java.split("requireSubcontractOutboundReleased\\(", -1))
                .hasSize(4);
    }

    @Test
    void subcontractReceiptSendsSupplierSuppliedExcessToFinanceInsteadOfRefusingIt()
            throws Exception {
        String java = read("src/main/java/com/uten/imp/features/subcontract/receipt/"
                + "SubcontractReceiptService.java");
        String capacity = read("src/main/java/com/uten/imp/features/subcontract/receipt/"
                + "SubcontractReturnCapacity.java");

        // ADR-101 §2.8：到货异常闸必须**先**跑。它会把「超过我方供料能做出来的数量」那部分
        // 落成 PENDING_FINANCE 到货异常并通知财务(抛的是不回滚的 Blocked 异常，异常记录照常
        // 提交)；守恒闸留在后面兜底，只有财务已经批准过那份自带料的单子才走得到它。
        // 顺序一旦反过来，仓库又会先撞上一句看不懂的「禁止超量回仓」，财务全程不知情，
        // 多出来的实物落在账外。
        assertThat(java).containsSubsequence(
                "arrivalControl.validateBeforeApproval(",
                "requireTargetOutboundCapacity(items, id);");
        assertThat(java)
                .contains("lockAndRequireDraftOutboundCapacity(req.getItems(), null, List.of())")
                // ADR-143 §三.6：草稿保存、审核守恒闸与发料红冲共用同一个容量读取口。
                .contains("SubcontractReturnCapacity.lockAndRead(")
                .contains("facts.activeDraftBase()")
                // 登记只拦并发撞单：物理上够、但额度被同明细另一张未审草稿占住。
                .contains("本行可回厂额度已被同一订货明细的其它回厂草稿占用")
                .doesNotContain("真实出仓可回厂额度不足，或额度已被其它回厂草稿占用")
                .contains("facts.approvedReceiptBase().add(entry.getValue())")
                .contains("facts.authorizedBase()")
                .contains("回厂数量超过我方发给委外商的材料能做出来的数量")
                .doesNotContain("ISSUED_TARGET_BASE_SUM")
                .doesNotContain("委外目标件尚未足额出仓且无足够IQC失败返修额度");
        // 守恒额度 = 可做套数(逐种物料取短板, 不相加) + 已退回的质检不合格量 + 财务批准的
        // 委外商自带料；否则财务批准完这单仍然审不过去。
        assertThat(capacity)
                .contains("COALESCE(fn_subcontract_returnable_qty(order_item.id), 0)")
                .contains("returnableBase.add(returnedFailureBase).add(approvedSupplierOwnBase)")
                .contains("FOR UPDATE OF order_item")
                .contains("active_draft_base")
                .contains("receipt.status = 1")
                .doesNotContain("returnable_qty IS NULL");
    }

    private static String read(String relative) throws Exception {
        Path direct = Path.of(relative);
        Path source = Files.exists(direct) ? direct : Path.of("server").resolve(direct);
        return Files.readString(source).replace("\r\n", "\n");
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
