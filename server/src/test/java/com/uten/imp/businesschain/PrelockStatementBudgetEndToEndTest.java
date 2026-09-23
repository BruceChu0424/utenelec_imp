package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueBatchRequest;
import com.uten.imp.features.stock.dto.StockDocItemLine;
import com.uten.imp.features.stock.dto.StockDocSaveRequest;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * 履约预锁「一轮发现 + 一次版本复核」(ADR-107)的语句预算。
 *
 * <p>两条最能说明问题的轻写入: 委外发料草稿改一行(只写 4 行却曾经要 1.2-5.6 秒)和
 * 领料任务中心批量出库。两处都只允许最外层跑一轮只读发现、锁后再跑一次行版本复核,
 * 不允许任何整行哈希快照(md5)语句, 会话变量每事务只绑一次。</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!",
        // 量的是生产配置: 关掉测试默认打开的嵌套足迹诊断(ADR-107)。
        "uten.concurrency.verify-nested-footprint=false"})
@Import(ProductionJdbcMeasurement.Configuration.class)
class PrelockStatementBudgetEndToEndTest {

    /** 委外发料草稿改一行的语句上限: 改前 69 条(其中整行哈希 28 条), ADR-107 实测 46 条, 取 +10%。 */
    static final int MATERIAL_ISSUE_UPDATE_BUDGET = 51;
    /** 三张领料单批量出库的语句上限: 改前 708 条(整行哈希 156 条), ADR-107 实测 544 条, 取 +10%。 */
    static final int ISSUE_BATCH_BUDGET = 598;

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired StockDocService stockDocs;
    @Autowired SubcontractMaterialIssueService issues;
    @Autowired org.springframework.transaction.PlatformTransactionManager transactionManager;
    FullChainEndToEndTest fixture;

    @BeforeEach
    void prepare() {
        fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
    }

    @AfterEach
    void logout() {
        ProductionJdbcMeasurement.end();
        SecurityContextHolder.clearContext();
    }

    @Test
    void draftSubcontractMaterialIssueEditRunsOneDiscoveryAndNoRowHashes() {
        var w = fixture.seedWorld("prelock-issue-put");
        fixture.loginAs(w.superAdminUserId());
        opening(w, "10");
        var submitted = fixture.submitLeafSubcontractForFinance(w, new BigDecimal("5"));
        fixture.loginAs(submitted.reviewerUserId());
        fixture.approvePendingFinance("SUBCONTRACT", submitted.orderId());
        fixture.loginAs(w.superAdminUserId());
        UUID item = db.queryForObject("select id from subcontract_order_items where order_id=?",
                UUID.class, submitted.orderId());
        UUID issue = db.queryForObject("""
                select header.id from subcontract_material_issues header
                join subcontract_material_issue_items line on line.issue_id=header.id
                where line.order_item_id=? and header.status=0 and not header.is_deleted
                """, UUID.class, item);
        var original = issues.detail(issue).getItems().getFirst();
        var command = new MaterialIssueSaveRequest();
        command.setBillDate(BusinessTime.today());
        command.setSupplierId(w.supplierId());
        command.setWarehouseId(w.warehouseId());
        var line = new MaterialIssueItemLine();
        line.setGoodsId(w.goodsE());
        line.setParentGoodsId(w.goodsE());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal("4"));
        line.setOrderItemId(item);
        line.setPlanItemId(original.getPlanItemId());
        command.setItems(List.of(line));

        var sample = ProductionJdbcMeasurement.begin();
        try {
            issues.update(issue, command);
        } finally {
            ProductionJdbcMeasurement.end();
        }

