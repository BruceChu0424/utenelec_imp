package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import java.math.BigDecimal;
import java.util.Map;
import java.util.List;
import java.util.ArrayList;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * 行级流程阶段推导的行为口径（表格进度/待办列唯一词表的服务端源头）。
 *
 * <p>链路 SQL 的真实聚合由 PostgreSQL 聚焦测试覆盖；这里锁定纯推导分支：
 * 未下达第一步、自制锚点执行段映射与零料直制、委外行无申请时的前置自制回退。</p>
 */
class MaterialAnalysisFlowStageServiceTest {

    private final EntityManager em = mock(EntityManager.class);
    private final MaterialAnalysisFlowStageService service =
            new MaterialAnalysisFlowStageService(em);

    @BeforeEach
    void stubEmptyChainQueries() {
        // 先构建空查询再打桩：在 thenReturn 参数里再开 when() 会造成
        // UnfinishedStubbing（Mockito 嵌套桩限制）。
        Query empty = mock(Query.class);
        when(empty.setParameter(
                anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(empty);
        when(empty.getResultList()).thenReturn(java.util.List.of());
        when(em.createNativeQuery(anyString())).thenReturn(empty);
    }

    @Test
    void buyLineWithoutActionStaysAtPendingIssue() {
        UUID line = UUID.randomUUID();
        Map<UUID, String> stages = service.lineFlowStages(
                UUID.randomUUID(),
                Map.of(line, "BUY"),
                Map.of(line, new BigDecimal("5")),
                Map.of(line, new BigDecimal("10")),
                Map.of(),
                Map.of());
        assertThat(stages).containsEntry(line, "BUY_PENDING_ISSUE");
    }

    @Test
    void zeroDemandLineWithoutActionStaysAtPendingIssue() {
        // 2026-09-06 锚点模型：required=0 不再跳过推导（转产行要拿到真实
        // 阶段键）；无行动的零需求行推导为 PENDING_ISSUE，由展示层跳过。
        UUID line = UUID.randomUUID();
        Map<UUID, String> stages = service.lineFlowStages(
                UUID.randomUUID(),
                Map.of(line, "BUY"),
                Map.of(line, new BigDecimal("5")),
                Map.of(line, BigDecimal.ZERO),
                Map.of(),
                Map.of());
        assertThat(stages).containsEntry(line, "BUY_PENDING_ISSUE");
    }

    @Test
    void makeAnchorMapsExecutionStatesWithZeroMaterialVariants() {
        UUID waiting = UUID.randomUUID();
        UUID zeroReady = UUID.randomUUID();
        UUID running = UUID.randomUUID();
        UUID done = UUID.randomUUID();
        Map<UUID, String> stages = service.lineFlowStages(
                UUID.randomUUID(),
                Map.of(
                        waiting, "MAKE",
                        zeroReady, "MAKE",
                        running, "MAKE",
                        done, "MAKE"),
                Map.of(
                        waiting, new BigDecimal("5"),
                        zeroReady, new BigDecimal("5"),
                        running, new BigDecimal("5"),
                        done, BigDecimal.ZERO),
                Map.of(
                        waiting, new BigDecimal("10"),
                        zeroReady, new BigDecimal("10"),
                        running, new BigDecimal("10"),
                        done, new BigDecimal("10")),
                Map.of(
                        waiting, "WAITING",
                        zeroReady, "READY",
                        running, "IN_PROGRESS",
                        done, "COMPLETED"),
                Map.of(
                        waiting, false,
                        zeroReady, true,
                        running, false,
                        done, false));
        assertThat(stages)
                .containsEntry(waiting, "MAKE_WAITING_MATERIAL")
                .containsEntry(zeroReady, "MAKE_ZERO_READY")
                .containsEntry(running, "MAKE_IN_PROGRESS")
                .containsEntry(done, "MAKE_COMPLETED");
    }

    @Test
    void subcontractWithoutApplicationFallsBackToPrecedingMakeStage() {
        UUID line = UUID.randomUUID();
        Map<UUID, String> stages = service.lineFlowStages(
                UUID.randomUUID(),
                Map.of(line, "SUBCONTRACT"),
                Map.of(line, new BigDecimal("5")),
                Map.of(line, new BigDecimal("10")),
                Map.of(line, "IN_PROGRESS"),
                Map.of(line, false));
        // 无委外申请 = 尚未通知委外：先走前置自制的执行进度。
        assertThat(stages).containsEntry(line, "MAKE_IN_PROGRESS");
    }

    @Test
    void stockedLineCompletesEvenWithoutChainRows() {
        // 空链路下 shortage<=0 不会出现在真实数据（有行动才可能齐套），
        // 但口径必须先判齐套：本测试以 BUY_REQUESTED 起点验证顺序保守。
        UUID line = UUID.randomUUID();
        Map<UUID, String> stages = service.lineFlowStages(
                UUID.randomUUID(),
                Map.of(line, "BUY"),
                Map.of(line, BigDecimal.ZERO),
                Map.of(line, new BigDecimal("10")),
                Map.of(),
                Map.of());
        assertThat(stages).containsEntry(line, "BUY_PENDING_ISSUE");
    }

    @Test
    void delegatedBuyLineWithZeroShortageDoesNotFakeStocked() {
        // 2026-09-06 修复「采购未下单却显示已入库」：整批下达把 required/shortage
        // 一并归零（转出不是齐套）。有行动、无订货单 → BUY_REQUESTED，
        // 而不是直接跳到 BUY_STOCKED。
        UUID line = UUID.randomUUID();
        UUID action = UUID.randomUUID();
        stubAllocationChain(line, action, "PURCHASE_REQUEST");
        Map<UUID, String> stages = service.lineFlowStages(
                UUID.randomUUID(),
                Map.of(line, "BUY"),
                Map.of(line, BigDecimal.ZERO),
                Map.of(line, BigDecimal.ZERO),
                Map.of(),
                Map.of());
        assertThat(stages).containsEntry(line, "BUY_REQUESTED");
    }

    @Test
    void coveredBuyLineWithLiveDemandStillCompletes() {
        // 需求仍在行内（required>0）且缺口归零 = 现货/权益覆盖齐套：保留完成口径。
        UUID line = UUID.randomUUID();
        UUID action = UUID.randomUUID();
        stubAllocationChain(line, action, "PURCHASE_REQUEST");
        Map<UUID, String> stages = service.lineFlowStages(
                UUID.randomUUID(),
                Map.of(line, "BUY"),
                Map.of(line, BigDecimal.ZERO),
                Map.of(line, new BigDecimal("10")),
                Map.of(),
                Map.of());
        assertThat(stages).containsEntry(line, "BUY_STOCKED");
    }

    @Test
    void delegatedSubcontractLineWithZeroShortageDoesNotFakeStocked() {
        // 委外同口径：整批转出行沿链路判定，未成订货单 = SC_REQUESTED。
        UUID line = UUID.randomUUID();
        UUID action = UUID.randomUUID();
        stubAllocationChain(line, action, "SUBCONTRACT_APPLICATION");
        Map<UUID, String> stages = service.lineFlowStages(
                UUID.randomUUID(),
                Map.of(line, "SUBCONTRACT"),
                Map.of(line, BigDecimal.ZERO),
                Map.of(line, BigDecimal.ZERO),
                Map.of(),
                Map.of());
        assertThat(stages).containsEntry(line, "SC_REQUESTED");
    }

    @ParameterizedTest
    @ValueSource(strings = {"BUY", "SUBCONTRACT"})
    void partiallyStockedLiveDemandStillWaitsForItsMissingSupply(String route) {
        assertThat(stage(route, "10", "6", false,
                order("10", 1, receipt("COMPLETE", "4", "4"))))
                .isEqualTo(waitReceipt(route));
    }

    @ParameterizedTest
    @ValueSource(strings = {"BUY", "SUBCONTRACT"})
    void passedSlicesStillWaitingForStockInTakePrecedenceOverRemainingShortage(String route) {
        assertThat(stage(route, "10", "6", false,
                order("10", 1, receipt("COMPLETE", "4", "4"), receipt("COMPLETE", "6", "0"))))
                .isEqualTo(prefix(route) + "WAIT_STOCK_IN");
    }

    @ParameterizedTest
    @ValueSource(strings = {"BUY", "SUBCONTRACT"})
    void partiallyInspectedReceiptDoesNotSkipQualityEvenWithSomeStockedGoods(String route) {
        assertThat(stage(route, "10", "4", false,
                order("10", 1, receipt("PARTIAL", "6", "6"))))
                .isEqualTo(prefix(route) + "WAIT_IQC");
    }

    @ParameterizedTest
    @ValueSource(strings = {"BUY", "SUBCONTRACT"})
    void missingInspectionEvidenceForOneReceiptKeepsTheQualityGate(String route) {
        assertThat(stage(route, "0", "0", false,
                order("10", 1, receipt("COMPLETE", "4", "4"), receipt(null, "0", "0"))))
                .isEqualTo(prefix(route) + "WAIT_IQC");
    }

    @ParameterizedTest
    @ValueSource(strings = {"BUY", "SUBCONTRACT"})
    void transferredLegacyLineCompletesOnlyAfterEveryReceiptCoversItsOrder(String route) {
        assertThat(stage(route, "0", "0", false,
                order("10", 1, receipt("COMPLETE", "4", "4"), receipt("COMPLETE", "6", "6"))))
                .isEqualTo(prefix(route) + "STOCKED");
    }

    @ParameterizedTest
    @ValueSource(strings = {"BUY", "SUBCONTRACT"})
    void transferredLegacyLineDoesNotTreatOnePartialReceiptAsTheWholeOrder(String route) {
        assertThat(stage(route, "0", "0", false,
                order("10", 1, receipt("COMPLETE", "4", "4"))))
                .isEqualTo(waitReceipt(route));
    }

    @ParameterizedTest
    @ValueSource(strings = {"BUY", "SUBCONTRACT"})
    void multipleOrdersFromOneSourceRetainTheEarlierUnapprovedOrder(String route) {
        assertThat(stage(route, "0", "0", false,
                order("4", 0, receipt("COMPLETE", "4", "4")),
                order("6", 1, receipt("COMPLETE", "6", "6"))))
                .isEqualTo(prefix(route) + "PENDING_FINANCE");
    }

    @ParameterizedTest
    @ValueSource(strings = {"BUY", "SUBCONTRACT"})
    void multipleOrdersFromOneSourceRetainTheEarlierOpenInspection(String route) {
        assertThat(stage(route, "0", "0", false,
                order("4", 1, receipt("PARTIAL", "2", "2")),
                order("6", 1, receipt("COMPLETE", "6", "6"))))
                .isEqualTo(prefix(route) + "WAIT_IQC");
    }

    @ParameterizedTest
    @ValueSource(strings = {"BUY", "SUBCONTRACT"})
    void oneOrdersExcessCannotCoverAnotherOrderThatHasNotArrived(String route) {
        assertThat(stage(route, "0", "0", false,
                order("4", 1, receipt("COMPLETE", "10", "10")), order("6", 1)))
                .isEqualTo(waitReceipt(route));
    }

    @ParameterizedTest
    @ValueSource(strings = {"BUY", "SUBCONTRACT"})
    void orderStockedElsewhereDoesNotOverrideTheActualAnalysisShortage(String route) {
        assertThat(stage(route, "10", "2", false,
                order("10", 1, receipt("COMPLETE", "10", "10"))))
                .isEqualTo(waitReceipt(route));
    }

    @ParameterizedTest
    @ValueSource(strings = {"BUY", "SUBCONTRACT"})
    void pendingFinanceStillWinsOverCompletedReceiptFacts(String route) {
        assertThat(stage(route, "0", "0", true,
                order("10", 1, receipt("COMPLETE", "10", "10"))))
                .isEqualTo(prefix(route) + "PENDING_FINANCE");
    }

    private String stage(String route, String required, String shortage, boolean financePending,
                         OrderFixture... orders) {
        UUID line = UUID.randomUUID();
        UUID action = UUID.randomUUID();
        UUID sourceItem = UUID.randomUUID();
        boolean purchase = "BUY".equals(route);
        String kind = purchase ? "purchase" : "subcontract";
        String receiptType = purchase ? "PURCHASE" : "SUBCONTRACT";
        List<UUID> receiptIds = new ArrayList<>();
        List<Object[]> receiptRows = new ArrayList<>();
        List<Object[]> inspectionRows = new ArrayList<>();
        for (OrderFixture order : orders) {
            for (ReceiptFixture receipt : order.receipts) {
                // Receipt, order item and source item identities must remain distinct.
                assertThat(receipt.id).isNotEqualTo(order.itemId).isNotEqualTo(sourceItem);
                receiptIds.add(receipt.id);
                receiptRows.add(new Object[]{order.itemId, receipt.id});
                if (receipt.status != null) inspectionRows.add(new Object[]{receiptType, receipt.id,
                        receipt.status, new BigDecimal(receipt.passed), new BigDecimal(receipt.stocked)});
            }
        }
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            List<?> rows = List.of();
            if (sql.contains("FROM preplan_supply_action_allocations allocation")) {
                rows = List.<Object[]>of(new Object[]{line, action,
                        purchase ? "PURCHASE_REQUEST" : "SUBCONTRACT_APPLICATION"});
            } else if (sql.contains("SELECT action_id, external_item_id")) {
                rows = List.<Object[]>of(new Object[]{action, sourceItem});
            } else if (sql.contains("FROM " + kind + "_order_item_sources src")) {
                rows = java.util.Arrays.stream(orders).map(order -> new Object[]{sourceItem,
                        order.id, order.status, order.itemId, new BigDecimal(order.quantity)}).toList();
            } else if (sql.contains("FROM procurement_order_approval_cases approval") && financePending) {
                rows = List.<Object[]>of(new Object[]{orders[0].id, "PENDING"});
            } else if (sql.contains("FROM " + kind + "_receipt_items receipt_item")) {
                rows = receiptRows;
            } else if (sql.contains("FROM procurement_inspection_items inspection")) {
                rows = inspectionRows;
            } else if (sql.contains("FROM subcontract_material_plan_items pi")) {
                rows = java.util.Arrays.stream(orders).map(order -> new Object[]{order.itemId,
                        new BigDecimal(order.quantity), new BigDecimal(order.quantity)}).toList();
            }
            Query query = mock(Query.class);
            when(query.setParameter(anyString(), org.mockito.ArgumentMatchers.any())).thenAnswer(binding -> {
                if ("receiptItemIds".equals(binding.getArgument(0))) {
                    assertThat(binding.<List<UUID>>getArgument(1)).containsExactlyInAnyOrderElementsOf(receiptIds);
                }
                return query;
            });
            when(query.getResultList()).thenReturn(rows);
            return query;
        });
        return service.lineFlowStages(UUID.randomUUID(), Map.of(line, route),
                Map.of(line, new BigDecimal(shortage)), Map.of(line, new BigDecimal(required)),
                Map.of(), Map.of()).get(line);
    }

