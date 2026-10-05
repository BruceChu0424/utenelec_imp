package com.uten.imp.features.production.analysis;

import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class MaterialAnalysisSupplyProgressServiceTest {

    @Test
    void purchaseSiblingApprovedReceiptDoesNotCompleteUnreceivedTargetLine() {
        ProjectionScenario scenario = new ProjectionScenario(true, false);

        MaterialAnalysisContracts.SupplyProgressView view = scenario.service()
                .supplyProgress(scenario.analysisId, scenario.materialLineId);

        assertThat(step(view, "RECEIVED").state()).isEqualTo("CURRENT");
        assertThat(step(view, "RECEIVED").docNo()).isNull();
        assertThat(step(view, "QUALITY").state()).isEqualTo("CURRENT");
        assertThat(scenario.executions)
                .filteredOn(execution -> execution.sql().contains(
                        "FROM purchase_receipt_items receipt_item"))
                .singleElement()
                .satisfies(execution -> {
                    assertThat(execution.sql())
                            .contains("receipt_item.order_item_id IN (:orderItemIds)")
                            .doesNotContain("order_item.order_id IN (:orderIds)");
                    assertThat(execution.parameters())
                            .containsEntry("orderItemIds", List.of(scenario.targetOrderItemId));
                });
        assertThat(scenario.executions)
                .noneMatch(execution -> execution.sql().contains(
                        "FROM procurement_inspection_items"));
    }

    @Test
    void subcontractSiblingPassAndOpenDrawDoNotPolluteTargetLine() {
        ProjectionScenario scenario = new ProjectionScenario(false, true);

        MaterialAnalysisContracts.SupplyProgressView view = scenario.service()
                .supplyProgress(scenario.analysisId, scenario.materialLineId);

        assertThat(step(view, "DRAW").state()).isEqualTo("DONE");
        assertThat(step(view, "DRAW").detail())
                .isEqualTo("已领 10 / 10(直属物料已全部发外)");
        assertThat(step(view, "DRAW").docNo()).isEqualTo("FL-001");
        assertThat(step(view, "RECEIVED").state()).isEqualTo("DONE");
        assertThat(step(view, "QUALITY").state()).isEqualTo("REJECTED");
        assertThat(step(view, "QUALITY").detail()).isEqualTo("全部判定不合格");
        assertThat(step(view, "STOCKED").state()).isEqualTo("WAITING");
        assertThat(view.steps()).extracting(MaterialAnalysisContracts.SupplyProgressStep::key)
                .doesNotContain("PREPARATION", "TARGET_OUTBOUND");

        assertThat(scenario.executions)
                .filteredOn(execution -> execution.sql().contains(
                        "fn_subcontract_draw_summary"))
                .singleElement()
                .satisfies(execution -> {
                    assertThat(execution.sql())
                            .contains("item.id IN (:orderItemIds)")
                            .doesNotContain("flow_mode")
                            .doesNotContain("preparation_status");
                    assertThat(execution.parameters())
                            .containsEntry("orderItemIds", List.of(scenario.targetOrderItemId));
                });
        assertThat(scenario.executions)
                .filteredOn(execution -> execution.sql().contains(
                        "FROM procurement_inspection_items"))
                .singleElement()
                .satisfies(execution -> {
                    assertThat(execution.sql())
                            .contains("receipt_item_id IN (:receiptItemIds)")
                            .doesNotContain("receipt_id IN (:receiptIds)");
                    assertThat(execution.parameters())
                            .containsEntry("receiptItemIds", List.of(scenario.targetReceiptItemId));
                });
    }

    @Test
    void partialDrawShowsDrawnSetsAndDrawableRemainderWithoutSummingMaterials() {
        ProjectionScenario scenario = new ProjectionScenario(false, false);
        scenario.drawSummary = new Object[]{new BigDecimal("2"), new BigDecimal("100"), 2,
                new BigDecimal("40"), new BigDecimal("10"), new BigDecimal("20"), new BigDecimal("30"),
                false, true, false, BigDecimal.ZERO};

        MaterialAnalysisContracts.SupplyProgressView view = scenario.service()
                .supplyProgress(scenario.analysisId, scenario.materialLineId);

        // 订货单位换算率 2：已领 40 套 = 80，订货 100 = 200(委外件基本量)。
        assertThat(step(view, "DRAW").state()).isEqualTo("CURRENT");
        assertThat(step(view, "DRAW").detail())
                .startsWith("已领 80 / 200")
                .contains("可领 40")
                .contains("已提交领料 20");
        assertThat(step(view, "RECEIVED").state()).isEqualTo("CURRENT");
        assertThat(step(view, "RECEIVED").detail()).isEqualTo("等待登记委外件回厂");
    }

    @Test
    void nothingDrawnYetBlocksReturnRegistration() {
        ProjectionScenario scenario = new ProjectionScenario(false, false);
        scenario.drawSummary = new Object[]{BigDecimal.ONE, new BigDecimal("10"), 1,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, new BigDecimal("10"),
                false, true, false, BigDecimal.ZERO};

        MaterialAnalysisContracts.SupplyProgressView view = scenario.service()
                .supplyProgress(scenario.analysisId, scenario.materialLineId);

        assertThat(step(view, "DRAW").detail()).contains("等待物料备齐");
        assertThat(step(view, "RECEIVED").state()).isEqualTo("WAITING");
        assertThat(step(view, "RECEIVED").detail()).isEqualTo("至少发出一批直属物料后方可登记回厂");
    }

    @Test
    void batchReturnBelowOrderQuantityKeepsReturnStepInProgress() {
        ProjectionScenario scenario = new ProjectionScenario(false, true);
        scenario.drawSummary = new Object[]{BigDecimal.ONE, new BigDecimal("10"), 1,
                new BigDecimal("6"), BigDecimal.ZERO, BigDecimal.ZERO, new BigDecimal("4"),
                false, true, false, new BigDecimal("4")};

        MaterialAnalysisContracts.SupplyProgressView view = scenario.service()
                .supplyProgress(scenario.analysisId, scenario.materialLineId);

        assertThat(step(view, "RECEIVED").state()).isEqualTo("CURRENT");
        assertThat(step(view, "RECEIVED").detail()).isEqualTo("已回厂 4 / 10(分批回厂)");
        assertThat(step(view, "RECEIVED").docNo()).isEqualTo("WSH-001");
    }

    @Test
    void approvedSubcontractWithoutDrawPlanFailsClosed() {
        // ADR-143 §二.3：缺 BOM 的委外件不能下单，已批准的明细一定有领料计划行；
        // 万一没有，进度停在「领料计划尚未生成」，不放行回厂登记。
        ProjectionScenario scenario = new ProjectionScenario(false, false);
        scenario.drawSummary = new Object[]{BigDecimal.ONE, new BigDecimal("10"), 0,
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                false, false, false, BigDecimal.ZERO};

        MaterialAnalysisContracts.SupplyProgressView view = scenario.service()
                .supplyProgress(scenario.analysisId, scenario.materialLineId);

        assertThat(step(view, "DRAW").state()).isEqualTo("WAITING");
        assertThat(step(view, "DRAW").detail()).isEqualTo("领料计划尚未生成");
        assertThat(step(view, "RECEIVED").state()).isEqualTo("WAITING");
        assertThat(scenario.executions).noneMatch(execution ->
                execution.sql().contains("FROM subcontract_material_issues i"));
    }

    @Test
    void delegatedZeroRequirementIsCompletedWithoutDisplayingZeroOverZero() {
        ProjectionScenario scenario = new ProjectionScenario(true, true);
        scenario.requiredQty = BigDecimal.ZERO;
        scenario.shortageQty = BigDecimal.ZERO;
        scenario.delegatedQty = new BigDecimal("10000");

        MaterialAnalysisContracts.SupplyProgressView view = scenario.service()
                .supplyProgress(scenario.analysisId, scenario.materialLineId);

        MaterialAnalysisContracts.SupplyProgressStep stocked =
                step(view, "STOCKED");
        assertThat(stocked.state()).isEqualTo("DONE");
        assertThat(stocked.detail())
                .isEqualTo("该供给行动的合格权益已移交自制子件 10000"
                        + " · 原路径本批无需重复备料")
                .doesNotContain("0 / 0");
    }

    @Test
    void delegatedPurchaseWithoutArrivalIsWaitingNotStocked() {
        // 2026-09-06 修复「采购未下单却显示已入库」：整批下达后 required/shortage
        // 归零是转出不是齐套。无移交权益且链路未到货时，末步必须是 WAITING，
        // 不能跳过下单/收货/验收直接完成。
        ProjectionScenario scenario = new ProjectionScenario(true, false);
        scenario.requiredQty = BigDecimal.ZERO;
        scenario.shortageQty = BigDecimal.ZERO;

        MaterialAnalysisContracts.SupplyProgressView view = scenario.service()
                .supplyProgress(scenario.analysisId, scenario.materialLineId);

        assertThat(step(view, "ORDER_PLACED").state()).isEqualTo("DONE");
        assertThat(step(view, "RECEIVED").state()).isEqualTo("CURRENT");
        assertThat(step(view, "QUALITY").state()).isEqualTo("CURRENT");
        assertThat(step(view, "STOCKED").state()).isEqualTo("WAITING");
        assertThat(step(view, "STOCKED").detail())
                .contains("本批需求已转出采购")
                .contains("等待到货合格入库");
    }

    @Test
    void delegatedPurchaseWithoutOrderIsWaitingAtRequestStep() {
        // 更早断点：订货单都还没生成（采购员未下单）——下单进行中、末步未开始。
        ProjectionScenario scenario = new ProjectionScenario(true, false);
        scenario.requiredQty = BigDecimal.ZERO;
        scenario.shortageQty = BigDecimal.ZERO;
        scenario.orderExists = false;

        MaterialAnalysisContracts.SupplyProgressView view = scenario.service()
                .supplyProgress(scenario.analysisId, scenario.materialLineId);

        assertThat(step(view, "ORDER_PLACED").state()).isEqualTo("CURRENT");
        assertThat(step(view, "FINANCE").state()).isEqualTo("WAITING");
        assertThat(step(view, "RECEIVED").state()).isEqualTo("WAITING");
        assertThat(step(view, "QUALITY").state()).isEqualTo("WAITING");
        assertThat(step(view, "STOCKED").state()).isEqualTo("WAITING");
        assertThat(step(view, "STOCKED").detail())
                .contains("本批需求已转出采购");
    }

    @Test
    void safetyOnlyActionIsLinkedByPhysicalDimensionAndExplainedAsPublicStock() {
        ProjectionScenario scenario = new ProjectionScenario(true, false);
        scenario.splitProgress = new Object[]{
                BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                new BigDecimal("100"), new BigDecimal("40"),
                new BigDecimal("60")};

        MaterialAnalysisContracts.SupplyProgressView view = scenario.service()
                .supplyProgress(scenario.analysisId, scenario.materialLineId);

        assertThat(step(view, "REQUEST_SUBMITTED").detail())
                .contains("生产需求绑定 0/0")
                .contains("公共安全补库 40/100(在途 60)");
        assertThat(scenario.executions)
                .filteredOn(execution -> execution.sql().contains("LIMIT 1"))
                .singleElement()
                .satisfies(execution -> {
                    assertThat(execution.sql())
                            .contains("action.safety_replenishment_qty > 0")
                            .contains("action.goods_id = :goodsId")
                            .contains("action.warehouse_id = (");
                    assertThat(execution.parameters())
                            .containsEntry("goodsId", scenario.goodsId)
                            .containsEntry("colorId", scenario.colorId);
                });
    }

    @Test
    void makeProgressUsesExactChildItemAndReturnsClickableProductionPlan() {
        ProjectionScenario scenario = new ProjectionScenario(true, false);
        scenario.make = true;
        scenario.shortageQty = BigDecimal.ZERO;

        MaterialAnalysisContracts.SupplyProgressView view = scenario.service()
                .supplyProgress(scenario.analysisId, scenario.materialLineId);

        assertThat(view.route()).isEqualTo("MAKE");
        MaterialAnalysisContracts.SupplyProgressStep plan = step(view, "PLAN");
        assertThat(plan.docNo()).isEqualTo("SJ-MAKE-001");
        assertThat(plan.documentType()).isEqualTo("PRODUCTION_PLAN");
        assertThat(plan.documentId()).isEqualTo(scenario.makePlanId);
        assertThat(scenario.executions)
                .filteredOn(execution -> execution.sql().contains(
                        "FROM production_plans plan"))
                .singleElement()
                .satisfies(execution -> {
                    assertThat(execution.parameters())
                            .containsEntry("analysisId", scenario.analysisId)
                            .containsEntry("makeChildAnalysisItemId",
                                    scenario.makeChildAnalysisItemId);
                    assertThat(execution.parameters().values())
                            .doesNotContain(scenario.analysisItemId);
                });
    }

    private static MaterialAnalysisContracts.SupplyProgressStep step(
            MaterialAnalysisContracts.SupplyProgressView view, String key) {
        return view.steps().stream()
                .filter(candidate -> key.equals(candidate.key()))
                .findFirst()
                .orElseThrow();
    }

    private record QueryExecution(String sql, Map<String, Object> parameters) {
    }

    private static final class ProjectionScenario {
        private static final OffsetDateTime AT =
                OffsetDateTime.parse("2026-08-20T09:00:00+08:00");

        private final boolean purchase;
        private final boolean targetHasReceipt;
        private BigDecimal requiredQty = BigDecimal.TEN;
        private BigDecimal shortageQty = BigDecimal.TEN;
        private BigDecimal delegatedQty = BigDecimal.ZERO;
        private Object[] splitProgress;
        private boolean make;
        private boolean orderExists = true;
        /** fn_subcontract_draw_summary 行：换算率、订货量、物料种数、已领、待发、可领、还缺(套)、
         * 全部发齐、领料开放、订货单结案、已回厂(基本量)。默认 10 套全部领齐、全部回厂。 */
        private Object[] drawSummary = new Object[]{BigDecimal.ONE, new BigDecimal("10"), 1,
                new BigDecimal("10"), BigDecimal.ZERO, BigDecimal.ZERO, BigDecimal.ZERO,
                true, true, false, new BigDecimal("10")};
        private final UUID analysisId = UUID.randomUUID();
        private final UUID materialLineId = UUID.randomUUID();
        private final UUID analysisItemId = UUID.randomUUID();
        private final UUID makerId = UUID.randomUUID();
        private final UUID actionId = UUID.randomUUID();
        private final UUID goodsId = UUID.randomUUID();
        private final UUID colorId = UUID.randomUUID();
        private final UUID externalItemId = UUID.randomUUID();
        private final UUID makeChildAnalysisItemId = UUID.randomUUID();
        private final UUID makePlanId = UUID.randomUUID();
        private final UUID orderId = UUID.randomUUID();
        private final UUID targetOrderItemId = UUID.randomUUID();
        private final UUID siblingOrderItemId = UUID.randomUUID();
        private final UUID receiptId = UUID.randomUUID();
        private final UUID targetReceiptItemId = UUID.randomUUID();
        private final UUID siblingReceiptItemId = UUID.randomUUID();
        private final List<QueryExecution> executions = new ArrayList<>();

        private ProjectionScenario(boolean purchase, boolean targetHasReceipt) {
            this.purchase = purchase;
            this.targetHasReceipt = targetHasReceipt;
        }

        private MaterialAnalysisSupplyProgressService service() {
            EntityManager em = mock(EntityManager.class);
            when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
                String sql = invocation.getArgument(0);
                Query query = mock(Query.class);
                Map<String, Object> parameters = new HashMap<>();
                when(query.setParameter(anyString(), any())).thenAnswer(parameterCall -> {
                    parameters.put(parameterCall.getArgument(0), parameterCall.getArgument(1));
                    return query;
                });
                when(query.getResultList()).thenAnswer(ignored -> {
                    executions.add(new QueryExecution(sql, Map.copyOf(parameters)));
                    return result(sql, parameters);
                });
                when(query.getSingleResult()).thenAnswer(ignored -> {
                    executions.add(new QueryExecution(sql, Map.copyOf(parameters)));
                    if (sql.contains(
                            "FROM v_preplan_make_entitlement_delegation_state")) {
                        return delegatedQty;
                    }
                    throw new AssertionError("Unexpected scalar query: " + sql);
                });
                return query;
            });
            ProductionDocumentAccessPolicy access = mock(ProductionDocumentAccessPolicy.class);
            EmployeeNameResolver names = mock(EmployeeNameResolver.class);
            when(names.nameWithCodeOf(any())).thenReturn("测试员工");
            return new MaterialAnalysisSupplyProgressService(em, access, names);
        }

        private List<?> result(String sql, Map<String, Object> parameters) {
            if (sql.contains("fn_subcontract_draw_summary")) {
                return rows(drawSummary);
            }
            if (sql.contains("SELECT maker_id FROM production_material_analyses")) {
                return List.of(makerId);
            }
            if (sql.contains("FROM production_material_analysis_materials material")) {
                return rows(new Object[]{analysisItemId, requiredQty,
                        shortageQty, "MAT-01", "目标物料", goodsId, colorId});
            }
            if (sql.contains("SELECT DISTINCT request.bill_no")) {
                return rows(new Object[]{purchase ? "SQ-001" : "WW-001", AT});
            }
            if (sql.contains("FROM production_plans plan")) {
                return make
                        ? rows(new Object[]{makePlanId, "SJ-MAKE-001", 1,
                                true, AT, makerId})
                        : List.of();
            }
            if (sql.contains("SELECT DISTINCT ord.id")) {
                return orderExists
                        ? rows(new Object[]{orderId, purchase ? "CG-001" : "WO-001",
                                1, false, AT, makerId, targetOrderItemId})
                        : List.of();
            }
            if (sql.contains("FROM procurement_order_approval_cases")) {
                return rows(new Object[]{"APPROVED", AT, makerId});
            }
            if (sql.contains("FROM subcontract_material_issues i")) {
                return rows(new Object[]{"FL-001", AT, makerId});
            }
            if (sql.contains("FROM purchase_receipt_items receipt_item")) {
                // Only the sibling order line was received and passed. The old order-id filter
                // sees it; the exact target order-item filter correctly returns no receipt.
                if (parameters.containsKey("orderItemIds")) {
                    return List.of();
                }
                return rows(new Object[]{receiptId, "SH-001", 1, AT, makerId,
                        siblingReceiptItemId});
            }
            if (sql.contains("FROM subcontract_receipt_items receipt_item")) {
                if (!targetHasReceipt) {
                    return List.of();
                }
                return rows(new Object[]{receiptId, "WSH-001", 1, AT, makerId,
                        targetReceiptItemId});
            }
            if (sql.contains("FROM procurement_inspection_items")) {
                // Target line failed, while a sibling line on the same receipt passed. Filtering
                // by receipt header would produce DONE; filtering by target receipt item is FAIL.
                return parameters.containsKey("receiptItemIds")
                        ? rows(new Object[]{1L, 0L, BigDecimal.ZERO,
                                new BigDecimal("10"), null, BigDecimal.ZERO})
                        : rows(new Object[]{2L, 0L, new BigDecimal("10"),
                                new BigDecimal("10"), AT,
                                new BigDecimal("10")});
            }
            if (sql.contains("FROM v_preplan_buy_action_slice_progress progress")) {
                return splitProgress == null ? List.of() : rows(splitProgress);
            }
            if (sql.contains("FROM preplan_supply_action_allocations allocation")
                    && sql.contains("LIMIT 1")) {
                return rows(new Object[]{actionId,
                        make ? "MAKE" : purchase ? "BUY" : "SUBCONTRACT",
                        make ? "PREPLAN_MAKE_TASK"
                                : purchase ? "PURCHASE_REQUEST" : "SUBCONTRACT_APPLICATION",
                        make ? makeChildAnalysisItemId : externalItemId,
                        make ? "自制备料 2026-08-30 abcd"
                                : purchase ? "SQ-001" : "WW-001",
                        AT, makerId});
            }
            throw new AssertionError("Unexpected native query: " + sql);
        }

        private static List<Object[]> rows(Object[]... rows) {
            return List.of(rows);
        }
    }
}
