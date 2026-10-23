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
    @Autowired com.uten.imp.common.mastercode.CategoryDrivenCodeService categoryCodes;
    @Autowired com.uten.imp.features.master.history.MasterRecordHistoryService sharedHistory;
    @Autowired com.uten.imp.features.master.color.ColorService colors;
    @Autowired com.uten.imp.security.TxSessionVars sessionVars;
    @Autowired com.uten.imp.features.master.lifecycle.MasterLifecycleService lifecycle;
    @Autowired com.uten.imp.features.master.unit.UnitService units;
    UUID actor;

    @BeforeEach void login() {
        actor = db.queryForObject("SELECT id FROM users WHERE login_account=?", UUID.class,
                FullChainEndToEndTest.SHARED_ADMIN_LOGIN);
        UUID employee = db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, actor);
        var principal = new AuthUser(actor, employee, "inline-runtime-test", Set.of(
                "goods:view", "goods:edit", "goods:price:view", "goods:price:edit", "goods:discount:view",
                "color:view", "color:edit", "color:delete", "unit:view", "unit:edit", "warehouse:view", "warehouse:edit", "warehouse:status"), false, true, false, false, null, UUID.randomUUID());
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

    @Test void fullGoodsFormsCannotChangeOrClearSubcontractLossWithoutCostAuthority() throws Exception {
        UUID id = goods();
        db.update("UPDATE goods SET subcontract_allowed_loss_pct=15 WHERE id=?", id);
        loginForSubcontractLoss(false);
        long version = db.queryForObject("SELECT version FROM goods WHERE id=?", Long.class, id);
        long versions = db.queryForObject("SELECT count(*) FROM master_record_versions WHERE source_table='goods' AND row_id=?", Long.class, id);
        long operations = history("goods_operation_history");
        route("/api/master/goods/" + id, "PUT");
        for (String value : new String[]{"25", "null"}) {
            var request = lossRequest(id, "forbidden rename", ",\"subcontractAllowedLossPct\":" + value);
            assertTrue(request.hasSubcontractAllowedLossPct());
            ApiException denied = assertThrows(ApiException.class, () -> goods.update(id, request));
            assertEquals(ErrorCode.FORBIDDEN, denied.getCode());
            assertEquals("runtime goods original", db.queryForObject("SELECT name FROM goods WHERE id=?", String.class, id));
            assertEquals(0, new BigDecimal("15").compareTo(db.queryForObject("SELECT subcontract_allowed_loss_pct FROM goods WHERE id=?", BigDecimal.class, id)));
            assertEquals(version, db.queryForObject("SELECT version FROM goods WHERE id=?", Long.class, id));
            assertEquals(versions, db.queryForObject("SELECT count(*) FROM master_record_versions WHERE source_table='goods' AND row_id=?", Long.class, id));
            assertEquals(operations, history("goods_operation_history"));
        }
        route("/api/master/goods", "POST");
        var create = lossRequest(id, "forbidden create " + id, ",\"subcontractAllowedLossPct\":12");
        create.setCode("LOSS-DENIED-" + id);
        ApiException denied = assertThrows(ApiException.class, () -> goods.create(create));
        assertEquals(ErrorCode.FORBIDDEN, denied.getCode());
        assertEquals(0, db.queryForObject("SELECT count(*) FROM goods WHERE name=?", Integer.class, create.getName()));
        assertEquals(0, db.queryForObject("SELECT count(*) FROM business_identifier_reservations WHERE normalized_identifier=?", Integer.class, create.getCode()));
    }

    @Test void fullGoodsFormsMayOmitOrEchoReadableLossWhileEditingOtherFields() throws Exception {
        UUID id = goods();
        db.update("UPDATE goods SET subcontract_allowed_loss_pct=15 WHERE id=?", id);
        loginForSubcontractLoss(false);
        route("/api/master/goods/" + id, "PUT");
        var omitted = lossRequest(id, "omitted policy rename", "");
        assertFalse(omitted.hasSubcontractAllowedLossPct());
        goods.update(id, omitted);
        var echoed = lossRequest(id, "echoed policy rename", ",\"subcontractAllowedLossPct\":15.0000");
        assertTrue(echoed.hasSubcontractAllowedLossPct());
        goods.update(id, echoed);
        assertEquals("echoed policy rename", db.queryForObject("SELECT name FROM goods WHERE id=?", String.class, id));
        assertEquals(0, new BigDecimal("15").compareTo(db.queryForObject("SELECT subcontract_allowed_loss_pct FROM goods WHERE id=?", BigDecimal.class, id)));
        assertEquals(0, new BigDecimal("15").compareTo(goods.detail(id).getSubcontractAllowedLossPct()));
        assertEquals(0, new BigDecimal("1.2345").compareTo(db.queryForObject("SELECT price FROM goods WHERE id=?", BigDecimal.class, id)));
    }

    @Test void costAuthorizedFullGoodsFormsCanCreateChangeAndClearSubcontractLoss() throws Exception {
        UUID source = goods();
        loginForSubcontractLoss(true);
        route("/api/master/goods", "POST");
        var create = lossRequest(source, "authorized loss create " + source, ",\"subcontractAllowedLossPct\":12");
        create.setCode("LOSS-AUTH-" + source);
        UUID id = goods.create(create).getId();
        assertEquals(0, new BigDecimal("12").compareTo(db.queryForObject("SELECT subcontract_allowed_loss_pct FROM goods WHERE id=?", BigDecimal.class, id)));
        route("/api/master/goods/" + id, "PUT");
        goods.update(id, lossRequest(id, "authorized loss changed", ",\"subcontractAllowedLossPct\":25"));
        assertEquals(0, new BigDecimal("25").compareTo(db.queryForObject("SELECT subcontract_allowed_loss_pct FROM goods WHERE id=?", BigDecimal.class, id)));
        goods.update(id, lossRequest(id, "authorized loss cleared", ",\"subcontractAllowedLossPct\":null"));
        assertNull(db.queryForObject("SELECT subcontract_allowed_loss_pct FROM goods WHERE id=?", BigDecimal.class, id));
        assertEquals("authorized loss cleared", db.queryForObject("SELECT name FROM goods WHERE id=?", String.class, id));
    }

    private com.uten.imp.features.master.goods.dto.GoodsSaveRequest lossRequest(UUID id, String name, String policyJson) throws Exception {
        UUID category = db.queryForObject("SELECT category_id FROM goods WHERE id=?", UUID.class, id);
        return json.readValue("{\"categoryId\":\"" + category + "\",\"name\":\"" + name
                + "\",\"status\":\"使用\",\"sourceType\":\"采购\"" + policyJson + "}",
                com.uten.imp.features.master.goods.dto.GoodsSaveRequest.class);
    }

    private void loginForSubcontractLoss(boolean canViewCosts) {
        UUID employee = db.queryForObject("SELECT employee_id FROM users WHERE id=?", UUID.class, actor);
        var permissions = new java.util.HashSet<>(Set.of("goods:view", "goods:edit", "goods:create"));
        if (canViewCosts) permissions.add("goods:cost:view");
        var principal = new AuthUser(actor, employee, "loss-runtime-test", permissions,
                false, true, false, false, null, UUID.randomUUID());
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(principal, "", principal.getAuthorities()));
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

    @Test void concurrentAutomaticAndManualGoodsCodesShareTheSameSerializedLifetimeRegistry() throws Exception {
        UUID category = UUID.randomUUID();
        String prefix = ("N" + category.toString().replace("-", "").substring(0, 7)).toUpperCase(java.util.Locale.ROOT);
        new TransactionTemplate(transactions).executeWithoutResult(status -> {
            db.update("INSERT INTO material_categories(id,code,name,code_prefix) VALUES(?,?,?,?)",
                    category, "AUTO-CATEGORY-" + category, "并发编号回归", prefix);
            db.update("UPDATE category_master_code_sequences SET last_seq=greatest(last_seq,(SELECT coalesce(max(code_sequence),0) FROM goods)) WHERE master_type='GOODS'");
        });
        assertEquals(prefix + "02", allocateAndInsertGoods(category, prefix + "02"));
        var gate = new java.util.concurrent.CountDownLatch(1);
        var pool = java.util.concurrent.Executors.newFixedThreadPool(6);
        try {
            var automatic = new java.util.ArrayList<java.util.concurrent.Future<String>>();
            for (int i = 0; i < 9; i++) automatic.add(pool.submit(() -> {
                gate.await();
                return allocateAndInsertGoods(category, null);
            }));
            var manual = pool.submit(() -> {
                gate.await();
                try { return allocateAndInsertGoods(category, prefix + "10"); }
                catch (ApiException conflict) {
                    assertEquals(ErrorCode.CONFLICT, conflict.getCode());
                    return null;
                }
            });
            gate.countDown();
            var codes = new java.util.HashSet<String>();
            for (var task : automatic) assertTrue(codes.add(task.get(90, java.util.concurrent.TimeUnit.SECONDS)));
            assertFalse(codes.contains(prefix + "02"));
            String manualCode = manual.get(90, java.util.concurrent.TimeUnit.SECONDS);
            if (manualCode != null) assertFalse(codes.contains(manualCode));
            int expected = 10 + (manualCode == null ? 0 : 1);
            assertEquals(expected, db.queryForObject("SELECT count(*) FROM goods WHERE category_id=?", Integer.class, category));
            assertEquals(expected, db.queryForObject("SELECT count(*) FROM business_identifier_reservation_members member JOIN goods g ON g.id=member.entity_id WHERE member.owner_domain='GOODS' AND g.category_id=?", Integer.class, category));
        } finally { pool.shutdownNow(); }
    }

    private String allocateAndInsertGoods(UUID category, String requestedCode) {
        return new TransactionTemplate(transactions).execute(status -> {
            var allocation = categoryCodes.allocate(com.uten.imp.common.mastercode.CategoryDrivenCodeService.MasterType.GOODS,
                    category, requestedCode);
            db.update("INSERT INTO goods(id,category_id,code,name,code_sequence,code_prefix_category_id,code_managed,status,source_type) VALUES(?,?,?,?,?,?,?,'使用','采购')",
                    UUID.randomUUID(), category, allocation.code(), "并发编号货品", allocation.sequence(),
                    allocation.prefixCategoryId(), allocation.managed());
            return allocation.code();
        });
    }

    @Test void sharedColorVersionRestoresItsOldCodeThroughCurrentPolicyAndRejectsAStaleHead() {
        UUID id = UUID.randomUUID();
        String oldCode = "COLOR-OLD-" + id, nextCode = "COLOR-NEW-" + id;
        new TransactionTemplate(transactions).executeWithoutResult(status -> db.update(
                "INSERT INTO colors(id,code,name,status) VALUES(?,?,?,'使用')", id, oldCode, "颜色编号恢复"));
        route("/api/master/colors/" + id, "PUT");
        var request = new com.uten.imp.features.master.color.dto.ColorSaveRequest();
        request.setName("颜色编号恢复");request.setCode(nextCode);request.setStatus("使用");
        colors.update(id, request);
        long version = db.queryForObject("SELECT max(id) FROM master_record_versions WHERE source_table='colors' AND row_id=?", Long.class, id);
        route("/api/master/colors/" + id, "DELETE");
        lifecycle.delete(com.uten.imp.features.master.lifecycle.MasterEntityKind.COLOR, id);
        var selected = sharedHistory.detail("colors", version);
        assertTrue(selected.canRestoreBefore(), selected.blockedReason());
        route("/api/master/record-history/" + version + "/restore", "POST");
        sharedHistory.restore("colors", version, selected.expectedHead(), true);
        assertEquals(oldCode.toUpperCase(java.util.Locale.ROOT), db.queryForObject("SELECT code FROM colors WHERE id=?", String.class, id));
        assertFalse(db.queryForObject("SELECT is_deleted FROM colors WHERE id=?", Boolean.class, id));
        assertEquals(2, db.queryForObject("SELECT count(*) FROM business_identifier_reservation_members WHERE owner_domain='COLOR' AND entity_id=?", Integer.class, id));
        assertThrows(ApiException.class, () -> sharedHistory.restore("colors", version, selected.expectedHead(), true));
    }

    @Test void sharedGoodsVersionRestoresDisplayCodeWithoutRollingBackItsCurrentSequence() throws Exception {
        UUID id = goods();
        var before = json.readTree(db.queryForObject("SELECT to_jsonb(g)::text FROM goods g WHERE id=?", String.class, id));
        String oldCode = before.path("code").asText();
        UUID category = UUID.fromString(before.path("category_id").asText());
        route("/api/master/goods/" + id, "PUT");
        var allocated = new TransactionTemplate(transactions).execute(status -> {
            sessionVars.bind();
            long suffix = db.queryForObject("SELECT greatest(last_seq,(SELECT coalesce(max(code_sequence),0) FROM goods))+100 FROM category_master_code_sequences WHERE master_type='GOODS'", Long.class);
            String code = "HP" + String.format("%06d", suffix);
            var next = categoryCodes.allocateForUpdate(com.uten.imp.common.mastercode.CategoryDrivenCodeService.MasterType.GOODS,
                    id, category, code, new com.uten.imp.common.mastercode.CategoryCodeAllocation(oldCode,
                            before.path("code_sequence").asLong(), null, before.path("code_managed").asBoolean()));
            db.update("UPDATE goods SET code=?,code_sequence=?,code_managed=?,code_prefix_category_id=?,version=version+1 WHERE id=?",
                    next.code(), next.sequence(), next.managed(), next.prefixCategoryId(), id);
            return next;
        });
        long version = db.queryForObject("SELECT max(id) FROM master_record_versions WHERE source_table='goods' AND row_id=?", Long.class, id);
        var selected = sharedHistory.detail("goods", version);
        assertTrue(selected.canRestoreBefore(), selected.blockedReason());
        route("/api/master/record-history/" + version + "/restore", "POST");
        sharedHistory.restore("goods", version, selected.expectedHead(), true);
        assertEquals(oldCode.toUpperCase(java.util.Locale.ROOT), db.queryForObject("SELECT code FROM goods WHERE id=?", String.class, id));
        assertEquals(allocated.sequence(), db.queryForObject("SELECT code_sequence FROM goods WHERE id=?", Long.class, id));
        assertFalse(db.queryForObject("SELECT code_managed FROM goods WHERE id=?", Boolean.class, id));
        assertEquals(2, db.queryForObject("SELECT count(*) FROM business_identifier_reservation_members WHERE owner_domain='GOODS' AND entity_id=?", Integer.class, id));
    }

    @Test void ordinaryUnitJsonRenameAndCodeEditPreserveTheUnspecifiedMassProfile() throws Exception {
        UUID id = UUID.randomUUID();
        String oldCode = "UNIT-OLD-" + id, nextCode = "UNIT-NEW-" + id;
        new TransactionTemplate(transactions).executeWithoutResult(status -> {
            db.update("INSERT INTO units(id,code,name,status) VALUES(?,?,?,'使用')", id, oldCode, "旧单位名称");
            db.update("INSERT INTO unit_measurement_profiles(unit_id,measurement_dimension,mass_unit_code,provenance) VALUES(?,'MASS','KG','MANUAL_GOVERNANCE')", id);
        });
        var request = json.readValue("{\"name\":\"新单位名称\",\"code\":\"" + nextCode + "\",\"status\":\"使用\"}",
                com.uten.imp.features.master.unit.dto.UnitSaveRequest.class);
        route("/api/master/units/" + id, "PUT");
        units.update(id, request);
        assertEquals("新单位名称", db.queryForObject("SELECT name FROM units WHERE id=?", String.class, id));
        assertEquals(nextCode, db.queryForObject("SELECT code FROM units WHERE id=?", String.class, id));
        assertEquals("MASS/KG", db.queryForObject("SELECT measurement_dimension||'/'||mass_unit_code FROM unit_measurement_profiles WHERE unit_id=?", String.class, id));
    }

    @Test void warehouseInlineCodeChangeKeepsIdentityAndRejectsLifetimeCrossDomainDuplicates() {
        UUID id = warehouse();
        String oldCode = db.queryForObject("SELECT code FROM warehouses WHERE id=?", String.class, id);
        String nextCode = ("WH-MANUAL-" + UUID.randomUUID()).toUpperCase(java.util.Locale.ROOT);
        route("/api/master/inline-edit/warehouses/" + id, "PATCH");
        masterInline.patch("warehouses", id, Map.of("code", oldCode), Map.of("code", nextCode));
        assertEquals(nextCode, db.queryForObject("SELECT code FROM warehouses WHERE id=?", String.class, id));
        assertEquals(rootWarehouse(), db.queryForObject("SELECT parent_id FROM warehouses WHERE id=?", UUID.class, id));
        assertEquals(id, db.queryForObject("SELECT entity_id FROM business_identifier_reservation_members WHERE normalized_identifier=? AND owner_domain='WAREHOUSE'", UUID.class, oldCode.toUpperCase()));
        String occupied = "COLOR-RESERVED-" + UUID.randomUUID();
        new TransactionTemplate(transactions).executeWithoutResult(status -> db.update(
                "INSERT INTO colors(id,code,name,status) VALUES(?,?,?,'使用')", UUID.randomUUID(), occupied, occupied));
        ApiException conflict = assertThrows(ApiException.class, () -> masterInline.patch("warehouses", id,
                Map.of("code", nextCode), Map.of("code", occupied.toLowerCase())));
        assertEquals(ErrorCode.CONFLICT, conflict.getCode());
        assertEquals(nextCode, db.queryForObject("SELECT code FROM warehouses WHERE id=?", String.class, id));
        long version = db.queryForObject("SELECT max(id) FROM master_record_versions WHERE source_table='warehouses' AND row_id=?", Long.class, id);
        var selected = sharedHistory.detail("warehouses", version);
        assertTrue(selected.canRestoreBefore(), selected.blockedReason());
        route("/api/master/record-history/" + version + "/restore", "POST");
        sharedHistory.restore("warehouses", version, selected.expectedHead(), true);
        assertEquals(oldCode.toUpperCase(java.util.Locale.ROOT), db.queryForObject("SELECT code FROM warehouses WHERE id=?", String.class, id));
    }

    @Test void warehouseInlinePatchCannotDisableTheMainOrChangeALineSideWarehouse() {
        UUID root = rootWarehouse();
        route("/api/master/inline-edit/warehouses/" + root, "PATCH");
        String rootCode = db.queryForObject("SELECT code FROM warehouses WHERE id=?", String.class, root);
        assertThrows(ApiException.class, () -> masterInline.patch("warehouses", root,
                Map.of("code", rootCode), Map.of("code", "MAIN-CHANGED")));
        assertEquals(rootCode, db.queryForObject("SELECT code FROM warehouses WHERE id=?", String.class, root));
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
