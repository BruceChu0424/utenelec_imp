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
    void subcontractSiblingPassAndOpenOutboundDoNotPolluteTargetLine() {
        ProjectionScenario scenario = new ProjectionScenario(false, true);

        MaterialAnalysisContracts.SupplyProgressView view = scenario.service()
                .supplyProgress(scenario.analysisId, scenario.materialLineId);

        assertThat(step(view, "MATERIAL_ISSUED").state()).isEqualTo("DONE");
        assertThat(step(view, "MATERIAL_ISSUED").detail())
                .isEqualTo("已出仓 10 / 计划 10");
        assertThat(step(view, "RECEIVED").state()).isEqualTo("DONE");
        assertThat(step(view, "QUALITY").state()).isEqualTo("REJECTED");
        assertThat(step(view, "QUALITY").detail()).isEqualTo("全部判定不合格");

        assertThat(scenario.executions)
                .filteredOn(execution -> execution.sql().contains(
                        "FROM subcontract_material_plans p"))
                .singleElement()
                .satisfies(execution -> {
                    assertThat(execution.sql())
                            .contains("pi.order_item_id IN (:orderItemIds)")
                            .doesNotContain("p.order_id IN (:orderIds)");
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
        private final UUID analysisId = UUID.randomUUID();
        private final UUID materialLineId = UUID.randomUUID();
        private final UUID analysisItemId = UUID.randomUUID();
        private final UUID makerId = UUID.randomUUID();
        private final UUID actionId = UUID.randomUUID();
        private final UUID externalItemId = UUID.randomUUID();
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
            if (sql.contains("SELECT maker_id FROM production_material_analyses")) {
                return List.of(makerId);
            }
            if (sql.contains("FROM production_material_analysis_materials material")) {
                return rows(new Object[]{analysisItemId, requiredQty,
                        shortageQty, "MAT-01", "目标物料"});
            }
            if (sql.contains("SELECT DISTINCT request.bill_no")) {
                return rows(new Object[]{purchase ? "SQ-001" : "WW-001", AT});
            }
            if (sql.contains("SELECT DISTINCT ord.id")) {
                return rows(new Object[]{orderId, purchase ? "CG-001" : "WO-001",
                        1, false, AT, makerId, targetOrderItemId});
            }
            if (sql.contains("FROM procurement_order_approval_cases")) {
                return rows(new Object[]{"APPROVED", AT, makerId});
            }
            if (sql.contains("FROM subcontract_material_plans p")) {
                // Target line is fully issued. The sibling line remains open; an order-level
                // projection would incorrectly return the contaminated second aggregate.
                return parameters.containsKey("orderItemIds")
                        ? rows(new Object[]{new BigDecimal("10"), new BigDecimal("10"),
                                BigDecimal.ZERO, 1L})
                        : rows(new Object[]{new BigDecimal("30"), new BigDecimal("20"),
                                new BigDecimal("10"), 1L});
            }
            if (sql.contains("FROM subcontract_material_issues i")) {
                return rows(new Object[]{"FL-001", 1, AT, makerId});
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
                                new BigDecimal("10"), null})
                        : rows(new Object[]{2L, 0L, new BigDecimal("10"),
                                new BigDecimal("10"), AT});
            }
            if (sql.contains("FROM preplan_supply_action_allocations allocation")
                    && sql.contains("LIMIT 1")) {
                return rows(new Object[]{actionId, purchase ? "BUY" : "SUBCONTRACT",
                        purchase ? "PURCHASE_REQUEST" : "SUBCONTRACT_APPLICATION",
                        externalItemId, purchase ? "SQ-001" : "WW-001", AT, makerId});
            }
            throw new AssertionError("Unexpected native query: " + sql);
        }

        private static List<Object[]> rows(Object[]... rows) {
            return List.of(rows);
        }
    }
}
