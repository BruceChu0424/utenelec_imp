package com.uten.imp.common.mastercode;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.context.annotation.Import;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.UUID;

import static com.uten.imp.common.mastercode.CategoryDrivenCodeService.MasterType.GOODS;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** PostgreSQL proof for recursive prefix ownership and uniqueness-safe bulk renumbering. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@DataJpaTest(properties = {
        "spring.jpa.hibernate.ddl-auto=none",
        "spring.flyway.enabled=true",
        "spring.jpa.show-sql=false",
        "logging.level.org.hibernate.SQL=OFF"
})
@AutoConfigureTestDatabase(replace = AutoConfigureTestDatabase.Replace.NONE)
@Import(CategoryDrivenCodeService.class)
class CategoryDrivenCodeServicePostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    @DynamicPropertySource
    static void database(DynamicPropertyRegistry registry) {
        POSTGRES.start();
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Autowired
    private CategoryDrivenCodeService service;

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private PlatformTransactionManager transactionManager;

    @Test
    void rootChangeRenumbersInheritedAndCustomRowsButNotCloserOverride() {
        UUID root = UUID.randomUUID();
        UUID inheritedChild = UUID.randomUUID();
        UUID overrideChild = UUID.randomUUID();
        UUID rootGoods = UUID.randomUUID();
        UUID inheritedGoods = UUID.randomUUID();
        UUID overrideGoods = UUID.randomUUID();
        UUID customGoods = UUID.randomUUID();
        UUID deletedCaseConflict = UUID.randomUUID();

        TransactionTemplate transaction = new TransactionTemplate(transactionManager);
        transaction.executeWithoutResult(status -> {
            insertCategory(root, "ROOT", "根分类", null, "AA");
            insertCategory(inheritedChild, "CHILD", "继承分类", root, null);
            insertCategory(overrideChild, "OVERRIDE", "覆盖分类", root, "BB");
            insertGoods(rootGoods, root, "AA000001", 1, root, true, false);
            insertGoods(inheritedGoods, inheritedChild, "AA000002", 2, root, true, false);
            insertGoods(overrideGoods, overrideChild, "BB000003", 3, overrideChild, true, false);
            insertGoods(customGoods, inheritedChild, "LEGACY-X", 4, null, false, false);
            insertGoods(deletedCaseConflict, root, " CaseOnly ", 5, null, false, true);
            jdbc.update("""
                    UPDATE category_master_code_sequences
                    SET last_seq = 5
                    WHERE master_type = 'GOODS'
                    """);
        });

        CategoryPrefixPreview preview = transaction.execute(status ->
                service.preview(GOODS, root, "v6"));
        assertEquals("V6", preview.resultingEffectivePrefix());
        assertEquals(3L, preview.affectedRecords());
        assertEquals(1L, preview.customOrLegacyRecords());
        assertEquals(1L, preview.descendantOverrides());
        assertEquals(0L, preview.conflicts());

        Integer affected = transaction.execute(status -> {
            jdbc.update(
                    "UPDATE material_categories SET code_prefix = 'V6' WHERE id = ?",
                    root);
            return service.reconcileSubtree(GOODS, root, "AA", "V6");
        });
        assertEquals(3, affected);

        assertCode(rootGoods, "V6000001", true, root);
        assertCode(inheritedGoods, "V6000002", true, root);
        assertCode(customGoods, "V6000004", true, root);
        assertCode(overrideGoods, "BB000003", true, overrideChild);
        assertEquals(3L, longValue("""
                SELECT count(*) FROM master_code_history
                WHERE master_type = 'GOODS' AND reason = 'CATEGORY_PREFIX_CHANGE'
                """));
        assertEquals(3L, longValue("""
                SELECT count(*) FROM audit_log
                WHERE target_type = 'goods' AND action = 'update'
                  AND "after" ->> 'code' IN ('V6000001', 'V6000002', 'V6000004')
                """));
        assertFalse(Boolean.TRUE.equals(jdbc.queryForObject("""
                SELECT bool_or("after" ? 'ground_graph') FROM audit_log
                WHERE target_type = 'goods' AND action = 'update'
                  AND "after" ->> 'code' IN ('V6000001', 'V6000002', 'V6000004')
                """, Boolean.class)));

        assertThrows(ApiException.class, () -> transaction.execute(status ->
                service.allocate(GOODS, root, "caseonly")),
                "Deleted historical numbers remain reserved case-insensitively");
    }

    @Test
    void parentMovePreviewUsesRequestedParentsEffectivePrefix() {
        UUID oldRoot = UUID.randomUUID();
        UUID newRoot = UUID.randomUUID();
        UUID child = UUID.randomUUID();
        UUID goods = UUID.randomUUID();
        insertCategory(oldRoot, "OLD-ROOT", "旧父分类", null, "AA");
        insertCategory(newRoot, "NEW-ROOT", "新父分类", null, "V6");
        insertCategory(child, "MOVING", "待移动分类", oldRoot, null);
        insertGoods(goods, child, "AA000007", 7, oldRoot, true, false);

        CategoryPrefixPreview current = service.preview(GOODS, child, "");
        CategoryPrefixPreview moved = service.previewForParent(
                GOODS, child, "", newRoot);

        assertEquals("AA", current.resultingEffectivePrefix());
        assertEquals(0L, current.affectedRecords());
        assertEquals("V6", moved.resultingEffectivePrefix());
        assertEquals(1L, moved.affectedRecords());
        assertEquals(0L, moved.conflicts());
    }

    @Test
    void subcontractSnapshotMaterializedViewSupportsConcurrentRefresh() {
        jdbc.execute("REFRESH MATERIALIZED VIEW CONCURRENTLY subcontract_monthly_mv");
    }

    @Test
    void accountPostingStyleResolverUsesUuidAndRejectsConflictingLegacyShadow() {
        UUID uuidStyle = UUID.randomUUID();
        UUID legacyStyle = UUID.randomUUID();
        UUID account = UUID.randomUUID();
        jdbc.update("""
                INSERT INTO payment_styles (
                    id, legacy_id, code, name, category, level, path, status, is_deleted)
                VALUES (?, 910001, 'T910001', 'UUID科目', 'ACCOUNT', 0,
                        '/T910001/', '使用', false),
                       (?, 910002, 'T910002', '旧影子科目', 'ACCOUNT', 0,
                        '/T910002/', '使用', false)
                """, uuidStyle, legacyStyle);
        jdbc.update("""
                INSERT INTO accounts (
                    id, code, name, account_type, status, style_id,
                    style_legacy_id, is_deleted)
                VALUES (?, 'AC-T910001', 'UUID关系测试账户', 'BANK', '使用', ?, NULL,
                        false)
                """, account, uuidStyle);

        UUID resolved = jdbc.queryForObject(
                "SELECT account_style_id(?)", UUID.class, account);
        assertEquals(uuidStyle, resolved);
        assertEquals(910001, jdbc.queryForObject(
                "SELECT style_legacy_id FROM accounts WHERE id = ?",
                Integer.class,
                account));

        assertThrows(DataIntegrityViolationException.class, () -> jdbc.update("""
                UPDATE accounts
                SET style_legacy_id = 910002
                WHERE id = ?
                """, account));
    }

    private void insertCategory(
            UUID id, String code, String name, UUID parentId, String prefix) {
        jdbc.update("""
                INSERT INTO material_categories (
                    id, code, name, parent_id, code_prefix, is_deleted)
                VALUES (?, ?, ?, ?, ?, false)
                """, id, code, name, parentId, prefix);
    }

    private void insertGoods(
            UUID id,
            UUID categoryId,
            String code,
            long sequence,
            UUID ownerId,
            boolean managed,
            boolean deleted) {
        jdbc.update("""
                INSERT INTO goods (
                    id, category_id, code, name, code_sequence,
                    code_prefix_category_id, code_managed, is_deleted)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, id, categoryId, code, "测试货品", sequence, ownerId, managed, deleted);
    }

    private void assertCode(UUID id, String code, boolean managed, UUID ownerId) {
        var row = jdbc.queryForMap("""
                SELECT code, code_managed, code_prefix_category_id
                FROM goods WHERE id = ?
                """, id);
        assertEquals(code, row.get("code"));
        assertEquals(managed, row.get("code_managed"));
        assertEquals(ownerId, row.get("code_prefix_category_id"));
    }

    private long longValue(String sql) {
        Long value = jdbc.queryForObject(sql, Long.class);
        assertTrue(value != null);
        return value;
    }
}
