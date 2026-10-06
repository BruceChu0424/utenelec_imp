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
        "uten.features.goods-owner-scope-enabled=false",
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
    /** 2026-09-30 同夹具572→474条；去重复锁/详情后收紧到525，防止冗余工作回流。 */
    static final int ISSUE_BATCH_BUDGET = 525;

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
        // ADR-143: 委外件 E 发外的是它的直属物料(按件用量 1); 委外人员领 5 套, 仓库拣货时改少成 4。
        UUID material = fixture.ensureSubcontractDirectMaterial(w, w.goodsE());
        opening(w, material, "10");
        var submitted = fixture.submitLeafSubcontractForFinance(w, new BigDecimal("5"));
        fixture.loginAs(submitted.reviewerUserId());
        fixture.approvePendingFinance("SUBCONTRACT", submitted.orderId());
        fixture.loginAs(w.superAdminUserId());
        UUID item = db.queryForObject("select id from subcontract_order_items where order_id=?",
                UUID.class, submitted.orderId());
        UUID issue = fixture.submitSubcontractDraw(item, new BigDecimal("5"), "prelock-issue-draw-" + item).getFirst();
        var original = issues.detail(issue).getItems().getFirst();
        var command = new MaterialIssueSaveRequest();
        command.setBillDate(BusinessTime.today());
        command.setSupplierId(w.supplierId());
        command.setWarehouseId(w.warehouseId());
        var line = new MaterialIssueItemLine();
        line.setGoodsId(material);
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
     * ADR-149 §2.1: 非超管的仓储部门成员批量出库 5 张草稿领料单(出库即审核), 逐单复核的仓库任务办理范围
     * (审核、出库、详情可读)整批只解析一次 fn_user_warehouse_access。超管在判定前提前返回, 上面的预算量不出这一项。
     */
    @Test
    void warehouseMemberIssueBatchResolvesTheWarehouseScopeOnce() throws Exception {
        var w = fixture.seedWorld("scope-issue-batch");
        db.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsB(), new BigDecimal("100"));
        db.update("insert into stock_balances(warehouse_id, goods_id, color_id, qty) values (?,?,NULL,?)",
                w.warehouseId(), w.goodsE(), new BigDecimal("50"));
        fixture.loginAs(w.superAdminUserId());
        var generate = FullChainEndToEndTest.class.getDeclaredMethod(
                "generateSingleWarehouseDraw", FullChainEndToEndTest.World.class, String.class);
        generate.setAccessible(true);
        List<UUID> draws = new ArrayList<>();
        for (int index = 0; index < 5; index++) {
            draws.add((UUID) generate.invoke(fixture, w, "scope-batch-" + index + "-" + w.warehouseId()));
        }
        fixture.requestWorkshopDraws("scope-batch", draws);
        UUID member = fixture.createUserWithPerms(w, "scope-batch-" + w.warehouseId(),
                "stock_doc:view", "stock_doc:approve", "stock_doc:issue");
        db.update("UPDATE employees SET department_id=(SELECT id FROM departments WHERE code='SUB_WH' AND NOT is_deleted)"
                + " WHERE id=(SELECT employee_id FROM users WHERE id=?)", member);
        fixture.loginAs(member);
        var request = new StockDocIssueBatchRequest();
        request.setIdempotencyKey("scope-batch-issue-" + w.warehouseId());
        request.setDocIds(List.copyOf(draws));

        var sample = ProductionJdbcMeasurement.begin();
        try {
            assertEquals(5, stockDocs.issueFullBatch(request).issuedCount());
        } finally {
            ProductionJdbcMeasurement.end();
        }

        long resolutions = sample.labelsByFingerprint.entrySet().stream()
                .filter(label -> "warehouse.scope_access".equals(label.getValue()))
                .mapToLong(label -> sample.fingerprints.getOrDefault(label.getKey(), 0L))
                .sum();
        assertEquals(1, resolutions, "整批出库只解析一次仓库数据范围");
        assertEquals(1, sample.commits, "批量出库必须是一笔事务");
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
        assertTrue(((org.springframework.transaction.support.AbstractPlatformTransactionManager)
                transactionManager).getTransactionExecutionListeners().stream().anyMatch(
                com.uten.imp.application.concurrency.FulfillmentCommandDeadlineTransactions.class::isInstance),
                "完整应用的事务管理器必须接入命令截止时间监听器");
        assertTrue(beans.getBean(org.springframework.transaction.interceptor.TransactionInterceptor.class)
                .getTransactionAttributeSource() instanceof
                com.uten.imp.application.concurrency.FulfillmentDeadlineTransactionAttributeSource,
                "完整应用的声明式事务必须使用剩余命令时限");

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

    private void opening(FullChainEndToEndTest.World w, UUID goodsId, String quantity) {
        var command = new StockDocSaveRequest();
        command.setDocType("OTHER_IN");
        command.setBillDate(BusinessTime.today());
        command.setWarehouseId(w.warehouseId());
        var line = new StockDocItemLine();
        line.setGoodsId(goodsId);
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
