package com.uten.imp.common.mastercode;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.jdbc.AutoConfigureTestDatabase;
import org.springframework.boot.test.autoconfigure.orm.jpa.DataJpaTest;
import org.springframework.context.annotation.Import;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.annotation.DirtiesContext;
import org.springframework.test.context.TestContext;
import org.springframework.test.context.TestExecutionListeners;
import org.springframework.test.context.support.AbstractTestExecutionListener;
import org.springframework.test.context.support.DirtiesContextTestExecutionListener;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.UUID;
import java.util.List;

import static com.uten.imp.common.mastercode.CategoryDrivenCodeService.MasterType.GOODS;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** PostgreSQL proof for recursive prefix ownership and uniqueness-safe bulk renumbering. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
// Evict the cached pool together with this class-owned PostgreSQL container.
@DirtiesContext(classMode = DirtiesContext.ClassMode.AFTER_CLASS)
@TestExecutionListeners(listeners = CategoryDrivenCodeServicePostgresTest.DatabaseCleanup.class,
        mergeMode = TestExecutionListeners.MergeMode.MERGE_WITH_DEFAULTS)
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

    public static class DatabaseCleanup extends AbstractTestExecutionListener {
        // Spring invokes afterTestClass in reverse order: close its pool before PostgreSQL.
        @Override public int getOrder() { return new DirtiesContextTestExecutionListener().getOrder() - 1; }
        @Override public void afterTestClass(TestContext ignored) { POSTGRES.stop(); }
    }

    @Autowired
    private CategoryDrivenCodeService service;

    @Autowired
    private JdbcTemplate jdbc;

    @Autowired
    private PlatformTransactionManager transactionManager;

    @Autowired
    private jakarta.persistence.EntityManager entityManager;

    @Autowired
    private com.uten.imp.features.master.mould.MouldRepository mouldRepository;

    @Autowired
    private com.uten.imp.features.master.mouldcategory.MouldCategoryRepository mouldCategoryRepository;

    @Test
    void mouldCategorySeriesSearchKeepsSubtreePaginationGlobalSearchAndExportInAgreement() {
        UUID root = UUID.randomUUID();
        UUID child = UUID.randomUUID();
        UUID outside = UUID.randomUUID();
        jdbc.update("INSERT INTO mould_categories (id, code, name, remark, is_deleted) VALUES (?, 'SERIES-ROOT', 'Q7系列', '旧分类备注', false)", root);
        jdbc.update("INSERT INTO mould_categories (id, code, name, parent_id, is_deleted) VALUES (?, 'SERIES-CHILD', 'Q7开关子系列', ?, false)", child, root);
        jdbc.update("INSERT INTO mould_categories (id, code, name, is_deleted) VALUES (?, 'SERIES-OUTSIDE', 'Q7外部系列', false)", outside);
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        UUID outsideMould = UUID.randomUUID();
        UUID unrelated = UUID.randomUUID();
        jdbc.update("INSERT INTO moulds (id, category_id, code, name, code_sequence, status, is_deleted) VALUES (?, ?, 'SERIES-M001', '双联开关模具', 1, '使用', false)", first, root);
        jdbc.update("INSERT INTO moulds (id, category_id, code, name, code_sequence, status, is_deleted) VALUES (?, ?, 'SERIES-M002', '双联开关模具', 2, '使用', false)", second, child);
        jdbc.update("INSERT INTO moulds (id, category_id, code, name, code_sequence, status, is_deleted) VALUES (?, ?, 'SERIES-M003', '双联开关模具', 3, '使用', false)", outsideMould, outside);
        jdbc.update("INSERT INTO moulds (id, category_id, code, name, code_sequence, status, is_deleted) VALUES (?, ?, 'SERIES-M004', '双联插座模具', 4, '使用', false)", unrelated, child);
        var mouldService = new com.uten.imp.features.master.mould.MouldService(mouldRepository, mouldCategoryRepository,
                org.mockito.Mockito.mock(com.uten.imp.security.TxSessionVars.class), entityManager, service,
                org.mockito.Mockito.mock(com.uten.imp.common.util.DepartmentNameResolver.class),
                org.mockito.Mockito.mock(com.uten.imp.common.util.EmployeeNameResolver.class));
        var filter = new com.uten.imp.features.master.mould.dto.MouldQueryFilter(root, null, java.util.Set.of(),
                null, "双联开关模具", null, null, null, "使用", null)
                .withColumnSearch(java.util.Map.of("categoryName", "Q7", "name", "开关"));
        var pageOne = mouldService.list(filter, 1, 1);
        var pageTwo = mouldService.list(filter, 2, 1);
        assertEquals(2, pageOne.getTotal());
        assertEquals(2, pageTwo.getTotal());
        assertEquals(first, pageOne.getItems().getFirst().getId());
        assertEquals("Q7系列", pageOne.getItems().getFirst().getCategoryName());
        assertEquals(second, pageTwo.getItems().getFirst().getId());
        assertEquals("Q7开关子系列", pageTwo.getItems().getFirst().getCategoryName());
        var exported = mouldService.export(filter, 100);
        assertEquals(2, exported.rows().size());
        assertEquals(java.util.Set.of("Q7系列", "Q7开关子系列"), exported.rows().stream()
                .map(row -> row.get("categoryName")).collect(java.util.stream.Collectors.toSet()));
        var global = mouldService.list(new com.uten.imp.features.master.mould.dto.MouldQueryFilter(null, "Q7", null,
                null, null, null, null, null, null, null), 1, 20);
        assertEquals(java.util.Set.of(first, second, outsideMould, unrelated), global.getItems().stream()
                .map(item -> item.getId()).collect(java.util.stream.Collectors.toSet()));
    }

    @Test
    void masterColumnSearchUsesDisplayedTextAndCombinesColumnsBeforePagination() {
        UUID category = UUID.randomUUID();
        UUID hit = UUID.randomUUID();
        UUID other = UUID.randomUUID();
        UUID color = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        insertCategory(category, "COLSEARCH-CAT", "搜索分类", null, "9S");
        insertGoods(hit, category, "COLSEARCH-HIT", 1, null, false, false);
        insertGoods(other, category, "COLSEARCH-OTHER", 2, null, false, false);
        jdbc.update("INSERT INTO colors (id, legacy_id, code, name, is_deleted) VALUES (?, 919191, 'COLSEARCH-COLOR', '银灰色', false)", color);
        jdbc.update("INSERT INTO units (id, legacy_id, code, name, is_deleted) VALUES (?, 919192, 'COLSEARCH-UNIT', '套件', false)", unit);
        jdbc.update("UPDATE goods SET name = '双联 开关', spec = '10A 250V', color_id = ?, unit_id = ? WHERE id = ?", color, unit, hit);
        jdbc.update("UPDATE goods SET name = '双联 插座', spec = '10A 250V', color_id = ?, unit_id = ? WHERE id = ?", color, unit, other);
        var searches = java.util.Map.of("name", "双联 开关", "spec", "250V", "colorLegacyId", "灰色", "unitLegacyId", "套");
        assertEquals(List.of(hit), masterMatches(
                com.uten.imp.features.master.search.MasterColumnSearch.Domain.GOODS, searches));
        // The same displayed names still match old UUID-missing rows, without creating relations.
        jdbc.update("UPDATE goods SET color_id = NULL, unit_id = NULL, color_legacy_id = 919191, unit_legacy_id = 919192 WHERE id = ?", hit);
        assertEquals(List.of(hit), masterMatches(
                com.uten.imp.features.master.search.MasterColumnSearch.Domain.GOODS, searches));

        UUID client = UUID.randomUUID();
        UUID supplier = UUID.randomUUID();
        UUID mould = UUID.randomUUID();
        jdbc.update("INSERT INTO clients (id, code, name, mobile, code_sequence, is_deleted) VALUES (?, 'COLSEARCH-CLIENT', '电器客户', '13800123456', 1, false)", client);
        jdbc.update("INSERT INTO suppliers (id, code, name, phone, code_sequence, is_deleted) VALUES (?, 'COLSEARCH-SUPPLIER', '电器供应商', '0760-123456', 1, false)", supplier);
        jdbc.update("INSERT INTO moulds (id, code, name, manufacturer, code_sequence, is_deleted) VALUES (?, 'COLSEARCH-MOULD', '双联开关', '优腾制造', 1, false)", mould);
        assertEquals(List.of(client), masterMatches(
                com.uten.imp.features.master.search.MasterColumnSearch.Domain.CLIENT, java.util.Map.of("mobile", "13800", "name", "客户")));
        assertEquals(List.of(supplier), masterMatches(
                com.uten.imp.features.master.search.MasterColumnSearch.Domain.SUPPLIER, java.util.Map.of("phone", "123456", "name", "电器")));
        assertEquals(List.of(mould), masterMatches(
                com.uten.imp.features.master.search.MasterColumnSearch.Domain.MOULD, java.util.Map.of("name", "开关", "manufacturer", "优腾")));
    }

    private List<UUID> masterMatches(com.uten.imp.features.master.search.MasterColumnSearch.Domain domain,
                                    java.util.Map<String, String> searches) {
        var cb = entityManager.getCriteriaBuilder();
        var query = cb.createQuery(UUID.class);
        Class<?> entity = switch (domain) {
            case GOODS -> com.uten.imp.features.master.goods.Goods.class;
            case CLIENT -> com.uten.imp.features.master.client.Client.class;
            case SUPPLIER -> com.uten.imp.features.master.supplier.Supplier.class;
            case MOULD -> com.uten.imp.features.master.mould.Mould.class;
        };
        var root = query.from(entity);
        query.select(root.get("id")).where(com.uten.imp.features.master.search.MasterColumnSearch.predicate(
                cb, root.get("id"), domain, searches));
        // The count uses the exact same expression, and page boundaries apply in SQL.
        var countQuery = cb.createQuery(Long.class);
        var countRoot = countQuery.from(entity);
        countQuery.select(cb.count(countRoot)).where(com.uten.imp.features.master.search.MasterColumnSearch.predicate(
                cb, countRoot.get("id"), domain, searches));
        assertEquals(entityManager.createQuery(countQuery).getSingleResult().intValue(),
                entityManager.createQuery(query).getResultList().size());
        return entityManager.createQuery(query).setFirstResult(0).setMaxResults(20).getResultList();
    }

    @Test
    void livePrefixCheckUsesLifetimeCrossDomainReservationsWithoutClaiming() {
        UUID owner = UUID.randomUUID();
        UUID child = UUID.randomUUID();
        insertCategory(owner, "PREFIX-OWNER", "已占用分类", null, "UQ");
        insertCategory(child, "PREFIX-CHILD", "继承分类", owner, null);
        long before = longValue("SELECT count(*) FROM business_prefix_reservation_members");

        for (var type : CategoryDrivenCodeService.MasterType.values()) {
            CategoryPrefixAvailability occupied = service.prefixAvailability(type, " uq ", null);
            assertEquals("UQ", occupied.normalizedPrefix());
            assertFalse(occupied.available());
            assertEquals(CategoryPrefixAvailability.OCCUPIED_MESSAGE, occupied.message());
            assertFalse(service.prefixAvailability(type, "hp", null).available(),
                    "The fixed goods namespace is occupied across every master domain");
            assertTrue(service.prefixAvailability(type, "UQX", null).available(),
                    "Only the exact prefix token conflicts, not a longer token");
            assertTrue(service.prefixAvailability(type, "", null).available());
        }
        assertTrue(service.prefixAvailability(GOODS, "uQ", owner).available());
        assertFalse(service.prefixAvailability(GOODS, "UQ", child).available(),
                "An inherited prefix cannot be explicitly claimed by the child");
        assertThrows(ApiException.class, () -> service.prefixAvailability(
                CategoryDrivenCodeService.MasterType.MOULD, "UQ", owner));
        assertEquals(before, longValue("SELECT count(*) FROM business_prefix_reservation_members"),
                "Typing checks must not reserve any candidate");

        UUID deletedOwner = UUID.randomUUID();
        insertCategory(deletedOwner, "PREFIX-DELETED", "已删除分类", null, "UQR");
        jdbc.update("UPDATE material_categories SET is_deleted = true WHERE id = ?", deletedOwner);
        assertFalse(service.prefixAvailability(GOODS, "UQR", null).available());
        assertThrows(ApiException.class,
                () -> service.prefixAvailability(GOODS, "UQR", deletedOwner));
    }

    @Test
    void livePrefixCheckMatchesCurrentAndHistoricalSameOwnerAllowance() {
        UUID owner = UUID.randomUUID();
        insertCategory(owner, "PREFIX-HISTORY", "历史前缀分类", null, "UQ");
        jdbc.update("UPDATE material_categories SET code_prefix = 'UQX' WHERE id = ?", owner);
        assertTrue(service.prefixAvailability(GOODS, "UQ", owner).available(),
                "A sole owner may reclaim its previous prefix");
        assertFalse(service.prefixAvailability(GOODS, "UQ", null).available());

        claimHistoricalPrefix("UQ", "HISTORICAL_DOCUMENT");
        assertFalse(service.prefixAvailability(GOODS, "UQ", owner).available(),
                "A historical collision prevents returning to an old prefix");
        claimHistoricalPrefix("UQX", "HISTORICAL_DOCUMENT");
        assertTrue(service.prefixAvailability(GOODS, "UQX", owner).available(),
                "Keeping the current legacy prefix is permitted by the save guard");
        jdbc.update("UPDATE material_categories SET code_prefix = 'UQZ' WHERE id = ?", owner);
        assertFalse(service.prefixAvailability(GOODS, "UQX", owner).available());
    }

    @Test
    void databaseStillRejectsAClaimMadeAfterTheLiveCheck() {
        assertTrue(service.prefixAvailability(GOODS, "UQ", null).available());
        assertTrue(service.prefixAvailability(
                CategoryDrivenCodeService.MasterType.MOULD, "UQ", null).available());
        insertCategory(UUID.randomUUID(), "PREFIX-FIRST", "先保存的分类", null, "UQ");
        assertFalse(service.prefixAvailability(
                CategoryDrivenCodeService.MasterType.MOULD, "UQ", null).available());
        assertThrows(DataIntegrityViolationException.class, () -> jdbc.update("""
                INSERT INTO mould_categories (id, code, name, code_prefix, is_deleted)
                VALUES (?, 'PREFIX-SECOND', '后保存的分类', 'UQ', false)
                """, UUID.randomUUID()));
    }

    private void claimHistoricalPrefix(String prefix, String namespace) {
        jdbc.queryForList("""
                SELECT fn_claim_global_business_prefix(
                    ?, 'NAMESPACE', ?, NULL, NULL, ?, 'HISTORICAL', NULL, TRUE)
                """, prefix, namespace, prefix);
    }

    @Test
    void digitStartingPrefixesAreValidatedReservedAndAllocatedWithoutRewritingExistingCodes() {
        UUID category = UUID.randomUUID();
        UUID existingGoods = UUID.randomUUID();
        insertCategory(category, "DIGIT-PREFIX", "数字编号分类", null, "28");
        insertGoods(existingGoods, category, "LEGACY-DIGIT", 1, null, false, false);
        jdbc.update("UPDATE category_master_code_sequences SET last_seq = 1 WHERE master_type = 'GOODS'");

        var allocation = service.allocate(GOODS, category, null);
        assertEquals("28000002", allocation.code());
        assertEquals(category, allocation.prefixCategoryId());
        assertTrue(allocation.managed());
        assertCode(existingGoods, "LEGACY-DIGIT", false, null);
        assertFalse(service.prefixAvailability(CategoryDrivenCodeService.MasterType.MOULD, "28", null).available());

        String[] tables = {"mould_categories", "client_categories", "supplier_categories"};
        for (int i = 0; i < tables.length; i++) {
            jdbc.update("INSERT INTO " + tables[i]
                    + " (id, code, name, code_prefix, is_deleted) VALUES (?, ?, ?, ?, false)",
                    UUID.randomUUID(), "DIGIT-CAT-" + i, "数字分类", (i + 3) + "A");
        }
    }

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
        UUID currency = jdbc.queryForObject("""
                SELECT id
                FROM currencies
                WHERE is_base_currency
                  AND status = '使用'
                  AND COALESCE(is_deleted, false) = false
                """, UUID.class);
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
                    id, code, name, account_type, status, currency_id,
                    style_id, style_legacy_id, is_deleted)
                VALUES (?, 'AC-T910001', 'UUID关系测试账户', 'BANK', '使用', ?,
                        ?, NULL, false)
                """, account, currency, uuidStyle);

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