        assertEquals(1, sample.commits, "草稿保存必须是一笔事务");
        assertEquals(0, sample.md5Statements, "锁后复核只比行版本, 不再对整行做哈希");
        assertTrue(sample.setConfigStatements <= 1, "会话变量每事务只绑一次: " + sample.setConfigStatements);
        assertTrue(sample.logicalStatements <= MATERIAL_ISSUE_UPDATE_BUDGET,
                "委外发料草稿改一行用了 " + sample.logicalStatements + " 条语句, 超出预算 "
                        + MATERIAL_ISSUE_UPDATE_BUDGET);
        assertEquals(0, new BigDecimal("4").compareTo(issues.detail(issue).getItems().getFirst().getQty()));
    }

    @Test
    void productionDrawIssueBatchRunsOneDiscoveryAndNoRowHashes() throws Exception {
        var w = fixture.seedWorld("prelock-issue-batch");
        db.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsB(), new BigDecimal("60"));
        db.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsE(), new BigDecimal("30"));
        fixture.loginAs(w.superAdminUserId());
        var generate = FullChainEndToEndTest.class.getDeclaredMethod(
                "generateSingleWarehouseDraw", FullChainEndToEndTest.World.class, String.class);
        generate.setAccessible(true);
        List<UUID> draws = new ArrayList<>();
        for (int index = 0; index < 3; index++) {
            draws.add((UUID) generate.invoke(fixture, w, "prelock-batch-" + index + "-" + w.warehouseId()));
        }
        fixture.requestWorkshopDraws("prelock-batch", draws);
        var request = new StockDocIssueBatchRequest();
        request.setIdempotencyKey("prelock-batch-issue-" + w.warehouseId());
        request.setDocIds(List.copyOf(draws));

        var sample = ProductionJdbcMeasurement.begin();
        try {
            assertEquals(3, stockDocs.issueFullBatch(request).issuedCount());
        } finally {
            ProductionJdbcMeasurement.end();
        }

        assertEquals(1, sample.commits, "批量出库必须是一笔事务");
        assertEquals(0, sample.md5Statements, "锁后复核只比行版本, 不再对整行做哈希");
        assertTrue(sample.setConfigStatements <= 1, "会话变量每事务只绑一次: " + sample.setConfigStatements);
        assertTrue(sample.logicalStatements <= ISSUE_BATCH_BUDGET,
                "三张领料单批量出库用了 " + sample.logicalStatements + " 条语句, 超出预算 " + ISSUE_BATCH_BUDGET);
    }

    /**
     * 服务端截止时间(ADR-107 / overhaul-gap-01): 应用连接带锁等待、单条语句、事务内空闲上限,
     * 事务默认 40 秒(小于客户端 45 秒)。等锁超时回可重跑 409, 不再无限排队占住连接。
     */
    @Test
    void applicationConnectionsCarryServerSideDeadlines() throws Exception {
        assertEquals("10s", db.queryForObject("SHOW lock_timeout", String.class));
        assertEquals("1min", db.queryForObject("SHOW statement_timeout", String.class));
        assertEquals("2min", db.queryForObject("SHOW idle_in_transaction_session_timeout", String.class));
        assertEquals("off", db.queryForObject("SHOW jit", String.class));
        assertEquals(40, ((org.springframework.transaction.support.AbstractPlatformTransactionManager)
                transactionManager).getDefaultTimeout());

        UUID row = db.queryForObject("SELECT id FROM users ORDER BY created_at LIMIT 1", UUID.class);
        try (var holder = java.util.Objects.requireNonNull(db.getDataSource()).getConnection()) {
            holder.setAutoCommit(false);
            try (var lock = holder.prepareStatement("SELECT id FROM users WHERE id=? FOR UPDATE")) {
                lock.setObject(1, row);
                lock.executeQuery().close();
            }
            long started = System.nanoTime();
            var failure = org.junit.jupiter.api.Assertions.assertThrows(Exception.class, () ->
                    new org.springframework.transaction.support.TransactionTemplate(transactionManager)
                            .executeWithoutResult(status -> db.queryForList(
                                    "SELECT id FROM users WHERE id=? FOR UPDATE", row)));
            long waitedMillis = (System.nanoTime() - started) / 1_000_000L;
            holder.rollback();
            assertTrue(waitedMillis >= 9_000 && waitedMillis < 30_000, "Bounded lock wait: " + waitedMillis + " ms");
            var response = new com.uten.imp.common.web.GlobalExceptionHandler().handleOther(failure);
            assertEquals(409, response.getStatusCode().value());
            assertEquals("有人正在处理相关单据，本次操作未生效，请稍后再试", response.getBody().getMessage());
            assertEquals("1", response.getHeaders().getFirst("Retry-After"));
        }
    }

    /**
     * dup-backend-split-15 评审补充(全上下文): Spring Boot 自动配置的事务管理器挂着
     * {@code TransactionAuditActorBinder}; 一段故意不写 tx.bind() 的写事务, 数据库审计行照样记到
     * 当前登录人和本次请求号, 且整笔只发一次会话变量绑定。
     */
    @Test
    void writeWithoutTxBindStillRecordsTheSignedInActorAndRequest() {
        var manager = (org.springframework.transaction.support.AbstractPlatformTransactionManager) transactionManager;
        assertTrue(manager.getTransactionExecutionListeners().stream()
                .anyMatch(listener -> listener instanceof com.uten.imp.security.TransactionAuditActorBinder),
                "The auto-configured transaction manager must carry the audit actor binder");
        var w = fixture.seedWorld("audit-actor-auto-bind");
        fixture.loginAs(w.superAdminUserId());
        var request = new org.springframework.mock.web.MockHttpServletRequest("PUT", "/api/warehouses/audit-probe");
        request.setRemoteAddr("10.1.2.3");
        org.springframework.web.context.request.RequestContextHolder.setRequestAttributes(
                new org.springframework.web.context.request.ServletRequestAttributes(request));
        try {
            var sample = ProductionJdbcMeasurement.begin();
            try {
                new org.springframework.transaction.support.TransactionTemplate(transactionManager).executeWithoutResult(
                        status -> db.update("UPDATE warehouses SET name = name || '-审计' WHERE id=?", w.warehouseId()));
            } finally {
                ProductionJdbcMeasurement.end();
            }
            assertEquals(1, sample.setConfigStatements, "Bound exactly once at transaction begin");
            UUID requestId = com.uten.imp.audit.AuditRequestContext.ensureRequestId(request);
            var row = db.queryForMap("""
                    SELECT actor_id, request_id FROM audit_log
                    WHERE target_type='warehouses' AND target_id=? AND action='update'
                    ORDER BY id DESC LIMIT 1
                    """, w.warehouseId().toString());
            assertEquals(w.superAdminUserId(), row.get("actor_id"));
            assertEquals(requestId, row.get("request_id"));
        } finally {
            org.springframework.web.context.request.RequestContextHolder.resetRequestAttributes();
        }
    }

    private void opening(FullChainEndToEndTest.World w, String quantity) {
        var command = new StockDocSaveRequest();
        command.setDocType("OTHER_IN");
        command.setBillDate(BusinessTime.today());
        command.setWarehouseId(w.warehouseId());
        var line = new StockDocItemLine();
        line.setGoodsId(w.goodsE());
        line.setUnitId(w.unitId());
        line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(quantity));
        line.setAmountOriginal(new BigDecimal("100"));
        line.setAmountLocal(new BigDecimal("100"));
        line.setPrice(new BigDecimal("10"));
        command.setItems(List.of(line));
        stockDocs.approve(stockDocs.create(command).getId());
    }
}
