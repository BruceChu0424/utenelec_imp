package com.uten.searchtest;

import com.uten.imp.features.finance.payables.*;
import com.uten.imp.features.master.client.ClientAccessService;
import com.uten.imp.features.sales.order.SalesOrderFinanceConfirmService;
import com.uten.imp.features.sales.quote.SalesQuoteFinanceService;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.responsibility.DataHandoverCandidateService;
import com.uten.imp.responsibility.EmployeeHandoverAuthorization;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.*;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Executes service-built rows/count/facet/amount SQL on real migrated column projections.
 * DTO enrichment and command mutations are intentionally outside this search-query oracle. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FinancialQueueSearchPostgresTest {
    private static final PostgreSQLContainer<?> PG = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final String[] TABLES = {"suppliers", "goods", "units", "currencies", "colors",
            "settlement_methods", "ar_ap_ledger", "subcontract_loss_cases", "v_subcontract_loss_case_value",
            "supplier_settlement_batches", "procurement_iqc_rejection_cases", "procurement_inspection_items",
            "sales_orders", "sales_order_items", "sales_order_qty_change_logs", "sales_order_revision_logs",
            "sales_quotes", "sales_quote_items", "sales_quote_revision_logs", "clients", "employees", "departments", "users"};
    private static NamedParameterJdbcTemplate db;
    private final List<Execution> executions = new ArrayList<>();
    private EntityManager em;
    private UUID supplier, currency, owner, otherOwner;

    @BeforeAll static void start() {
        PG.start();
        db = new NamedParameterJdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        MigratedProjectionSchema.createCurrentTables(db.getJdbcTemplate(), TABLES);
    }
    @AfterAll static void stop() { PG.stop(); }
    @BeforeEach void setup() {
        for (String table : TABLES) db.getJdbcTemplate().update("DELETE FROM " + table);
        executions.clear();
        em = sqlEntityManager();
        supplier = insert("suppliers", Map.of("code", "SUP_100%", "name", "钢材供应商"));
        currency = insert("currencies", Map.of("code", "CNY", "name", "人民币"));
        owner = UUID.randomUUID(); otherOwner = UUID.randomUUID();
    }

    @Test void iqcNamesLeadBeforePagingAndWordsCountsLiteralCharactersAndOwnerStayConsistent() {
        UUID exact = iqc("RC_100%", "螺丝", owner, "PENDING_RETURN", "PURCHASE", false, 2020);
        UUID prefix = iqc("RC-2", "螺丝加长", owner, "PENDING_RETURN", "PURCHASE", false, 2022);
        UUID contains = iqc("RC-3", "铁螺丝", owner, "RETURN_RECORDED", "PURCHASE", false, 2025);
        UUID codeOnly = iqc("螺丝", "普通零件", owner, "PENDING_RETURN", "PURCHASE", false, 2026);
        iqc("RC_100%", "螺丝", otherOwner, "PENDING_RETURN", "PURCHASE", false, 2026);
        iqc("RC_100%", "螺丝", owner, "PENDING_RETURN", "SUBCONTRACT", false, 2026);
        iqc("RC_100%", "螺丝", owner, "PENDING_RETURN", "PURCHASE", true, 2026);
        iqc("RCA100X", "螺丝", owner, "REVERSED", "PURCHASE", false, 2026);
        var service = service(ProcurementIqcRejectionService.class);
        ReflectionTestUtils.setField(service, "currentUser", user());
        // ADR-184: counts() 在 TaskAudiencePort 里复核真实动作权限后加 ACTIONABLE_* 桶；
        // 本测试只验证 SQL/分词契约，直通保留当前身份即可（全部 task 开关为 false）。
        ReflectionTestUtils.setField(service, "taskAudience",
                new com.uten.imp.application.port.TaskAudiencePort() {
                    @Override public <T> T read(java.util.function.Supplier<T> work) { return work.get(); }
                });
        var expected = List.of(exact, prefix, contains, codeOnly);
        for (int page = 1; page <= 4; page++) {
            executions.clear();
            assertThat(service.list("PURCHASE", "ACTIVE", "螺丝", page, 1).total()).isEqualTo(4);
            assertThat(ids()).containsExactly(expected.get(page - 1));
        }
        executions.clear();
        assertThat(service.list("PURCHASE", "ACTIVE", "螺丝\u3000RC_100%", 1, 20).total()).isEqualTo(1);
        assertThat(ids()).containsExactly(exact);
        assertThat(service.counts("PURCHASE", "螺丝 RC_100%").total()).isEqualTo(1);
        assertThat(service.list("PURCHASE", "ACTIVE", "螺丝 不存在", 1, 20).total()).isZero();
    }

    @Test void payablesReuseWordFilterForRowsCountAmountsAndFacetsWithinOriginalDimensions() {
        UUID exact = payable("AP", "SRC_100%", "PURCHASE", "AP", 2020, "10");
        UUID prefix = payable("AP-EXT", "SRC-2", "PURCHASE", "AP", 2022, "20");
        UUID contains = payable("XAPX", "SRC-3", "PURCHASE", "AP", 2026, "30");
        UUID exactSource = payable("OTHER", "AP", "PURCHASE", "AP", 2026, "40");
        payable("AP-hidden", "SRC-4", "DIRECT", "AP", 2026, "100");
        payable("AP-hidden-ar", "SRC-5", "PURCHASE", "AR", 2026, "200");
        var hold = mock(SupplierPayableHoldGuard.class);
        when(hold.holdInfos(anyList())).thenReturn(Map.of());
        var service = new ProcurementPayablesService(em, hold);
        var expected = List.of(exactSource, exact, prefix, contains);
        for (int page = 1; page <= 4; page++) {
            executions.clear();
            var result = service.list("PURCHASE", supplier, "OPEN", null, currency,
                    null, null, null, null, "AP", page, 1, "billDate", "desc", null);
            assertThat(result.total()).isEqualTo(4);
            assertThat(new BigDecimal(result.summary().payableLocal())).isEqualByComparingTo("100");
            assertThat(ids()).containsExactly(expected.get(page - 1));
        }
        executions.clear();
        assertThat(service.list("PURCHASE", supplier, "OPEN", null, currency,
                null, null, null, null, "钢材 SRC_100%", 1, 20, null, null, null).total()).isEqualTo(1);
        assertThat(ids()).containsExactly(exact);
        service.facets("PURCHASE", supplier, "OPEN", null, currency, null, null, null, null, "钢材 SRC_100%");
        assertThat(lastFacet().rows).hasSize(1);
        assertThat(lastFacet().rows.getFirst()[0]).isEqualTo("SRC_100%");
        assertThat(service.list("PURCHASE", supplier, "OPEN", null, currency,
                null, null, null, null, "钢材 不存在", 1, 20, null, null, null).total()).isZero();
    }

    @Test void lossClaimsKeepSupplierStatusAndExactHeaderFiltersWithLiteralWordsAndRankBeforeLimit() {
        UUID exact = loss("LOSS", "OPEN", supplier, false, 2020);
        UUID prefix = loss("LOSS-EXT", "OPEN", supplier, false, 2022);
        UUID contains = loss("XLOSSX", "OPEN", supplier, false, 2026);
        UUID literal = loss("LOSS_100%\\A", "OPEN", supplier, false, 2026);
        loss("LOSSA100X\\A", "CANCELED", supplier, false, 2026);
        loss("LOSS-hidden", "OPEN", supplier, true, 2026);
        var service = service(SubcontractLossClaimService.class);
        for (int page = 1; page <= 3; page++) {
            executions.clear();
            assertThat(service.list(supplier, "OPEN", "LOSS", page, 1).total()).isEqualTo(4);
            assertThat(ids()).containsExactly(List.of(exact, literal, prefix).get(page - 1));
        }
        executions.clear();
        assertThat(service.list(supplier, "OPEN", "钢材 LOSS_100%\\A", 1, 20).total()).isEqualTo(1);
        assertThat(ids()).containsExactly(literal);
        service.facets(supplier, "OPEN", "钢材 LOSS_100%\\A");
        assertThat(lastFacet().rows).hasSize(1);
        assertThat(service.list(supplier, "OPEN", "钢材 LOSS", 1, 20, null, null, "XLOSSX").total()).isEqualTo(1);
        assertThat(service.list(supplier, "CANCELED", "LOSS_100%\\A", 1, 20).total()).isZero();
    }

    @Test void settlementsKeepMonthSupplierAndStateWhileMatchingWordsAndLiteralWildcardsBeforePaging() {
        UUID exact = batch("BATCH", "FROZEN", 2020, supplier, false);
        UUID prefix = batch("BATCH-EXT", "FROZEN", 2022, supplier, false);
        batch("XBATCHX", "FROZEN", 2026, supplier, false);
        UUID literal = batch("BATCH_100%", "FROZEN", 2026, supplier, false);
        batch("BATCHA100X", "REVERSED", 2026, supplier, false);
        batch("BATCH-hidden", "FROZEN", 2026, supplier, true);
        var service = service(SupplierSettlementService.class);
        for (int page = 1; page <= 2; page++) {
            executions.clear();
            assertThat(service.list(supplier, null, "FROZEN", "BATCH", page, 1).total()).isEqualTo(4);
            assertThat(ids()).containsExactly(List.of(exact, literal).get(page - 1));
        }
        executions.clear();
        assertThat(service.list(supplier, LocalDate.of(2026, 1, 17), "FROZEN", "钢材 BATCH_100%", 1, 20).total()).isEqualTo(1);
        assertThat(ids()).containsExactly(literal);
        assertThat(service.list(supplier, LocalDate.of(2025, 1, 1), "FROZEN", "BATCH_100%", 1, 20).total()).isZero();
    }

    @Test void salesConfirmationSharesWordFilterAndRankWithCountAndFacetsWithoutChangingPool() {
        UUID client = insert("clients", Map.of("code", "C1", "name", "客户华东"));
        UUID exact = order("ORDER", client, 2020, false, false);
        UUID prefix = order("ORDER-EXT", client, 2022, false, false);
        order("XORDERX", client, 2026, false, false);
        UUID literal = order("ORDER_100%", client, 2026, false, false);
        order("ORDERA100X", client, 2026, false, false);
        order("ORDER-confirmed", client, 2026, true, false);
        order("ORDER-hidden", client, 2026, false, true);
        var service = service(SalesOrderFinanceConfirmService.class);
        for (int page = 1; page <= 2; page++) {
            executions.clear();
            assertThat(service.pending(page, 1, null, "ORDER").getTotal()).isEqualTo(5);
            assertThat(ids()).containsExactly(List.of(exact, prefix).get(page - 1));
        }
        executions.clear();
        assertThat(service.pending(1, 20, null, "华东 ORDER_100%").getTotal()).isEqualTo(1);
        assertThat(ids()).containsExactly(literal);
        service.pendingFacets(null, "华东 ORDER_100%", null);
        assertThat(lastFacet().rows).hasSize(1);
        assertThat(service.pending(1, 20, null, "华东 不存在").getTotal()).isZero();
        assertThat(service.pending(1, 20, null, "ORDER", null, null, null, null, true).getTotal()).isEqualTo(1);
    }

    @Test void quoteFinanceKeepsStateDeletedAndAllVisiblePeopleInOneAndSearchWithRankBeforePaging() {
        UUID client = insert("clients", Map.of("code", "C1", "name", "客户华东"));
        UUID seller = employee("SELLER", "张三", null, "active", false, true, false);
        UUID exact = quote("QUOTE", client, seller, 2020, 2, false);
        UUID prefix = quote("QUOTE-EXT", client, seller, 2022, 2, false);
        quote("XQUOTEX", client, seller, 2026, 2, false);
        UUID literal = quote("QUOTE_100%", client, seller, 2026, 2, false);
        quote("QUOTEA100X", client, seller, 2026, 1, false);
        quote("QUOTE-hidden", client, seller, 2026, 2, true);
        var service = service(SalesQuoteFinanceService.class);
        var claims = mock(TaskClaimService.class);
        when(claims.activeClaimViewsByTargetKey(anyString())).thenReturn(Map.of());
        ReflectionTestUtils.setField(service, "claimViews", claims);
        for (int page = 1; page <= 2; page++) {
            executions.clear();
            assertThat(service.list("pending", "QUOTE", page, 1).getTotal()).isEqualTo(4);
            assertThat(ids()).containsExactly(List.of(exact, prefix).get(page - 1));
        }
        executions.clear();
        assertThat(service.list("pending", "华东 张三 QUOTE_100%", 1, 20).getTotal()).isEqualTo(1);
        assertThat(ids()).containsExactly(literal);
        assertThat(service.list("pending", "华东 不存在", 1, 20).getTotal()).isZero();
    }

    @Test void clientAssignmentCandidatesRequireAllWordsRankNamesAndKeepAccountAndEmploymentEligibility() {
        UUID department = insert("departments", Map.of("code", "RD", "name", "研发部门", "path", "/RD/"));
        UUID exact = employee("Z", "张三", department, "active", false, true, false);
        employee("A", "张三助理", department, "active", false, true, false);
        employee("张三", "其他员工", department, "active", false, true, false);
        employee("OFF", "张三", department, "offboarded", false, true, false);
        employee("NOACCOUNT", "张三", department, "active", false, false, false);
        employee("DELETED", "张三", department, "active", true, true, false);
        UUID literal = employee("UT_100%\\A", "字面员工", department, "active", false, true, false);
        employee("UTA100X\\A", "通配近似", department, "active", false, true, false);
        var service = service(ClientAccessService.class);
        assertThat(service.candidates("张三", 1, 1).getTotal()).isEqualTo(3);
        assertThat(ids()).containsExactly(exact);
        executions.clear();
        assertThat(service.candidates("研发 张三 Z", 1, 20).getTotal()).isEqualTo(1);
        assertThat(ids()).containsExactly(exact);
        executions.clear();
        assertThat(service.candidates("UT_100%\\A", 1, 20).getTotal()).isEqualTo(1);
        assertThat(ids()).containsExactly(literal);
    }

    @Test void handoverCandidatesKeepManagerSubtreeProtectedAccountsAndDifferentSourceTargetRules() {
        UUID manager = UUID.randomUUID();
        UUID department = insert("departments", Map.of("code", "RD", "name", "研发", "path", "/RD/", "level", "一级部门", "manager_id", manager));
        UUID outside = insert("departments", Map.of("code", "FIN", "name", "财务", "path", "/FIN/"));
        UUID exact = employee("Z", "张三", department, "active", false, true, false);
        employee("张三", "其他员工", department, "active", false, true, false);
        employee("OUT", "张三", outside, "active", false, true, false);
        employee("SUPER", "张三", department, "active", false, true, true);
        employee("OFF", "张三离职", department, "offboarded", false, false, false);
        UUID literal = employee("UT_100%", "字面员工", department, "active", false, true, false);
        employee("UTA100X", "通配近似", department, "active", false, true, false);
        var authorization = mock(EmployeeHandoverAuthorization.class);
        when(authorization.candidateScope()).thenReturn(new EmployeeHandoverAuthorization.CandidateScope(false, manager));
        var service = new DataHandoverCandidateService(em, authorization);
        assertThat(service.search("target", "张三", 1, 1).total()).isEqualTo(2);
        assertThat(ids()).containsExactly(exact);
        assertThat(service.search("source", "张三", 1, 20).total()).isEqualTo(3);
        executions.clear();
        assertThat(service.search("target", "张三 Z", 1, 20).total()).isEqualTo(1);
        assertThat(ids()).containsExactly(exact);
        executions.clear();
        assertThat(service.search("target", "UT_100%", 1, 20).total()).isEqualTo(1);
        assertThat(ids()).containsExactly(literal);
    }

    private UUID iqc(String bill, String name, UUID actor, String status, String type, boolean deleted, int year) {
        UUID goods = insert("goods", Map.of("code", UUID.randomUUID().toString(), "name", name));
        UUID inspection = insert("procurement_inspection_items", Map.of("status", "FAILED"));
        return insert("procurement_iqc_rejection_cases", Map.of("receipt_bill_no", bill, "goods_id", goods,
                "supplier_id", supplier, "inspection_item_id", inspection, "owner_user_id", actor,
                "receipt_type", type, "status", status, "is_deleted", deleted, "created_at", at(year)));
    }
    private UUID payable(String bill, String source, String business, String direction, int year, String amount) {
        Map<String,Object> row = new LinkedHashMap<>();
        row.put("bill_no", bill); row.put("source_doc_no", source); row.put("supplier_id", supplier);
        row.put("currency_id", currency); row.put("business_type", business); row.put("direction", direction);
        row.put("status", 1); row.put("is_deleted", false); row.put("bill_date", LocalDate.of(year,1,1));
        row.put("amount_balance", new BigDecimal(amount)); row.put("amount_original_local", new BigDecimal(amount));
        row.put("open_item_kind", "PAYABLE"); row.put("due_date", LocalDate.of(2030,1,1));
        return insert("ar_ap_ledger", row);
    }
    private UUID loss(String bill, String status, UUID supplierId, boolean deleted, int year) {
        return insert("subcontract_loss_cases", Map.of("waste_bill_no", bill, "supplier_id", supplierId,
                "status", status, "is_deleted", deleted, "created_at", at(year)));
    }
    private UUID batch(String bill, String status, int year, UUID supplierId, boolean deleted) {
        return insert("supplier_settlement_batches", Map.of("batch_no", bill, "supplier_id", supplierId,
                "currency_id", currency, "period_start", LocalDate.of(year,1,1), "status", status, "is_deleted", deleted));
    }
    private UUID order(String bill, UUID client, int year, boolean confirmed, boolean stopped) {
        return insert("sales_orders", Map.of("bill_no", bill, "client_id", client, "bill_date", LocalDate.of(year,1,1),
                "finance_confirmed", confirmed, "is_stopped", stopped, "is_closed", false, "finance_rejected", false,
                "status", 1, "is_deleted", false));
    }
    private UUID quote(String bill, UUID client, UUID seller, int year, int status, boolean deleted) {
        return insert("sales_quotes", Map.of("bill_no", bill, "client_id", client, "seller_id", seller,
                "status", status, "is_deleted", deleted, "submitted_at", at(year)));
    }
    private UUID employee(String code, String name, UUID department, String status, boolean deleted, boolean account, boolean admin) {
        Map<String,Object> row = new LinkedHashMap<>(); row.put("code", code); row.put("full_name", name);
        row.put("department_id", department); row.put("status", status); row.put("is_deleted", deleted);
        UUID id = insert("employees", row);
        if (account) insert("users", Map.of("employee_id", id, "login_account", UUID.randomUUID().toString(), "status", "active", "is_deleted", false, "is_super_admin", admin));
        return id;
    }
    private UUID insert(String table, Map<String,?> fields) {
        Map<String,Object> row = new LinkedHashMap<>(fields); UUID id = UUID.randomUUID(); row.put("id", id);
        db.update("INSERT INTO " + table + "(" + String.join(",",row.keySet()) + ") VALUES ("
                + String.join(",",row.keySet().stream().map(key -> ":"+key).toList()) + ")", row);
        return id;
    }
    private static OffsetDateTime at(int year) { return OffsetDateTime.parse(year+"-01-01T00:00:00Z"); }
    private SecurityContextCurrentUser user() {
        var current = mock(SecurityContextCurrentUser.class);
        when(current.get()).thenReturn(Optional.of(new AuthUser(owner, null, "reviewer", Set.of("procurement_iqc_rejection:view"), false, true, false)));
        when(current.requireId()).thenReturn(owner); return current;
    }
    private <T> T service(Class<T> type) {
        T service = mock(type, CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service,"em",em); return service;
    }
    private List<UUID> ids() {
        return executions.stream().filter(execution -> execution.sql.contains("ORDER BY") && !execution.sql.contains("GROUP BY"))
                .findFirst().orElseThrow().rows.stream().map(row -> (UUID)row[0]).toList();
    }
    private Execution lastFacet() { return executions.stream().filter(row -> row.sql.contains("GROUP BY")).reduce((a,b)->b).orElseThrow(); }
    private record Execution(String sql, List<Object[]> rows) {}
    private EntityManager sqlEntityManager() {
        EntityManager result = mock(EntityManager.class);
        when(result.createNativeQuery(anyString())).thenAnswer(call -> {
            String sql = call.getArgument(0); Map<String,Object> params = new LinkedHashMap<>();
            int[] bounds = {0, Integer.MAX_VALUE};
            Query query = mock(Query.class, RETURNS_SELF);
            when(query.setParameter(anyString(), any())).thenAnswer(bind -> { params.put(bind.getArgument(0),bind.getArgument(1)); return query; });
            when(query.setFirstResult(anyInt())).thenAnswer(bound -> { bounds[0]=bound.getArgument(0); return query; });
            when(query.setMaxResults(anyInt())).thenAnswer(bound -> { bounds[1]=bound.getArgument(0); return query; });
            when(query.getResultList()).thenAnswer(ignored -> {
                String statement = sql;
                if (!sql.toLowerCase(Locale.ROOT).contains("limit :") && bounds[1] != Integer.MAX_VALUE) statement += " LIMIT " + bounds[1] + " OFFSET " + bounds[0];
                List<Object[]> rows = db.query(statement, params, (rs,index) -> array(rs));
                executions.add(new Execution(statement, rows));
                return List.of(); // Isolate the query contract from unrelated row enrichment.
            });
            when(query.getSingleResult()).thenAnswer(ignored -> {
                List<Object[]> rows = db.query(sql,params,(rs,index)->array(rs));
                executions.add(new Execution(sql,rows));
                Object[] row=rows.getFirst(); return row.length==1 ? row[0] : row;
            });
            return query;
        });
        return result;
    }
    private static Object[] array(ResultSet rs) throws SQLException {
        Object[] row = new Object[rs.getMetaData().getColumnCount()];
        for (int index=0;index<row.length;index++) row[index]=rs.getObject(index+1);
        return row;
    }
}
