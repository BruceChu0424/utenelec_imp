package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.GoodsBomWhereUsedReplacementService;
import com.uten.imp.features.production.report.WhereUsedExportService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.access.AccessDeniedException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;

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
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class GoodsBomWhereUsedReplacementEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired GoodsBomWhereUsedReplacementService service;
    @Autowired WhereUsedExportService exports;
    final List<UUID> created = new ArrayList<>();
    final List<UUID> createdUnits = new ArrayList<>();
    UUID unit;
    AuthUser admin;
    UUID session;

    @BeforeEach void before() {
        FullChainEndToEndTest fixture = new FullChainEndToEndTest();
        beans.autowireBean(fixture);
        fixture.loginAs(db.queryForObject("SELECT id FROM users WHERE login_account='full-chain-bootstrap-admin-test'", UUID.class));
        admin = (AuthUser) SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        session = UUID.randomUUID();
        login(Set.of("production_where_used:view", "goods:bom:edit", "goods:view", "goods:price:view", "production_where_used:export"), session, null);
        unit = unit();
    }

    @AfterEach void after() {
        SecurityContextHolder.clearContext();
        for (UUID id : created) db.update("DELETE FROM goods_bom_items WHERE goods_id=? OR component_goods_id=?", id, id);
        for (UUID id : created) db.update("DELETE FROM goods WHERE id=?", id);
        for (UUID id : createdUnits) db.update("DELETE FROM units WHERE id=?", id);
    }

    @Test void nestedReplacementPreviewsAllSharedParentsRollsBackThenCommitsCanonicalEdgeOnce() {
        UUID root = goods("root"), other = goods("other"), sub = goods("sub"), old = goods("old"), replacement = goods("new");
        edge(root, sub); edge(other, sub); UUID original = edge(sub, old);
        var preview = service.preview(request(old, replacement, root));
        assertEquals(Set.of(root, other, sub), preview.affectedProducts().stream().map(GoodsBomWhereUsedReplacementService.Product::id).collect(java.util.stream.Collectors.toSet()));
        assertEquals(1, preview.edges().size());
        assertEquals(old, component(original), "preview must leave live BOM untouched");
        var result = service.commit(new GoodsBomWhereUsedReplacementService.Commit(preview.previewToken()));
        assertEquals(1, result.replacedEdges()); assertEquals(3, result.affectedProducts());
        assertEquals(replacement, component(original));
        assertEquals(new BigDecimal("2.50000"), db.queryForObject("SELECT qty FROM goods_bom_items WHERE id=?", BigDecimal.class, original));
        assertEquals("keep original", db.queryForObject("SELECT summary FROM goods_bom_items WHERE id=?", String.class, original));
        assertEquals(result, service.commit(new GoodsBomWhereUsedReplacementService.Commit(preview.previewToken())), "lost response retry is idempotent");
    }

    @Test void changedLiveEdgeRejectsStaleConfirmationAndLeavesAllParentsUnchanged() {
        UUID a = goods("a"), b = goods("b"), old = goods("old"), replacement = goods("new");
        UUID first = edge(a, old), second = edge(b, old);
        var preview = service.preview(new GoodsBomWhereUsedReplacementService.Request(old, replacement, List.of(a, b)));
        db.update("UPDATE goods_bom_items SET qty=9 WHERE id=?", second);
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class,
                () -> service.commit(new GoodsBomWhereUsedReplacementService.Commit(preview.previewToken()))).getCode());
        assertEquals(old, component(first)); assertEquals(old, component(second));
    }

    @Test void duplicateOrCycleInOneParentRollsBackEntireSimulation() {
        UUID a = goods("a"), b = goods("b"), old = goods("old"), replacement = goods("new");
        UUID first = edge(a, old), second = edge(b, old);
        edge(b, replacement);
        assertThrows(ApiException.class, () -> service.preview(new GoodsBomWhereUsedReplacementService.Request(old, replacement, List.of(a, b))));
        assertEquals(old, component(first)); assertEquals(old, component(second));
        UUID loopRoot = goods("loopRoot"), loopReplacement = goods("loopReplacement"), loopEdge = edge(loopRoot, old);
        edge(loopReplacement, loopRoot);
        assertThrows(ApiException.class, () -> service.preview(request(old, loopReplacement, loopRoot)));
        assertEquals(old, component(loopEdge));
    }

    @Test void historyOnlySelectionAndQuantityBasisChangeCannotBeSilentlyRewritten() {
        UUID a = goods("a"), historical = goods("historical"), old = goods("old"), replacement = goods("new");
        UUID current = edge(a, old), archived = edge(historical, old);
        db.update("UPDATE goods_bom_items SET is_deleted=true,deleted_at=now() WHERE id=?", archived);
        assertThrows(ApiException.class, () -> service.preview(new GoodsBomWhereUsedReplacementService.Request(old, replacement, List.of(a, historical))));
        assertEquals(old, component(current)); assertEquals(old, component(archived));
        UUID otherUnit = unit();
        db.update("UPDATE goods SET unit_id=? WHERE id=?", otherUnit, replacement);
        assertEquals(ErrorCode.VALIDATION_FAILED, assertThrows(ApiException.class, () -> service.preview(request(old, replacement, a))).getCode());
    }

    @Test void previewIsBoundToSessionAndImpersonationCannotWrite() {
        UUID a = goods("a"), old = goods("old"), replacement = goods("new"), original = edge(a, old);
        var preview = service.preview(request(old, replacement, a));
        login(admin.getPermissions(), UUID.randomUUID(), null);
        assertEquals(ErrorCode.CONFLICT, assertThrows(ApiException.class, () -> service.commit(new GoodsBomWhereUsedReplacementService.Commit(preview.previewToken()))).getCode());
        login(admin.getPermissions(), session, UUID.randomUUID());
        assertEquals(ErrorCode.FORBIDDEN, assertThrows(ApiException.class, () -> service.preview(request(old, replacement, a))).getCode());
        assertEquals(old, component(original));
    }

    @Test void reportingReadOrExportPermissionNeverGrantsRecipeEditAndExportIsIndependent() {
        UUID a = goods("a"), old = goods("old"), replacement = goods("new"); edge(a, old);
        login(Set.of("production_where_used:view", "production_where_used:export"), session, null);
        assertThrows(AccessDeniedException.class, () -> service.preview(request(old, replacement, a)));
        var document = exports.document(old, "current", null, null, null, null);
        assertEquals(1, document.sections().getFirst().rows().size());
        assertTrue(document.metadata().stream().anyMatch(value -> value.startsWith("操作员：") && value.length() > 4));
        assertTrue(document.metadata().stream().anyMatch(value -> value.contains("当前组件：") && value.contains(old.toString())));
        assertTrue(document.metadata().stream().anyMatch(value -> value.contains("导出时间：")));
        assertTrue(document.metadata().stream().anyMatch(value -> value.contains("当前 BOM")));
        login(Set.of("production_where_used:view", "production_report:export"), session, null);
        assertThrows(AccessDeniedException.class, () -> exports.document(old, "all", null, null, null, null));
    }

    private UUID goods(String tag) {
        UUID id = UUID.randomUUID();
        db.update("""
                INSERT INTO goods(id,code,name,unit_id,issue_method,status,auto_created,code_sequence)
                VALUES(?,?,?,?,'ORDER','使用',false,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))
                """, id, "WR-" + tag + "-" + id, tag, unit);
        created.add(id); return id;
    }
    private UUID unit() {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO units(id,code,name,status) VALUES(?,?,?,'使用')", id, "WRU-" + id, "WR-unit-" + id);
        createdUnits.add(id); return id;
    }
    private UUID edge(UUID parent, UUID component) {
        UUID id = UUID.randomUUID();
        db.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,summary) VALUES(?,?,?,2.5,'keep original')", id, parent, component);
        return id;
    }
    private UUID component(UUID edge) { return db.queryForObject("SELECT component_goods_id FROM goods_bom_items WHERE id=?", UUID.class, edge); }
    private GoodsBomWhereUsedReplacementService.Request request(UUID old, UUID replacement, UUID product) {
        return new GoodsBomWhereUsedReplacementService.Request(old, replacement, List.of(product));
    }
    private void login(Set<String> permissions, UUID sid, UUID impersonator) {
        AuthUser principal = new AuthUser(admin.getId(), admin.getEmployeeId(), admin.getUsername(), permissions,
                false, true, false, false, impersonator, sid);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal, null, principal.getAuthorities()));
    }
}
