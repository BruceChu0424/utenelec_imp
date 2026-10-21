package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.GoodsBomService;
import com.uten.imp.features.master.goods.GoodsInlineEditService;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.history.MasterInlineEditService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.web.context.request.RequestContextHolder;
import org.springframework.web.context.request.ServletRequestAttributes;

import java.math.BigDecimal;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** The real inline services, transaction binder and database audit/history chain. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.MOCK, properties = {
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false",
        "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only"})
class MasterInlineEditRuntimeEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }

    @Autowired GoodsInlineEditService goodsInline;
    @Autowired MasterInlineEditService masterInline;
    @Autowired GoodsService goods;
    @Autowired GoodsBomService bom;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired PlatformTransactionManager transactions;
    UUID actor;

    @BeforeEach void login() {
        actor = db.queryForObject("SELECT id FROM users WHERE login_account=?", UUID.class,
                FullChainEndToEndTest.SHARED_ADMIN_LOGIN);
        UUID employee = db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, actor);
        var principal = new AuthUser(actor, employee, "inline-runtime-test", Set.of(
                "goods:view", "goods:edit", "goods:price:view", "goods:price:edit", "goods:discount:view",
                "color:view", "color:edit", "warehouse:view", "warehouse:edit", "warehouse:status"), false, true, false, false, null, UUID.randomUUID());
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(principal, "", principal.getAuthorities()));
    }

    @AfterEach void clear() {
        RequestContextHolder.resetRequestAttributes();
        SecurityContextHolder.clearContext();
    }

    @Test void goodsInlinePatchKeepsItsOwnHistoryAndAuditWithoutAnUnrelatedMasterRecord() {
        UUID id = goods();
        long version = db.queryForObject("SELECT version FROM goods WHERE id=?", Long.class, id);
        long goodsBefore = history("goods_operation_history"), masterBefore = history("master_operation_history");
        route("/api/master/inline-edit/goods/" + id, "PATCH");
        var saved = goodsInline.patch(id, Map.of("version", json.valueToTree(version)),
                Map.of("name", json.valueToTree("runtime goods changed")));
        assertEquals("runtime goods changed", saved.getName());
        assertEquals(0, new BigDecimal("1.2345").compareTo(
                db.queryForObject("SELECT price FROM goods WHERE id=?", BigDecimal.class, id)));
        assertEquals(goodsBefore + 1, history("goods_operation_history"));
        assertEquals(masterBefore, history("master_operation_history"));
        assertEquals("GOODS_EDIT", db.queryForObject(
                "SELECT operation_type FROM goods_operation_history WHERE actor_id=? ORDER BY created_at DESC LIMIT 1",
                String.class, actor));
        assertTrue(audits(id) > 0);
    }

    @Test void colorInlinePatchKeepsMandatoryMasterHistoryAndActorAudit() {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO colors(id,code,name,status) VALUES(?,?,?, '使用')",
                id, "RT-" + id, "runtime color original");
        long goodsBefore = history("goods_operation_history"), masterBefore = history("master_operation_history");
        route("/api/master/inline-edit/colors/" + id, "PATCH");
        masterInline.patch("colors", id, Map.of("name", "runtime color original"),
                Map.of("name", "runtime color changed"));
        assertEquals("runtime color changed", db.queryForObject("SELECT name FROM colors WHERE id=?", String.class, id));
        assertEquals(masterBefore + 1, history("master_operation_history"));
        assertEquals(goodsBefore, history("goods_operation_history"));
        assertTrue(audits(id) > 0);
    }

    @Test void openingGoodsAndBomReadsDoesNotCreateEitherWriteHistory() {
        UUID id = goods();
        long goodsBefore = history("goods_operation_history"), masterBefore = history("master_operation_history");
        route("/api/master/goods/" + id + "/bom", "GET");
        assertNotNull(goods.detail(id));
        assertTrue(bom.list(id).isEmpty());
        assertEquals(goodsBefore, history("goods_operation_history"));
        assertEquals(masterBefore, history("master_operation_history"));
    }

    @Test void warehouseInlinePatchPreservesOtherValuesAndCapturesHistoryWithoutOverwritingAStaleField() {
        UUID id = warehouse();
        long before = history("master_operation_history");
        route("/api/master/inline-edit/warehouses/" + id, "PATCH");
        masterInline.patch("warehouses", id, Map.of("name", "runtime warehouse " + id),
                Map.of("name", "runtime warehouse changed " + id));
        assertEquals("原位置", db.queryForObject("SELECT location FROM warehouses WHERE id=?", String.class, id));
        assertEquals("原备注", db.queryForObject("SELECT remark FROM warehouses WHERE id=?", String.class, id));
        assertEquals(rootWarehouse(), db.queryForObject("SELECT parent_id FROM warehouses WHERE id=?", UUID.class, id));
        assertEquals(before + 1, history("master_operation_history"));
        assertEquals("warehouses", db.queryForObject(
                "SELECT entity_type FROM master_operation_history WHERE actor_id=? ORDER BY created_at DESC LIMIT 1",
                String.class, actor));
        assertTrue(audits(id) > 0);
        ApiException stale = assertThrows(ApiException.class, () -> masterInline.patch("warehouses", id,
                Map.of("name", "runtime warehouse " + id), Map.of("name", "stale overwrite")));
        assertEquals(ErrorCode.CONFLICT, stale.getCode());
        assertEquals("runtime warehouse changed " + id,
                db.queryForObject("SELECT name FROM warehouses WHERE id=?", String.class, id));
        assertEquals(before + 1, history("master_operation_history"));
    }

    @Test void warehouseInlinePatchCannotDisableTheMainOrChangeALineSideWarehouse() {
        UUID root = rootWarehouse();
        route("/api/master/inline-edit/warehouses/" + root, "PATCH");
        ApiException main = assertThrows(ApiException.class, () -> masterInline.patch("warehouses", root,
                Map.of("status", "使用"), Map.of("status", "禁用")));
        assertTrue(main.getMessage().contains("主仓"));
        assertEquals("使用", db.queryForObject("SELECT status FROM warehouses WHERE id=?", String.class, root));
        ApiException mainUse = assertThrows(ApiException.class, () -> masterInline.patch("warehouses", root,
                Map.of("defective", false), Map.of("defective", true)));
        assertTrue(mainUse.getMessage().contains("主仓"));
        assertFalse(db.queryForObject("SELECT is_defective FROM warehouses WHERE id=?", Boolean.class, root));

        UUID bin = UUID.randomUUID(), workshop = UUID.randomUUID();
        UUID production = db.queryForObject("SELECT id FROM departments WHERE code='DEPT_PROD'", UUID.class);
        new TransactionTemplate(transactions).executeWithoutResult(status -> {
            db.update("INSERT INTO departments(id,code,name,parent_id,level) VALUES(?,?,?,?,'二级班组')",
                    workshop, "RT-WS-" + workshop, "runtime workshop " + workshop, production);
            db.update("""
                    INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable,is_line_side,workshop_department_id)
                    VALUES(?,?,?,?,'使用',true,true,?)
                    """, bin, "RT-BIN-" + bin, "runtime bin " + bin, root, workshop);
            db.update("INSERT INTO workshop_bins(workshop_department_id,bin_warehouse_id,opened_by) VALUES(?,?,?)",
                    workshop, bin, actor);
        });
        route("/api/master/inline-edit/warehouses/" + bin, "PATCH");
        ApiException lineSide = assertThrows(ApiException.class, () -> masterInline.patch("warehouses", bin,
                Map.of("name", "runtime bin " + bin), Map.of("name", "forbidden line side rename")));
        assertTrue(lineSide.getMessage().contains("只读"));
        assertEquals("runtime bin " + bin, db.queryForObject("SELECT name FROM warehouses WHERE id=?", String.class, bin));
    }

    @Test void warehouseInlineStatusChangesStillRequireStatusPermission() {
        UUID id = warehouse();
        UUID employee = db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, actor);
        var principal = new AuthUser(actor, employee, "inline-warehouse-editor",
                Set.of("warehouse:view", "warehouse:edit"), false, true, false, false, null, UUID.randomUUID());
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(principal, "", principal.getAuthorities()));
        route("/api/master/inline-edit/warehouses/" + id, "PATCH");
        ApiException denied = assertThrows(ApiException.class, () -> masterInline.patch("warehouses", id,
                Map.of("status", "使用"), Map.of("status", "禁用")));
        assertEquals(ErrorCode.FORBIDDEN, denied.getCode());
        assertTrue(denied.getMessage().contains("warehouse:status"));
        masterInline.patch("warehouses", id, Map.of("remark", "原备注"), Map.of("remark", "无状态权限仍可维护备注"));
        assertEquals("无状态权限仍可维护备注", db.queryForObject("SELECT remark FROM warehouses WHERE id=?", String.class, id));
        assertEquals("使用", db.queryForObject("SELECT status FROM warehouses WHERE id=?", String.class, id));
    }

    private UUID warehouse() {
        UUID id = UUID.randomUUID(), root = rootWarehouse();
        db.update("""
                INSERT INTO warehouses(id,code,name,parent_id,status,is_accountable,location,remark)
                VALUES(?,?,?,?,'使用',true,'原位置','原备注')
                """, id, "RT-WH-" + id, "runtime warehouse " + id, root);
        return id;
    }

    private UUID rootWarehouse() {
        var roots = db.queryForList("SELECT id FROM warehouses WHERE code='001' AND NOT is_deleted", UUID.class);
        if (!roots.isEmpty()) return roots.getFirst();
        UUID root = UUID.randomUUID();
        db.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,'001',?,'使用',false)",
                root, "runtime main warehouse " + root);
        return root;
    }

    private UUID goods() {
        UUID category = UUID.randomUUID(), id = UUID.randomUUID();
        db.update("INSERT INTO material_categories(id,code,name) VALUES(?,?,?)",
                category, "RC-" + category, "runtime category " + category);
        db.update("""
                INSERT INTO goods(id,code,name,category_id,code_sequence,status,source_type,price)
                VALUES(?,?,?,?,(SELECT coalesce(max(code_sequence),0)+1 FROM goods),'使用','采购',1.2345)
                """, id, "RG-" + id, "runtime goods original", category);
        return id;
    }

    private long history(String table) {
        return db.queryForObject("SELECT count(*) FROM " + table + " WHERE actor_id=?", Long.class, actor);
    }

    private long audits(UUID id) {
        return db.queryForObject("SELECT count(*) FROM audit_log WHERE actor_id=? AND target_id=?",
                Long.class, actor, id.toString());
    }

    private static void route(String path, String method) {
        RequestContextHolder.setRequestAttributes(new ServletRequestAttributes(new MockHttpServletRequest(method, path)));
    }
}
