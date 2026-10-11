package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.PartyOpenBalancePort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.ItemSnapshot;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.common.finance.PartyOpenBalances;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * V835 财务汇率的真实 SQL 全链路（UTEN_RUN_DB_TESTS=true 时跑）：
 * 迁移本体可应用 → approve 带汇率落 case 新列（finance_total_local =
 * total_original × rate 完整乘积，snapshot_hash 不受影响）→ 缺省视为 1 →
 * 驳回不落 → review 只在已批后回填 financeExchangeRate → 待审列表折合本币
 * COALESCE(finance_total_local, amount_snapshot)。订单表头汇率全程不动
 * （V438 冻结口径：财务汇率落 case，不回写订单）。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementFinanceApprovalExchangeRatePostgresTest {
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();

    @Test
    void approveRecordsFinanceRateOnTheCaseWithoutTouchingSubmissionFacts() throws Exception {
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName("procurement_finance_rate")
                .withUsername("uten").withPassword("uten-test-only")) {
            postgres.start();
            JdbcTemplate jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword()));
            schema(jdbc);
            // 迁移本体在裁剪库上应用并自检（列精度 NUMERIC(18,6) / NUMERIC(30,10)）。
            applyV835(jdbc);
            for (String type : List.of("PURCHASE", "SUBCONTRACT")) {
                Harness harness = harness(jdbc, type);
                UUID caseId = submit(jdbc, harness);

                // 未批：review 的 financeExchangeRate 为 null，快照汇率仍是提交事实 1。
                String submittedHash = jdbc.queryForObject(
                        "SELECT snapshot_hash FROM procurement_order_approval_cases WHERE id=?",
                        String.class, caseId);
                assertThat(submittedHash)
                        .isEqualTo(HashUtil.sha256(ProcurementApprovalSnapshot.json(harness.snapshot, mapper)));
                assertThat(harness.service.review(caseId).financeExchangeRate()).isNull();
                assertThat(harness.service.review(caseId).exchangeRate())
                        .isEqualByComparingTo(BigDecimal.ONE);
                // 待审列表折合本币：无财务值时回落 amount_snapshot。
                assertThat(harness.service.tasks(1, 20, type, null).getItems())
                        .singleElement()
                        .satisfies(task -> assertThat(task.amount())
                                .isEqualByComparingTo(harness.snapshot.totalLocal()));

                // 带当日汇率通过：同一事务落 finance_exchange_rate / finance_total_local。
                harness.service.approveBatch(
                        List.of(new ProcurementApprovalContracts.BatchDecisionItem(caseId, 1L)),
                        null, new BigDecimal("6.85"));

                assertThat(jdbc.queryForObject(
                        "SELECT finance_exchange_rate FROM procurement_order_approval_cases WHERE id=?",
                        BigDecimal.class, caseId)).isEqualByComparingTo("6.85");
                assertThat(jdbc.queryForObject(
                        "SELECT finance_total_local FROM procurement_order_approval_cases WHERE id=?",
                        BigDecimal.class, caseId))
                        .isEqualByComparingTo(new BigDecimal("20").multiply(new BigDecimal("6.85")))
                        .isEqualByComparingTo("137.00");
                // 提交事实与哈希不受审批决定影响。
                assertThat(jdbc.queryForObject(
                        "SELECT submission_snapshot ->> 'exchangeRate' FROM procurement_order_approval_cases WHERE id=?",
                        String.class, caseId)).isEqualTo("1");
                assertThat(jdbc.queryForObject(
                        "SELECT snapshot_hash FROM procurement_order_approval_cases WHERE id=?",
                        String.class, caseId)).isEqualTo(submittedHash);
                assertThat(jdbc.queryForObject(
                        "SELECT status FROM procurement_order_approval_cases WHERE id=?",
                        String.class, caseId)).isEqualTo("APPROVED");
                // 事件台账留痕审批决定值。
                assertThat(jdbc.queryForObject(
                        "SELECT event_snapshot ->> 'financeExchangeRate'"
                                + " FROM procurement_order_approval_events"
                                + " WHERE case_id=? AND event_type='APPROVED'",
                        String.class, caseId)).isEqualTo("6.85");
                // 已批后 review 回填财务值；快照 exchangeRate 仍是提交事实。
                var approved = harness.service.review(caseId);
                assertThat(approved.financeExchangeRate()).isEqualByComparingTo("6.85");
                assertThat(approved.exchangeRate()).isEqualByComparingTo(BigDecimal.ONE);
                // 已批 case 不再出现在待审列表。
                assertThat(harness.service.tasks(1, 20, type, null).getItems()).isEmpty();

                // 防御性口径：待审行一旦带财务值（当前生产路径不会），折合本币取财务值。
                jdbc.update("UPDATE procurement_order_approval_cases"
                        + " SET status='PENDING', finance_total_local=999"
                        + " WHERE id=?", caseId);
                assertThat(harness.service.tasks(1, 20, type, null).getItems())
                        .singleElement()
                        .satisfies(task -> assertThat(task.amount()).isEqualByComparingTo("999"));
            }
        }
    }

    @Test
    void reconfirmationWithoutExplicitRateCarriesOverPriorFinanceRate() throws Exception {
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName("procurement_finance_rate_reconfirm")
                .withUsername("uten").withPassword("uten-test-only")) {
            postgres.start();
            JdbcTemplate jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword()));
            schema(jdbc);
            applyV835(jdbc);
            Harness harness = harness(jdbc, "PURCHASE");
            UUID caseId = submit(jdbc, harness);

            // 首轮：财务明确填 6.85 通过。
            harness.service.approveBatch(
                    List.of(new ProcurementApprovalContracts.BatchDecisionItem(caseId, 1L)),
                    null, new BigDecimal("6.85"));

            // V486 改量复核：case 回到 PENDING（新版本），财务这次没填汇率——
            // 缺省解析必须沿用首轮的财务决定值 6.85，而不是用 1 覆盖。
            jdbc.update("UPDATE procurement_order_approval_cases"
                    + " SET status='PENDING', version=2 WHERE id=?", caseId);
            harness.service.approveBatch(
                    List.of(new ProcurementApprovalContracts.BatchDecisionItem(caseId, 2L)),
                    null);
            assertThat(jdbc.queryForObject(
                    "SELECT finance_exchange_rate FROM procurement_order_approval_cases WHERE id=?",
                    BigDecimal.class, caseId)).isEqualByComparingTo("6.85");
            assertThat(jdbc.queryForObject(
                    "SELECT finance_total_local FROM procurement_order_approval_cases WHERE id=?",
                    BigDecimal.class, caseId)).isEqualByComparingTo("137.00");
            // 缺省通过不留事件汇率痕（与首轮显式值不同）。
            assertThat(jdbc.queryForList(
                    "SELECT event_snapshot ->> 'financeExchangeRate'"
                            + " FROM procurement_order_approval_events"
                            + " WHERE case_id=? AND event_type='APPROVED' ORDER BY created_at",
                    String.class, caseId)).containsExactly("6.85", null);
        }
    }

    @Test
    void omittedRateDefaultsToOneAndRejectionNeverWritesFinanceColumns() throws Exception {
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName("procurement_finance_rate_default")
                .withUsername("uten").withPassword("uten-test-only")) {
            postgres.start();
            JdbcTemplate jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword()));
            schema(jdbc);
            applyV835(jdbc);
            Harness approveSide = harness(jdbc, "PURCHASE");
            UUID defaulted = submit(jdbc, approveSide);
            // 旧两参签名（V835 前调用方）等价于缺省汇率 1。
            approveSide.service.approveBatch(
                    List.of(new ProcurementApprovalContracts.BatchDecisionItem(defaulted, 1L)), null);
            assertThat(jdbc.queryForObject(
                    "SELECT finance_exchange_rate FROM procurement_order_approval_cases WHERE id=?",
                    BigDecimal.class, defaulted)).isEqualByComparingTo(BigDecimal.ONE);
            assertThat(jdbc.queryForObject(
                    "SELECT finance_total_local FROM procurement_order_approval_cases WHERE id=?",
                    BigDecimal.class, defaulted))
                    .isEqualByComparingTo(new BigDecimal("20"));
            assertThat(jdbc.queryForObject(
                    "SELECT event_snapshot ->> 'financeExchangeRate'"
                            + " FROM procurement_order_approval_events"
                            + " WHERE case_id=? AND event_type='APPROVED'",
                    String.class, defaulted)).isNull();

            Harness rejectSide = harness(jdbc, "SUBCONTRACT");
            UUID rejected = submit(jdbc, rejectSide);
            String hashBefore = jdbc.queryForObject(
                    "SELECT snapshot_hash FROM procurement_order_approval_cases WHERE id=?",
                    String.class, rejected);
            rejectSide.service.rejectBatch(
                    List.of(new ProcurementApprovalContracts.BatchDecisionItem(rejected, 1L)),
                    "汇率口径待与银行流水核对");
            assertThat(jdbc.queryForObject(
                    "SELECT finance_exchange_rate FROM procurement_order_approval_cases WHERE id=?",
                    BigDecimal.class, rejected)).isNull();
            assertThat(jdbc.queryForObject(
                    "SELECT finance_total_local FROM procurement_order_approval_cases WHERE id=?",
                    BigDecimal.class, rejected)).isNull();
            assertThat(jdbc.queryForObject(
                    "SELECT status FROM procurement_order_approval_cases WHERE id=?",
                    String.class, rejected)).isEqualTo("REJECTED");
            assertThat(jdbc.queryForObject(
                    "SELECT snapshot_hash FROM procurement_order_approval_cases WHERE id=?",
                    String.class, rejected)).isEqualTo(hashBefore);
            assertThat(rejectSide.service.review(rejected).financeExchangeRate()).isNull();
        }
    }

    private static void applyV835(JdbcTemplate jdbc) throws Exception {
        try (var migration = getClassResource(
                "/db/migration/V835__procurement_finance_exchange_rate.sql")) {
            assertThat(migration).isNotNull();
            jdbc.execute(new String(migration.readAllBytes(), StandardCharsets.UTF_8));
        }
    }

    private static java.io.InputStream getClassResource(String name) {
        return ProcurementFinanceApprovalExchangeRatePostgresTest.class.getResourceAsStream(name);
    }

    /** 提交财务审批并按 attempt=1 查回 PENDING case id。 */
    private static UUID submit(JdbcTemplate jdbc, Harness harness) {
        harness.service.submit(harness.snapshot.orderType(), harness.orderId);
        return jdbc.queryForObject(
                "SELECT id FROM procurement_order_approval_cases"
                        + " WHERE order_type=? AND order_id=? AND attempt=1",
                UUID.class, harness.snapshot.orderType(), harness.orderId);
    }

    private record Harness(
            ProcurementFinanceApprovalService service,
            OrderSnapshot snapshot,
            UUID orderId) {
    }

    private Harness harness(JdbcTemplate jdbc, String type) {
        String prefix = type.equals("PURCHASE") ? "purchase" : "subcontract";
        UUID order = UUID.randomUUID(), item = UUID.randomUUID(),
                goods = UUID.randomUUID(), unit = UUID.randomUUID(),
                supplier = UUID.randomUUID(), currency = UUID.randomUUID(),
                settlement = UUID.randomUUID();
        jdbc.update("INSERT INTO suppliers VALUES (?, 'S1', '供应商甲')", supplier);
        jdbc.update("INSERT INTO currencies VALUES (?, '美元')", currency);
        jdbc.update("INSERT INTO settlement_methods VALUES (?, '电汇')", settlement);
        jdbc.update("INSERT INTO goods VALUES (?, 'G1', '货品甲')", goods);
        jdbc.update("INSERT INTO units VALUES (?, '个')", unit);
        jdbc.update("INSERT INTO " + prefix + "_orders VALUES (?, ?, NULL, ?, ?, NULL, NULL, NULL)",
                order, supplier, currency, settlement);
        jdbc.update("INSERT INTO " + prefix + "_order_items(id,order_id,line_no,goods_id,unit_id,"
                + "goods_code_snapshot,goods_name_snapshot,weight,remark)"
                + " VALUES (?, ?, 1, ?, ?, 'G1', '货品甲', 1.2500, '行备注')", item, order, goods, unit);
        BigDecimal amount = new BigDecimal("10").multiply(new BigDecimal("2"));
        OrderSnapshot snapshot = new OrderSnapshot(type, order, "ORDER",
                LocalDate.of(2026, 10, 10), supplier, null, currency,
                BigDecimal.ONE, settlement, BigDecimal.ZERO, null, null,
                LocalDate.of(2026, 10, 20), amount, amount,
                List.of(new ItemSnapshot(item, 1, null, goods, null, unit, BigDecimal.ONE,
                        new BigDecimal("10"), new BigDecimal("2"), amount, amount,
                        LocalDate.of(2026, 10, 20))));
        UUID actor = UUID.randomUUID(), employee = UUID.randomUUID();
        SecurityContextCurrentUser user = mock(SecurityContextCurrentUser.class);
        when(user.requireId()).thenReturn(actor);
        when(user.requireEmployeeId()).thenReturn(employee);
        AuthUser auth = mock(AuthUser.class);
        when(auth.isSuperAdmin()).thenReturn(true);
        when(auth.getPermissions()).thenReturn(Set.of());
        when(user.get()).thenReturn(Optional.of(auth));
        WorkflowReviewerEligibility eligibility = mock(WorkflowReviewerEligibility.class);
        when(eligibility.eligibleReviewersFor(anyString())).thenReturn(List.of(
                new WorkflowReviewerEligibility.EligibleReviewer(actor, employee, "财务",
                        UUID.randomUUID(), "财务部")));
        // approve/reject 走 requireEligibleReviewer；review/tasks 的动作按钮按
        // 实时资格 + 权限集计算（空权限集 → 无动作，不影响本测试断言）。
        when(eligibility.findEligible(any(UUID.class))).thenReturn(Optional.of(
                new com.uten.imp.application.port.FinanceReviewerEligibilityPort.EligibleFinanceReviewer(
                        actor, employee, "财务审核员")));
        ProcurementOrderApprovalPort port = mock(ProcurementOrderApprovalPort.class);
        when(port.orderType()).thenReturn(type);
        when(port.lockAndValidateFinanceSubmission(order)).thenReturn(snapshot);
        when(port.isFinanceApproved(order)).thenReturn(false);
        // ADR-128: 供应商余额由共用余额查询提供(本测试只看财务汇率)。
        PartyOpenBalancePort balances = mock(PartyOpenBalancePort.class);
        when(balances.suppliers(any())).thenReturn(PartyOpenBalances.empty());
        // 批量决策回执走投影查询；桩一个只读回执避免 null 元素进 List.copyOf。
        ProcurementApprovalProjectionQuery projection =
                mock(ProcurementApprovalProjectionQuery.class);
        when(projection.latestForOrder(anyString(), any(UUID.class), org.mockito.ArgumentMatchers.anyShort()))
                .thenAnswer(invocation -> new ProcurementApprovalContracts.FinanceApproval(
                        null, "APPROVED", 1, 2L, null, null, null, null, null, List.of()));
        ProcurementFinanceApprovalService service = new ProcurementFinanceApprovalService(
                List.of(port), jdbc, mapper, mock(BusinessEventPublisher.class), eligibility,
                projection, user, mock(TxSessionVars.class),
                mock(com.uten.imp.features.notice.ChainNoticeService.class),
                mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class,
                        org.mockito.Mockito.RETURNS_DEEP_STUBS),
                balances);
        return new Harness(service, snapshot, order);
    }

    private static void schema(JdbcTemplate jdbc) {
        jdbc.execute("""
                CREATE TABLE procurement_order_approval_cases(id uuid PRIMARY KEY,order_type text,order_id uuid,
                  attempt int,bill_no_snapshot text,amount_snapshot numeric,submission_snapshot jsonb,display_snapshot jsonb,snapshot_hash text,
                  submitted_by_user_id uuid,submitted_by_employee_id uuid,assignee_user_id uuid,assignee_employee_id uuid,
                  assignee_name_snapshot text,status text,version bigint,submitted_at timestamptz DEFAULT now(),
                  rejection_reason text,decided_by_user_id uuid,decided_by_employee_id uuid,decided_at timestamptz,
                  updated_at timestamptz);
                CREATE TABLE procurement_order_approval_events(id uuid,case_id uuid,event_type text,actor_user_id uuid,
                  actor_employee_id uuid,from_assignee_user_id uuid,to_assignee_user_id uuid,reason text,event_snapshot jsonb,created_at timestamptz DEFAULT now());
                CREATE TABLE procurement_order_qty_change_logs(order_type text,order_item_id uuid,old_qty numeric,new_qty numeric,changed_at timestamptz,changed_by_employee_id uuid,case_id uuid);
                CREATE TABLE inbound_expectations(id uuid,order_type text,order_id uuid,approval_case_id uuid,
                  bill_no_snapshot text,supplier_id uuid,warehouse_id uuid,expected_date date,owner_employee_id uuid,
                  status text,created_by uuid);
                CREATE TABLE inbound_expectation_items(id uuid,expectation_id uuid,order_item_id uuid,line_no int,
                  goods_id uuid,color_id uuid,unit_id uuid,unit_rate numeric,ordered_qty numeric,accepted_qty numeric,
                  expected_date date);
                CREATE TABLE suppliers(id uuid,code text,name text);
                CREATE TABLE warehouses(id uuid,name text);
                CREATE TABLE currencies(id uuid,name text);
                CREATE TABLE settlement_methods(id uuid,name text);
                CREATE TABLE employees(id uuid,full_name text);
                CREATE TABLE goods(id uuid,code text,name text, production_overproduction_rate numeric(9,6), name_en VARCHAR(255), name_en_source VARCHAR(8));
                CREATE TABLE colors(id uuid,name text);
                CREATE TABLE units(id uuid,name text);
                """);
        for (String prefix : List.of("purchase", "subcontract")) {
            jdbc.execute("CREATE TABLE " + prefix + "_orders(id uuid,supplier_id uuid,warehouse_id uuid,currency_id uuid,settlement_method_id uuid,purchaser_id uuid,maker_id uuid,remark text,deliver_date date)");
            jdbc.execute("CREATE TABLE " + prefix + "_order_items(id uuid,order_id uuid,line_no int,goods_id uuid,color_id uuid,unit_id uuid,goods_code_snapshot text,goods_name_snapshot text,weight numeric(18,4),remark text,source_doc_no text,is_deleted boolean DEFAULT FALSE)");
        }
    }
}
