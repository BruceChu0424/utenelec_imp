package com.uten.imp.features.warehouse.finishedin;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalContracts.ArrivalLotRequest;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService.GroupKey;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService.LotMember;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService.LotRequest;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/** ADR-148 / ADR-151 §5：产成品入库登记按实物交接批，一个命令按「报工 x 实际仓」分组。 */
class ProductionFinishedArrivalRegistrationServiceTest {

    @Test
    void preStockRequiresAWholeLotCountButTheStandardRouteIgnoresIt() {
        UUID lot = UUID.randomUUID(), warehouse = UUID.randomUUID();
        assertThatThrownBy(() -> ProductionFinishedArrivalRegistrationService.normalizeLots(
                List.of(new ArrivalLotRequest(lot, warehouse, "A01", null, null)), true))
                .isInstanceOf(ApiException.class).hasMessageContaining("逐批填写实际点数");
        for (String invalid : List.of("0", "-1", "1.00001", "100000000000000")) {
            assertThatThrownBy(() -> ProductionFinishedArrivalRegistrationService.normalizeLots(
                    List.of(new ArrivalLotRequest(lot, warehouse, "A01", new BigDecimal(invalid), null)), true))
                    .isInstanceOf(ApiException.class);
        }
        assertThat(ProductionFinishedArrivalRegistrationService.normalizeLots(
                List.of(new ArrivalLotRequest(lot, warehouse, "A01", null, null)), false)).containsOnlyKeys(lot);
        ProductionFinishedArrivalRegistrationService.requireCountedLot(new BigDecimal("1100"), new BigDecimal("1100.0"));
        assertThatThrownBy(() -> ProductionFinishedArrivalRegistrationService.requireCountedLot(
                new BigDecimal("1100"), new BigDecimal("1060")))
                .isInstanceOf(ApiException.class).hasMessageContaining("人工点收");
    }