    private static String prefix(String route) { return "BUY".equals(route) ? "BUY_" : "SC_"; }
    private static String waitReceipt(String route) { return prefix(route) + ("BUY".equals(route) ? "WAIT_RECEIPT" : "WAIT_RETURN"); }
    private static ReceiptFixture receipt(String status, String passed, String stocked) {
        return new ReceiptFixture(UUID.randomUUID(), status, passed, stocked);
    }
    private static OrderFixture order(String quantity, int status, ReceiptFixture... receipts) {
        return new OrderFixture(UUID.randomUUID(), UUID.randomUUID(), status, quantity, List.of(receipts));
    }
    private record ReceiptFixture(UUID id, String status, String passed, String stocked) {}
    private record OrderFixture(UUID id, UUID itemId, int status, String quantity, List<ReceiptFixture> receipts) {}

    /** 让链路事实装载看到一条未取消行动（外部单据类型 [type]），其余查询仍为空。 */
    private void stubAllocationChain(UUID line, UUID action, String type) {
        // 先构建查询再打桩：在 thenReturn 参数里再开 when() 会造成
        // UnfinishedStubbing（Mockito 嵌套桩限制）。
        Query allocation = mock(Query.class);
        when(allocation.setParameter(
                anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(allocation);
        when(allocation.getResultList()).thenReturn(java.util.List.<Object[]>of(
                new Object[]{line, action, type}));
        Query external = mock(Query.class);
        when(external.setParameter(
                anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(external);
        when(external.getResultList()).thenReturn(java.util.List.<Object[]>of(
                new Object[]{action, UUID.randomUUID()}));
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            if (sql.contains("FROM preplan_supply_action_allocations allocation")) {
                return allocation;
            }
            if (sql.contains("SELECT action_id, external_item_id")) {
                return external;
            }
            Query empty = mock(Query.class);
            when(empty.setParameter(
                    anyString(), org.mockito.ArgumentMatchers.any()))
                    .thenReturn(empty);
            when(empty.getResultList()).thenReturn(java.util.List.of());
            return empty;
        });
    }
}
