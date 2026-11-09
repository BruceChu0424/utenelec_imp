package com.uten.imp.features.warehouse.inbound;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.FinanceReviewerEligibilityPort;
import com.uten.imp.application.port.WarehouseTaskScopePort.WarehouseTaskScope;
import com.uten.imp.features.purchase.receipt.ReceiptPriceMasker;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;

class ProcurementArrivalExpectationQueryContractTest {

    @Test
    void defaultWarehouseUsesTheGoodsMasterWithSourceScopeRatherThanReceiptHistory() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/ProcurementArrivalControlService.java"));
        int start = source.indexOf("private InboundExpectationTask expectationTask(");
        int end = source.indexOf("Map<UUID, List<PreplanInboundAllocationReadPort.AllocationView>> expected", start);
        String query = source.substring(start, end);
        assertThat(query).contains("WarehouseMasterDefaultsSql.owningWarehouseJoin(\"goods\", \"remembered\")")
                .contains("fn_warehouse_same_main(remembered.id")
                .doesNotContain("LEFT JOIN LATERAL", "history.updated_at", "FROM purchase_receipt_items line");
    }

    @Test
    void listAndCountShareTheRealSubcontractOutboundVisibilityPredicate() {
        CapturingJdbcTemplate jdbc = new CapturingJdbcTemplate();
        ProcurementArrivalControlService service = service(jdbc);

        service.expectations(1, 20, "", "");

        assertThat(jdbc.expectationListSql).isNotNull();
        assertThat(jdbc.expectationCountSql).isNotNull();
        assertThat(parenthesisBalance(jdbc.expectationListSql)).isZero();
        assertThat(parenthesisBalance(jdbc.expectationCountSql)).isZero();
        for (String sql : List.of(jdbc.expectationListSql, jdbc.expectationCountSql)) {
            assertThat(sql.replaceAll("\\s+", " "))
                    .contains("expectation.order_type <> 'SUBCONTRACT'")
                    // ADR-143 §三.6: 委外可回厂量 = 已发直属物料能做成的完整套数(逐种取短板)
                    // + 财务已批准入库的自带料 + 已退回待补的 IQC 不合格量 - 已审核回厂。
                    .contains("fn_subcontract_returnable_qty(supplied_item.id)")
                    .contains("supplied_item.arrival_overage_posted_qty")
                    .contains("procurement_iqc_rejection_cases rejection")
                    .contains("visible_item.expectation_id = expectation.id")
                    .doesNotContain("flow_mode")
                    .doesNotContain("procurement_iqc_replacement_allocations");
        }
    }

    /**
     * 2026-11-08 口径修订的契约钉子: 委外催收量(预计到货列表/计数共用)的基准是订货量
     * (supplied_item.qty), 不再是订量×(1+损耗)(fn_subcontract_normal_receipt_limit);
     * 已过账超量(arrival_overage_posted_qty)不进催收目标, 只留在物理可回厂分支放宽可收上限。
     */
    @Test
    void subcontractCollectionTargetIsTheOrderedQuantityNotTheLossAllowance() {
        CapturingJdbcTemplate jdbc = new CapturingJdbcTemplate();
        service(jdbc).expectations(1, 20, "", "");

        for (String sql : List.of(jdbc.expectationListSql, jdbc.expectationCountSql)) {
            String flat = sql.replaceAll("\\s+", " ");
            // 催收基准 = 订量 + 已退货 + IQC 实物退回待补 − 已收 − 已结案损耗
            assertThat(flat)
                    .contains("GREATEST(COALESCE(supplied_item.qty,0) + COALESCE(supplied_item.returned_qty,0)")
                    .contains("- COALESCE(supplied_item.received_qty,0) - fn_subcontract_settled_loss_qty(supplied_item.id),0)")
                    // 允许损耗上限不再是催收基准
                    .doesNotContain("fn_subcontract_normal_receipt_limit")
                    // 物理可回厂分支保持原样: 套数 + 超收过账 + IQC 待补 − 已收, 仍是 LEAST 的第二支
                    .contains("GREATEST(fn_subcontract_returnable_qty(supplied_item.id)"
                            + " + COALESCE(supplied_item.arrival_overage_posted_qty,0)")
                    .contains("LEAST( GREATEST(COALESCE(supplied_item.qty,0)");
        }
    }

    @ParameterizedTest
    @MethodSource("expectationSortCases")
    void sortingKeepsPaginationSeparateAndBindsFiltersBeforePageArguments(
            String orderType, String sort, String order, String expectedOrderBy) {
        CapturingJdbcTemplate jdbc = new CapturingJdbcTemplate();
        UUID supplierId = UUID.randomUUID();
        String billNo = orderType.equals("PURCHASE")
                ? "CD20260926000001" : "EO20260926000001";

        service(jdbc).expectations(3, 7, orderType, "", supplierId,
                WarehouseTaskScope.ALL, sort, order, " " + billNo + " ");

        assertThat(jdbc.expectationListSql)
                .matches("(?s).*" + Pattern.quote(expectedOrderBy)
                        + "\\s+LIMIT \\? OFFSET \\?\\s*");
        for (String sql : List.of(jdbc.expectationListSql, jdbc.expectationCountSql)) {
            assertThat(sql).contains("expectation.order_type = ?")
                    .contains("expectation.supplier_id = ?")
                    .contains("expectation.bill_no_snapshot = ?")
                    .doesNotContain(billNo, supplierId.toString());
        }
        assertThat(jdbc.expectationCountArgs).containsExactly(orderType, supplierId, billNo);
        assertThat(jdbc.expectationListArgs).containsExactly(orderType, supplierId, billNo, 7, 14);
    }

    private static Stream<Arguments> expectationSortCases() {
        String defaultOrderBy = "ORDER BY expectation.expected_date NULLS LAST,"
                + " expectation.created_at, expectation.id";
        String billNoTieBreakers = " NULLS LAST, expectation.expected_date NULLS LAST,"
                + " expectation.created_at, expectation.id";
        return Stream.of("PURCHASE", "SUBCONTRACT").flatMap(orderType -> Stream.of(
                Arguments.of(orderType, null, null, defaultOrderBy),
                Arguments.of(orderType, "billNo", "asc",
                        "ORDER BY expectation.bill_no_snapshot ASC" + billNoTieBreakers),
                Arguments.of(orderType, "billNo", "desc",
                        "ORDER BY expectation.bill_no_snapshot DESC" + billNoTieBreakers),
                Arguments.of(orderType, "unknown", "desc", defaultOrderBy)));
    }

    @Test
    void destinationPreviewUsesBasicUnitsAndIsBatchMappedOnce() throws Exception {
        assertThat(ProcurementArrivalControlService.receivableBaseQty(
                new BigDecimal("2"), BigDecimal.ZERO, new BigDecimal("24")))
                .isEqualByComparingTo("48");
        assertThat(Arrays.stream(ProcurementArrivalContracts.InboundExpectationItem.class
                        .getRecordComponents())
                .map(java.lang.reflect.RecordComponent::getName).toList())
                .contains("baseUnitId", "baseUnitName", "expectedAllocations");
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/warehouse/inbound/"
                        + "ProcurementArrivalControlService.java"),
                StandardCharsets.UTF_8);
        assertThat(source)
                .contains("inboundAllocationRead.expectedForOrderItems(")
                .contains("base_unit.name AS base_unit_name")
                .contains("OrderItemQuantity(");
        assertThat(count(source, "inboundAllocationRead.expectedForOrderItems("))
                .isEqualTo(1);
    }

    private static int count(String value, String token) {
        return (value.length() - value.replace(token, "").length()) / token.length();
    }

    private static ProcurementArrivalControlService service(CapturingJdbcTemplate jdbc) {
        return new ProcurementArrivalControlService(
                jdbc,
                new ObjectMapper(),
                mock(BusinessEventPublisher.class),
                mock(SecurityContextCurrentUser.class),
                mock(TxSessionVars.class),
                mock(FinanceReviewerEligibilityPort.class),
                mock(ReceiptPriceMasker.class),
                com.uten.imp.support.FulfillmentMutationLockTestSupport.procurementLocks());
    }

    private static int parenthesisBalance(String sql) {
        int balance = 0;
        for (int index = 0; index < sql.length(); index++) {
            balance += switch (sql.charAt(index)) {
                case '(' -> 1;
                case ')' -> -1;
                default -> 0;
            };
            assertThat(balance)
                    .as("SQL closes a parenthesis before it is opened at index %s", index)
                    .isGreaterThanOrEqualTo(0);
        }
        return balance;
    }

    private static final class CapturingJdbcTemplate extends JdbcTemplate {
        private String expectationListSql;
        private String expectationCountSql;
        private Object[] expectationListArgs;
        private Object[] expectationCountArgs;

        @Override
        public <T> T queryForObject(String sql, Class<T> requiredType, Object... args) {
            if (sql.contains("FROM inbound_expectations expectation")) {
                expectationCountSql = sql;
                expectationCountArgs = args.clone();
            }
            return requiredType.cast(0L);
        }

        @Override
        public <T> List<T> query(String sql, RowMapper<T> rowMapper, Object... args) {
            if (sql.contains("GROUP BY expectation.id")) {
                expectationListSql = sql;
                expectationListArgs = args.clone();
            }
            return List.of();
        }
    }
}