    @Test
    void duplicateLotsAndBlankPlacesFailClosed() {
        UUID lot = UUID.randomUUID(), warehouse = UUID.randomUUID();
        assertThatThrownBy(() -> ProductionFinishedArrivalRegistrationService.normalizeLots(List.of(
                new ArrivalLotRequest(lot, warehouse, "A01", null, null),
                new ArrivalLotRequest(lot, UUID.randomUUID(), "B01", null, null)), false))
                .isInstanceOf(ApiException.class)
                .satisfies(error -> assertThat(((ApiException) error).getCode()).isEqualTo(ErrorCode.VALIDATION_FAILED))
                .hasMessageContaining("同一批实物");
        assertThatThrownBy(() -> ProductionFinishedArrivalRegistrationService.normalizeLots(
                List.of(new ArrivalLotRequest(lot, warehouse, "  ", null, null)), false))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> ProductionFinishedArrivalRegistrationService.normalizeLots(
                List.of(new ArrivalLotRequest(lot, warehouse, "A01", null, new BigDecimal("-0.0001"))), false))
                .isInstanceOf(ApiException.class).hasMessageContaining("千克");
    }

    @Test
    void groupHashIsOrderIndependentAndCoversPlaceCountWeightRemarkAndRoute() {
        UUID report = UUID.randomUUID(), warehouse = UUID.randomUUID();
        UUID first = UUID.randomUUID(), second = UUID.randomUUID();
        GroupKey group = new GroupKey(report, warehouse);
        Map<UUID, LotRequest> lots = new TreeMap<>(Map.of(
                first, new LotRequest("A01", null, new BigDecimal("12.5")),
                second, new LotRequest("B01", null, null)));
        var base = ProductionFinishedArrivalRegistrationService.normalizeGroup("batch-key-001", group, lots, null, false);
        var same = ProductionFinishedArrivalRegistrationService.normalizeGroup("batch-key-001", group,
                new TreeMap<>(Map.of(second, new LotRequest("B01", null, null),
                        first, new LotRequest("A01", null, new BigDecimal("12.5")))), null, false);
        assertThat(same.requestHash()).isEqualTo(base.requestHash());
        assertThat(same.idempotencyKey()).isEqualTo(base.idempotencyKey()).startsWith("FAR:").hasSize(52);
        for (var changed : List.of(
                ProductionFinishedArrivalRegistrationService.normalizeGroup("batch-key-001", group,
                        Map.of(first, new LotRequest("A02", null, new BigDecimal("12.5")),
                                second, new LotRequest("B01", null, null)), null, false),
                ProductionFinishedArrivalRegistrationService.normalizeGroup("batch-key-001", group,
                        Map.of(first, new LotRequest("A01", null, new BigDecimal("12.6")),
                                second, new LotRequest("B01", null, null)), null, false),
                ProductionFinishedArrivalRegistrationService.normalizeGroup("batch-key-001", group, lots, "备注", false),
                ProductionFinishedArrivalRegistrationService.normalizeGroup("batch-key-001", group, lots, null, true))) {
            assertThat(changed.requestHash()).isNotEqualTo(base.requestHash());
        }
        // 同一批量键下，另一张报工或另一个实际仓是另一组(另一个子键)。
        assertThat(ProductionFinishedArrivalRegistrationService.normalizeGroup("batch-key-001",
                new GroupKey(report, UUID.randomUUID()), lots, null, false).idempotencyKey())
                .isNotEqualTo(base.idempotencyKey());
        assertThat(ProductionFinishedArrivalRegistrationService.normalizeRemark("  x  ")).isEqualTo("x");
        assertThat(ProductionFinishedArrivalRegistrationService.normalizeRemark("   ")).isNull();
        assertThatThrownBy(() -> ProductionFinishedArrivalRegistrationService.normalizeRemark("r".repeat(501)))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void wholeLotWeightIsSplitByQuantityWithTheRemainderOnTheLastSlice() {
        var split = ProductionFinishedArrivalRegistrationService.splitWeight(new BigDecimal("11.0000"), List.of(
                new LotMember(UUID.randomUUID(), new BigDecimal("1000"), 0),
                new LotMember(UUID.randomUUID(), new BigDecimal("100"), 2)));
        assertThat(split.get(0)).isEqualByComparingTo("10.0000");
        assertThat(split.get(1)).isEqualByComparingTo("1.0000");
        var tiny = ProductionFinishedArrivalRegistrationService.splitWeight(new BigDecimal("0.0001"), List.of(
                new LotMember(UUID.randomUUID(), new BigDecimal("1"), 0),
                new LotMember(UUID.randomUUID(), new BigDecimal("1000"), 2)));
        assertThat(tiny.get(0)).as("分到 0 的份记为没称").isNull();
        assertThat(tiny.get(1)).isEqualByComparingTo("0.0001");
    }

    @Test
    void lotViewGroupsSlicesAndSplitsByOwnership() {
        UUID lot = UUID.randomUUID(), goods = UUID.randomUUID();
        UUID demand = UUID.randomUUID(), surplus = UUID.randomUUID();
        Object[] demandRow = row(lot, demand, 1, goods, "1000", "A-01", 0);
        Object[] surplusRow = row(lot, surplus, 2, goods, "100", "A-01", 2);
        var lots = ProductionFinishedArrivalRegistrationService.mapLots(List.of(surplusRow, demandRow));
        assertThat(lots).singleElement().satisfies(view -> {
            assertThat(view.lotId()).isEqualTo(lot);
            assertThat(view.reportedQty()).isEqualByComparingTo("1100");
            assertThat(view.demandQty()).isEqualByComparingTo("1000");
            assertThat(view.actualSurplusQty()).isEqualByComparingTo("100");
            assertThat(view.splitText()).isEqualTo("需求 1000 · 实际超产 100");
            assertThat(view.members()).extracting(member -> member.reportItemId()).containsExactly(demand, surplus);
            assertThat(view.members()).extracting(member -> member.kind()).containsExactly("DEMAND", "ACTUAL_SURPLUS");
            assertThat(view.lineNo()).isEqualTo(1);
        });
    }

    @Test
    void reversalReasonIsTrimmedAndBoundedAndHashesRegistrationIdentity() {
        UUID registrationId = UUID.randomUUID();
        var normalized = ProductionFinishedArrivalRegistrationService.normalizeReversal(
                registrationId,
                new ProductionFinishedArrivalContracts.ArrivalRegistrationReversalRequest(
                        "reverse-key-001", "  仓库选错  "));
        var other = ProductionFinishedArrivalRegistrationService.normalizeReversal(
                UUID.randomUUID(),
                new ProductionFinishedArrivalContracts.ArrivalRegistrationReversalRequest(
                        "reverse-key-001", "仓库选错"));
        assertThat(normalized.reason()).isEqualTo("仓库选错");
        assertThat(normalized.requestHash()).isNotEqualTo(other.requestHash());
        assertThatThrownBy(() -> ProductionFinishedArrivalRegistrationService.normalizeReversal(
                registrationId, new ProductionFinishedArrivalContracts.ArrivalRegistrationReversalRequest(
                        "reverse-key-001", " x ")))
                .isInstanceOf(ApiException.class);
    }

    @Test
    void rememberPlanMergesSameDimensionAndSeparatesColors() {
        UUID goodsId = UUID.randomUUID();
        UUID firstColor = UUID.randomUUID();
        UUID secondColor = UUID.randomUUID();
        var plan = ProductionFinishedArrivalRegistrationService.buildRememberPlan(List.of(
                new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                        goodsId, firstColor, " A31-3-1 ", "V5001", "成品"),
                new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                        goodsId, firstColor, "A31-3-1", "V5001", "成品"),
                new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                        goodsId, secondColor, "B02-1-4", "V5001", "成品")));
        assertThat(plan.ambiguous()).isZero();
        assertThat(plan.candidates())
                .extracting(ProductionFinishedArrivalRegistrationService.RememberCandidate::place)
                .containsExactly("A31-3-1", "B02-1-4");
    }

    @Test
    void rememberPlanRejectsDifferentPlacesForSameGoodsAndColor() {
        UUID goodsId = UUID.randomUUID();
        UUID colorId = UUID.randomUUID();
        var plan = ProductionFinishedArrivalRegistrationService.buildRememberPlan(List.of(
                new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                        goodsId, colorId, "A31-3-1", "V5001", "成品"),
                new ProductionFinishedArrivalRegistrationService.RememberPlaceSource(
                        goodsId, colorId, "B02-1-4", "V5001", "成品")));
        assertThat(plan.candidates()).isEmpty();
        assertThat(plan.ambiguous()).isEqualTo(1);
        assertThat(plan.warnings()).singleElement().asString().contains("V5001", "A31-3-1", "B02-1-4");
    }

    @Test
    void singleReportEndpointsAreGoneAndTheBatchCommandGroupsByReportAndWarehouse() throws Exception {
        String controller = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/finishedin/ProductionFinishedInboundTaskController.java"));
        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/finishedin/ProductionFinishedArrivalRegistrationService.java"));
        assertThat(controller)
                .contains("/arrival-registrations/batch")
                .contains("/arrival-registrations/{registrationId}/reverse")
                .doesNotContain("\"/arrival-registrations/{reportId}\"")
                .doesNotContain("@PathVariable UUID reportId");
        assertThat(service)
                .doesNotContain("public ArrivalRegistrationView register(")
                .doesNotContain("public ArrivalRegistrationView detail(")
                .contains("v_production_output_handoff_lots")
                .contains("v_production_report_items_pending_registration")
                .contains("new GroupKey(reportOfLot.get(lotId), lot.warehouseId())");
        int start = service.indexOf("public BatchArrivalRegistrationResult batchRegister(");
        String prepare = service.substring(start, service.indexOf("// 同仓新建批次", start));
        // 每张报工先于每个仓库加锁；重放先于当前仓库校验。
        assertThat(prepare).containsSubsequence("lockCommand(actorId, key)",
                "existingRegistration(entry.getKey().reportId()", "lockApprovedReport(reportId)",
                "ORDER BY report_id, id FOR UPDATE", "validatedWarehouse(warehouseId)",
                "references.receiver = requireReceiver(receiverEmployeeId)", "registerNew(");
        int insertItems = service.indexOf("INSERT INTO production_finished_arrival_registration_items");
        int registerFqc = service.indexOf("qualityInspection.registerApprovedReportItems(");
        assertThat(insertItems).isPositive();
        assertThat(registerFqc).isGreaterThan(insertItems);
    }

    private static Object[] row(UUID lot, UUID item, int lineNo, UUID goods, String qty, String place, int rank) {
        return new Object[]{lot, item, lineNo, UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(), "SJ-1",
                goods, "G-1", "成品", null, null, UUID.randomUUID(), "个", new BigDecimal(qty), place, null, null, null,
                null, null, BigDecimal.ONE, rank};
    }
}
