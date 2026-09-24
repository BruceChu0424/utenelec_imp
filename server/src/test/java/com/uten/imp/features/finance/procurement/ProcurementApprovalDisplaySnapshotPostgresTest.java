package com.uten.imp.features.finance.procurement;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.ProcurementOrderApprovalPort;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.ItemSnapshot;
import com.uten.imp.application.port.ProcurementOrderApprovalPort.OrderSnapshot;
import com.uten.imp.common.util.HashUtil;
import com.uten.imp.features.admin.workflow.WorkflowReviewerEligibility;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Real SQL covers both application case writers and the immutable display boundary. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProcurementApprovalDisplaySnapshotPostgresTest {
    private final ObjectMapper mapper = new ObjectMapper().findAndRegisterModules();

    @Test
    void bothSubmittersFreezeExtrasAndSourcesWithoutChangingCanonicalHash() throws Exception {
        try (var postgres = new PostgreSQLContainer<>("postgres:16-alpine")) {
            postgres.start();
            JdbcTemplate jdbc = new JdbcTemplate(new DriverManagerDataSource(
                    postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword()));
            schema(jdbc);
            UUID legacy = UUID.randomUUID();
            jdbc.update("INSERT INTO procurement_order_approval_cases(id,submission_snapshot,snapshot_hash) VALUES (?, '{}'::jsonb, 'legacy')", legacy);
            try (var migration = getClass().getResourceAsStream("/db/migration/V691__procurement_approval_display_snapshot.sql")) {
                assertThat(migration).isNotNull();
                jdbc.execute(new String(migration.readAllBytes(), StandardCharsets.UTF_8));
            }
            assertThat(jdbc.queryForObject("SELECT display_snapshot::text FROM procurement_order_approval_cases WHERE id=?", String.class, legacy)).isNull();
            assertThat(jdbc.queryForObject("SELECT snapshot_hash FROM procurement_order_approval_cases WHERE id=?", String.class, legacy)).isEqualTo("legacy");

            UUID actor = UUID.randomUUID(), employee = UUID.randomUUID();
            SecurityContextCurrentUser user = mock(SecurityContextCurrentUser.class);
            when(user.requireId()).thenReturn(actor);
            when(user.requireEmployeeId()).thenReturn(employee);
            AuthUser auth = mock(AuthUser.class);
            when(auth.isSuperAdmin()).thenReturn(true);
            when(user.get()).thenReturn(Optional.of(auth));
            WorkflowReviewerEligibility eligibility = mock(WorkflowReviewerEligibility.class);
            when(eligibility.eligibleReviewersFor(anyString())).thenReturn(List.of(new WorkflowReviewerEligibility.EligibleReviewer(actor, employee, "财务", UUID.randomUUID(), "财务部")));

            for (String type : List.of("PURCHASE", "SUBCONTRACT")) {
                String prefix = type.equals("PURCHASE") ? "purchase" : "subcontract";
                String extraColumn = type.equals("PURCHASE") ? "gift_qty" : "allowed_loss_pct";
                String extraKey = type.equals("PURCHASE") ? "giftQty" : "allowedLossPct";
                UUID order = UUID.randomUUID(), item = UUID.randomUUID(), goods = UUID.randomUUID(), unit = UUID.randomUUID();
                UUID supplier = UUID.randomUUID(), currency = UUID.randomUUID(), settlement = UUID.randomUUID();
                jdbc.update("INSERT INTO suppliers VALUES (?, 'S1', '原供应商')", supplier);
                jdbc.update("INSERT INTO currencies VALUES (?, '美元')", currency);
                jdbc.update("INSERT INTO settlement_methods VALUES (?, '原结算方式')", settlement);
                jdbc.update("INSERT INTO goods VALUES (?, 'G1', '现有主档名称')", goods);
                jdbc.update("INSERT INTO units VALUES (?, '公斤')", unit);
                jdbc.update("INSERT INTO " + prefix + "_orders VALUES (?, ?, NULL, ?, ?, NULL, NULL, '原头备注')", order, supplier, currency, settlement);
                jdbc.update("INSERT INTO " + prefix + "_order_items(id,order_id,line_no,goods_id,unit_id,goods_code_snapshot,goods_name_snapshot,weight," + extraColumn + ",remark) VALUES (?, ?, 1, ?, ?, 'G1', '提交时货品', 1.2500, 2.50, '原行备注')", item, order, goods, unit);
                sources(jdbc, prefix, item);
                OrderSnapshot original = snapshot(type, order, item, goods, unit, supplier, currency, settlement, "10");
                ProcurementOrderApprovalPort port = mock(ProcurementOrderApprovalPort.class);
                when(port.orderType()).thenReturn(type);
                when(port.lockAndValidateFinanceSubmission(order)).thenReturn(original);
                ProcurementFinanceApprovalService service = new ProcurementFinanceApprovalService(
                        List.of(port), jdbc, mapper, mock(BusinessEventPublisher.class), eligibility,
                        mock(ProcurementApprovalProjectionQuery.class), user, mock(TxSessionVars.class),
                        mock(com.uten.imp.features.notice.ChainNoticeService.class),
                        mock(com.uten.imp.features.common.taskclaim.TaskClaimService.class),
                        mock(com.uten.imp.common.concurrency.ProcurementMutationLocks.class, RETURNS_DEEP_STUBS));
                service.submit(type, order);
                UUID first = jdbc.queryForObject("SELECT id FROM procurement_order_approval_cases WHERE order_id=? AND attempt=1", UUID.class, order);
                String originalJson = ProcurementApprovalSnapshot.json(original, mapper);
                JsonNode frozen = display(jdbc, first);
                assertThat(frozen.path("remark").asText()).isEqualTo("原头备注");
                assertThat(frozen.path("supplierName").asText()).isEqualTo("原供应商");
                assertThat(frozen.path("items").get(0).path("sources").size()).isEqualTo(2);
                assertThat(frozen.path("items").get(0).path("sourceDocNo").isNull()).isTrue();
                assertThat(new BigDecimal(frozen.path("items").get(0).path(extraKey).asText())).isEqualByComparingTo("2.50");
                assertThat(jdbc.queryForObject("SELECT snapshot_hash FROM procurement_order_approval_cases WHERE id=?", String.class, first)).isEqualTo(HashUtil.sha256(originalJson));

                jdbc.update("UPDATE procurement_order_approval_cases SET status='APPROVED' WHERE id=?", first);
                jdbc.update("UPDATE " + prefix + "_orders SET remark=NULL WHERE id=?", order);
                jdbc.update("UPDATE " + prefix + "_order_items SET weight=2.7500," + extraColumn + "=3.75,remark=NULL WHERE id=?", item);
                jdbc.update("UPDATE suppliers SET name='后来供应商名' WHERE id=?", supplier);
                jdbc.update("UPDATE " + prefix + "_order_item_sources SET alloc_qty=6 WHERE order_item_id=?", item);
                OrderSnapshot changed = snapshot(type, order, item, goods, unit, supplier, currency, settlement, "12");
                UUID second = new ProcurementApprovalReconfirmationService(mapper, jdbc, mock(BusinessEventPublisher.class), user)
                        .openReconfirmationCase(changed, 1);
                JsonNode current = display(jdbc, second);
                assertThat(display(jdbc, first)).isEqualTo(frozen);
                assertThat(current.path("remark").isNull()).isTrue();
                assertThat(current.path("items").get(0).path("remark").isNull()).isTrue();
                assertThat(current.path("items").get(0).path("weight").asText()).isEqualTo("2.7500");
                assertThat(new BigDecimal(current.path("items").get(0).path(extraKey).asText())).isEqualByComparingTo("3.75");
                assertThat(current.path("items").get(0).path("sources").get(0).path("quantity").asText()).isEqualTo("6");
                assertThat(jdbc.queryForObject("SELECT snapshot_hash FROM procurement_order_approval_cases WHERE id=?", String.class, second))
                        .isEqualTo(HashUtil.sha256(ProcurementApprovalSnapshot.json(changed, mapper)));

                List<ProcurementApprovalContracts.ReviewLine> previous = ReflectionTestUtils.invokeMethod(service, "loadReviewLines", type, second, true);
                List<ProcurementApprovalContracts.ReviewLine> latest = ReflectionTestUtils.invokeMethod(service, "loadReviewLines", type, second, false);
                assertThat(previous.getFirst().remark()).isEqualTo("原行备注");
                assertThat(previous.getFirst().weight()).isEqualByComparingTo("1.25");
                assertThat(latest.getFirst().remark()).isNull();
                assertThat(latest.getFirst().displaySnapshotComplete()).isTrue();
                assertThat(latest.getFirst().sourceApplicationNos()).contains("SRC-A", "SRC-B");
                var review = service.review(second);
                assertThat(review.sourceApplicationCount()).isEqualTo(2);
                assertThat(review.previousHeaderSnapshot().get("remark")).isEqualTo("原头备注");
                assertThat(review.headerSnapshot()).containsEntry("remark", null);
                assertThatThrownBy(() -> jdbc.update("UPDATE procurement_order_approval_cases SET display_snapshot='{}'::jsonb WHERE id=?", first))
                        .hasRootCauseInstanceOf(org.postgresql.util.PSQLException.class);
                assertThatThrownBy(() -> jdbc.update("INSERT INTO procurement_order_approval_cases(id,order_type,order_id,submission_snapshot) VALUES (?, ?, ?, '{}'::jsonb)", UUID.randomUUID(), type, order))
                        .hasRootCauseInstanceOf(org.postgresql.util.PSQLException.class);
                String wrongIdentity = ProcurementApprovalSnapshot.json(snapshot(type, order, UUID.randomUUID(), goods, unit, supplier, currency, settlement, "12"), mapper);
                assertThatThrownBy(() -> jdbc.update("INSERT INTO procurement_order_approval_cases(id,order_type,order_id,submission_snapshot) VALUES (?, ?, ?, CAST(? AS jsonb))", UUID.randomUUID(), type, order, wrongIdentity))
                        .hasRootCauseInstanceOf(org.postgresql.util.PSQLException.class);
                assertThat(jdbc.queryForObject("SELECT count(*) FROM procurement_order_approval_cases WHERE order_id=?", Integer.class, order)).isEqualTo(2);
            }
        }
    }

    private JsonNode display(JdbcTemplate jdbc, UUID id) throws Exception {
        return mapper.readTree(jdbc.queryForObject("SELECT display_snapshot::text FROM procurement_order_approval_cases WHERE id=?", String.class, id));
    }

    private static OrderSnapshot snapshot(String type, UUID order, UUID item, UUID goods, UUID unit,
            UUID supplier, UUID currency, UUID settlement, String qty) {
        BigDecimal amount = new BigDecimal(qty).multiply(new BigDecimal("2"));
        return new OrderSnapshot(type, order, "ORDER", LocalDate.of(2026, 9, 23), supplier, null, currency,
                BigDecimal.ONE, settlement, BigDecimal.ZERO, null, null, LocalDate.of(2026, 10, 1), amount, amount,
                List.of(new ItemSnapshot(item, 1, null, goods, null, unit, BigDecimal.ONE,
                        new BigDecimal(qty), new BigDecimal("2"), amount, amount, LocalDate.of(2026, 10, 1))));
    }

    private static void sources(JdbcTemplate jdbc, String prefix, UUID item) {
        String stem = prefix.equals("purchase") ? "request" : "application";
        for (String label : List.of("SRC-A", "SRC-B")) {
            UUID document = UUID.randomUUID(), source = UUID.randomUUID();
            jdbc.update("INSERT INTO " + prefix + "_" + stem + "s VALUES (?, ?)", document, label);
            jdbc.update("INSERT INTO " + prefix + "_" + stem + "_items VALUES (?, ?, 1)", source, document);
            jdbc.update("INSERT INTO " + prefix + "_order_item_sources VALUES (?, ?, 5, 1)", item, source);
        }
    }

    private static void schema(JdbcTemplate jdbc) {
        jdbc.execute("""
                CREATE TABLE procurement_order_approval_cases(id uuid PRIMARY KEY,order_type text,order_id uuid,
                  attempt int,bill_no_snapshot text,amount_snapshot numeric,submission_snapshot jsonb,snapshot_hash text,
                  submitted_by_user_id uuid,submitted_by_employee_id uuid,assignee_user_id uuid,assignee_employee_id uuid,
                  assignee_name_snapshot text,status text,version bigint,submitted_at timestamptz DEFAULT now());
                CREATE TABLE procurement_order_approval_events(id uuid,case_id uuid,event_type text,actor_user_id uuid,
                  actor_employee_id uuid,from_assignee_user_id uuid,to_assignee_user_id uuid,reason text,event_snapshot jsonb,created_at timestamptz DEFAULT now());
                CREATE TABLE procurement_order_qty_change_logs(order_type text,order_item_id uuid,old_qty numeric,new_qty numeric,changed_at timestamptz,changed_by_employee_id uuid,case_id uuid);
                CREATE TABLE ar_ap_ledger(supplier_id uuid,amount_balance numeric,direction text,is_deleted boolean,status int);
                CREATE TABLE suppliers(id uuid,code text,name text);
                CREATE TABLE warehouses(id uuid,name text);
                CREATE TABLE currencies(id uuid,name text);
                CREATE TABLE settlement_methods(id uuid,name text);
                CREATE TABLE employees(id uuid,full_name text);
                CREATE TABLE goods(id uuid,code text,name text);
                CREATE TABLE colors(id uuid,name text);
                CREATE TABLE units(id uuid,name text);
                """);
        for (String prefix : List.of("purchase", "subcontract")) {
            String source = prefix.equals("purchase") ? "request" : "application";
            jdbc.execute("CREATE TABLE " + prefix + "_orders(id uuid,supplier_id uuid,warehouse_id uuid,currency_id uuid,settlement_method_id uuid,purchaser_id uuid,maker_id uuid,remark text)");
            String extra = prefix.equals("purchase") ? "gift_qty numeric(18,4)" : "allowed_loss_pct numeric(5,2)";
            jdbc.execute("CREATE TABLE " + prefix + "_order_items(id uuid,order_id uuid,line_no int,goods_id uuid,color_id uuid,unit_id uuid,goods_code_snapshot text,goods_name_snapshot text,weight numeric(18,4)," + extra + ",remark text,source_doc_no text,is_deleted boolean DEFAULT FALSE)");
            jdbc.execute("CREATE TABLE " + prefix + "_order_item_sources(order_item_id uuid," + source + "_item_id uuid,alloc_qty numeric,line_no int)");
            jdbc.execute("CREATE TABLE " + prefix + "_" + source + "_items(id uuid," + source + "_id uuid,line_no int)");
            jdbc.execute("CREATE TABLE " + prefix + "_" + source + "s(id uuid,bill_no text)");
        }
    }
}
