package com.uten.imp.common.mastercode;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.jdbc.test.autoconfigure.AutoConfigureTestDatabase;
import org.springframework.boot.data.jpa.test.autoconfigure.DataJpaTest;
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
import org.testcontainers.postgresql.PostgreSQLContainer;

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
@Import({CategoryDrivenCodeService.class, MasterIdentifierAvailabilityService.class, MasterCodeService.class,
        com.uten.imp.features.master.history.MasterIdentifierVersionRestorer.class,
        com.uten.imp.migration.AppliedMigrationCompatibilityCallback.class,
        com.uten.imp.migration.AuditFreshStartGuardCallback.class})
class CategoryDrivenCodeServicePostgresTest {

    private static final PostgreSQLContainer POSTGRES =
            new PostgreSQLContainer("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("fixture_admin")
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
    private MasterIdentifierAvailabilityService identifiers;

    @Autowired
    private MasterCodeService fixedCodes;

    @Autowired
    private com.uten.imp.features.master.history.MasterIdentifierVersionRestorer identifierRestore;

    @Test
    void restoringAnOldGoodsCodeKeepsCurrentIdentityMetadataAndAutoAllocationSkipsItsLifetimeClaim() throws Exception {
        UUID category = UUID.randomUUID(), goods = UUID.randomUUID();
        insertCategory(category, "RESTORE-NUMBER-CATEGORY", "编号恢复", null, "9Z");
        insertGoods(goods, category, "9Z01", 100, category, true, false);
        var custom = service.allocateForUpdate(GOODS, goods, category, "RESTORE-CUSTOM",
                new CategoryCodeAllocation("9Z01", 100, category, true));
        jdbc.update("UPDATE goods SET code=?,code_managed=?,code_prefix_category_id=? WHERE id=?",
                custom.code(), custom.managed(), custom.prefixCategoryId(), goods);
        var mapper = new com.fasterxml.jackson.databind.ObjectMapper();
        var current = mapper.readTree(jdbc.queryForObject("SELECT to_jsonb(g)::text FROM goods g WHERE id=?", String.class, goods));
        var old = current.deepCopy();
        ((com.fasterxml.jackson.databind.node.ObjectNode) old).put("code", "9Z01").put("code_sequence", 1).put("code_managed", true);
        identifierRestore.lockForRestore("goods");
        var restored = identifierRestore.prepare(List.of(new com.uten.imp.features.master.history.MasterVersionRow("goods", goods, current, old))).getFirst().target();
        assertEquals(100, restored.path("code_sequence").asLong(), "A stale historical sequence must never replace today's identity counter");
        jdbc.update("UPDATE goods SET code=?,code_sequence=?,code_managed=?,code_prefix_category_id=? WHERE id=?",
                restored.path("code").asText(), restored.path("code_sequence").asLong(), restored.path("code_managed").asBoolean(),
                UUID.fromString(restored.path("code_prefix_category_id").asText()), goods);
        var automatic = service.allocate(GOODS, category, null);
        assertEquals("9Z02", automatic.code());
        insertGoods(UUID.randomUUID(), category, automatic.code(), automatic.sequence(), automatic.prefixCategoryId(), automatic.managed(), false);
        assertEquals(2, longValue("SELECT count(DISTINCT code) FROM goods WHERE category_id='" + category + "'"));
        assertTrue(identifiers.check(MasterIdentifierAvailabilityService.Domain.GOODS, "9Z01", goods).available());
        assertFalse(identifiers.check(MasterIdentifierAvailabilityService.Domain.GOODS, "9Z01", null).available());
    }

    @Test
    void prefixRenumberingPastNinetyNineUsesFullSuffixAndFrozenAssignments() {
        UUID category = UUID.randomUUID();
        insertCategory(category, "PAST99-CATEGORY", "157个塑胶件", null, "9R");
        for (int i = 1; i <= 157; i++) {
            insertGoods(UUID.randomUUID(), category, "PAST99-" + String.format("%03d", i),
                    i, null, false, false);
        }
        var preview = service.preview(GOODS, category, "9T");
        assertEquals(157, preview.affectedRecords());
        assertEquals(0, preview.conflicts());
        jdbc.update("UPDATE material_categories SET code_prefix='9T' WHERE id=?", category);
        assertEquals(157, service.reconcileSubtree(GOODS, category, "9R", "9T"));
        assertEquals(157, longValue("SELECT count(DISTINCT code) FROM goods WHERE category_id='" + category + "'"));
        assertEquals("9T99", jdbc.queryForObject("SELECT new_code FROM master_code_history WHERE old_code='PAST99-099'", String.class));
        assertEquals("9T100", jdbc.queryForObject("SELECT new_code FROM master_code_history WHERE old_code='PAST99-100'", String.class));
        assertEquals("9T157", jdbc.queryForObject("SELECT new_code FROM master_code_history WHERE old_code='PAST99-157'", String.class));
        assertEquals(157, longValue("SELECT count(*) FROM goods g JOIN master_code_history h ON h.entity_id=g.id AND h.new_code=g.code WHERE g.category_id='" + category + "'"));
        assertEquals(0, longValue("SELECT count(*) FROM goods WHERE code LIKE '__MCB_%'"));
        assertEquals(0, longValue("SELECT count(*) FROM master_record_versions v JOIN goods g ON g.id=v.record_id WHERE g.category_id='" + category + "' AND (left(v.before_row->>'code',6)='__MCB_' OR left(v.after_row->>'code',6)='__MCB_')"));
        assertEquals(157, longValue("SELECT count(*) FROM master_record_versions v JOIN goods g ON g.id=v.record_id WHERE g.category_id='" + category + "' AND v.source_table='goods' AND v.before_row->>'code' LIKE 'PAST99-%' AND v.after_row->>'code' LIKE '9T%'"));
    }

    @Test
    void liveCodeChecksRespectNormalizedLifetimeIdentityAndNeverAllocate() {
        UUID category = UUID.randomUUID();
        UUID owner = UUID.randomUUID();
        insertCategory(category, "LIVE-CODE-CATEGORY", "编号查重", null, null);
        insertGoods(owner, category, "LIVE-CODE-OLD", 1, null, false, false);
        long before = longValue("SELECT count(*) FROM business_identifier_reservation_members");
        for (var domain : MasterIdentifierAvailabilityService.Domain.values()) {
            assertFalse(identifiers.check(domain, " live-code-old ", null).available());
            assertTrue(identifiers.check(domain, "LIVE-CODE-FREE", null).available());
            assertTrue(identifiers.check(domain, "", null).available());
        }
        assertTrue(identifiers.check(MasterIdentifierAvailabilityService.Domain.GOODS,
                "live-code-old", owner).available());
        assertFalse(identifiers.check(MasterIdentifierAvailabilityService.Domain.GOODS,
                "HP000001", null).available(), "A long managed code must also have a free stable suffix");
        assertTrue(identifiers.check(MasterIdentifierAvailabilityService.Domain.GOODS,
                "HP000001", owner).available());
        assertEquals(before, longValue("SELECT count(*) FROM business_identifier_reservation_members"));
        jdbc.update("UPDATE goods SET code='LIVE-CODE-NEW' WHERE id=?", owner);
        assertTrue(identifiers.check(MasterIdentifierAvailabilityService.Domain.GOODS,
                "LIVE-CODE-OLD", owner).available(), "Only its original identity may reclaim an old number");
        jdbc.update("UPDATE goods SET is_deleted=true WHERE id=?", owner);
        assertFalse(identifiers.check(MasterIdentifierAvailabilityService.Domain.GOODS,
                "LIVE-CODE-OLD", null).available());
        assertThrows(ApiException.class, () -> identifiers.check(
                MasterIdentifierAvailabilityService.Domain.GOODS, "LIVE-CODE-OLD", owner));
    }

    @Test
    void manualFixedCodeDoesNotAdvanceAutoSequenceAndAutoSkipsReservations() {
        jdbc.update("INSERT INTO currencies(id,code,name,status,is_deleted) VALUES (?,'BZ000001','编号测试币种','使用',false)", UUID.randomUUID());
        assertEquals("CUSTOM-CURRENCY", fixedCodes.resolveMutableCode(MasterCodePrefix.CURRENCY,
                " custom-currency ", null, null));
        assertEquals("BZ000002", fixedCodes.resolveMutableCode(MasterCodePrefix.CURRENCY,
                null, null, null));
        assertThrows(ApiException.class, () -> fixedCodes.resolveMutableCode(MasterCodePrefix.CURRENCY,
                " bz000001 ", null, null));
    }

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
                null, "双联开关模具", null, null, null, null, "使用", null)
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
                null, null, null, null, null, null, null, null), 1, 20);
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

        // 显式前缀走「前缀+两位序号」受管发号（2026-10-19 用户口径：2080358 → 208035801…99）；
        // code_sequence 仍是全局身份计数（此处 2），不再渲染进编号文本。
        var allocation = service.allocate(GOODS, category, null);
        assertEquals("2801", allocation.code());
        assertEquals(2L, allocation.sequence());
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
    void newOrCopiedGoodsUseTheTargetPrefixAndShortSuffixInsteadOfTheSourceOrGlobalCounter() {
        UUID source = UUID.randomUUID(), target = UUID.randomUUID(), targetLeaf = UUID.randomUUID();
        insertCategory(source, "COPY-SOURCE-NUMERIC", "原分类", null, "2008935");
        insertCategory(target, "COPY-TARGET-NUMERIC", "目标分类", null, "2881342");
        insertCategory(targetLeaf, "COPY-TARGET-CHILD", "目标子分类", target, null);
        for (int sequence = 501; sequence <= 520; sequence++) {
            insertGoods(UUID.randomUUID(), source, "2008935" + String.format("%02d", sequence - 500),
                    sequence, source, true, sequence < 520);
        }
        jdbc.update("UPDATE category_master_code_sequences SET last_seq=520 WHERE master_type='GOODS'");

        var allocation = service.allocate(GOODS, targetLeaf, null);

        assertEquals("288134201", allocation.code());
        assertEquals(521L, allocation.sequence(), "The identity counter is independent from the displayed short suffix");
        assertEquals(target, allocation.prefixCategoryId());
        assertTrue(allocation.managed());
        insertGoods(UUID.randomUUID(), targetLeaf, allocation.code(), allocation.sequence(), allocation.prefixCategoryId(), true, false);
        assertEquals("288134202", service.allocate(GOODS, targetLeaf, null).code());
        assertEquals(20L, longValue("SELECT count(*) FROM goods WHERE category_id='" + source + "' AND code LIKE '2008935%'"));
        assertEquals(19L, longValue("SELECT count(*) FROM goods WHERE category_id='" + source + "' AND is_deleted"));
    }

    @Test
    void newGoodsCanReuseAProvenUnusedDeletedLabelWithANewIdentityCounterAndReadOnlyPreview() {
        UUID category = UUID.randomUUID(), first = UUID.randomUUID(), second = UUID.randomUUID();
        insertCategory(category, "REUSE-CREATE-TARGET", "编号回用分类", null, "N9");
        var original = service.allocateForNewGoods(category, null, first);
        insertGoods(first, category, original.code(), original.sequence(), original.prefixCategoryId(), true, false);
        jdbc.update("UPDATE goods SET is_deleted=true,deleted_at=now() WHERE id=?", first);
        long claimsBeforePreview = longValue("SELECT count(*) FROM goods_code_reuse_releases");

        assertTrue(identifiers.check(MasterIdentifierAvailabilityService.Domain.GOODS, original.code(), null, category).available());
        assertEquals(claimsBeforePreview, longValue("SELECT count(*) FROM goods_code_reuse_releases"));
        var reused = service.allocateForNewGoods(category, null, second);
        assertEquals(original.code(), reused.code());
        assertTrue(reused.sequence() > original.sequence());
        insertGoods(second, category, reused.code(), reused.sequence(), reused.prefixCategoryId(), true, false);
        assertEquals(2L, longValue("SELECT count(*) FROM goods WHERE code='" + original.code() + "'"));
        assertEquals(1L, longValue("SELECT count(*) FROM goods_code_reuse_releases WHERE old_goods_id='" + first + "' AND new_goods_id='" + second + "'"));
        assertFalse(identifiers.checkForRestore(MasterIdentifierAvailabilityService.Domain.GOODS, original.code(), first, category).available());
        assertThrows(DataIntegrityViolationException.class,
                () -> jdbc.update("UPDATE goods SET is_deleted=false WHERE id=?", first));
    }

    @Test
    void explicitPrefixAllocationScansShortSuffixesAndGrowsPast99() {
        UUID category = UUID.randomUUID();
        insertCategory(category, "SHORT-PREFIX", "短编号分类", null, "2080358");
        jdbc.update("UPDATE category_master_code_sequences SET last_seq = 10 WHERE master_type = 'GOODS'");

        // 占掉 01 与 02（终身保留表），下一次自动发号应跳到 208035803。
        // 保留行与成员行同语句写入（CTE 回流），规避切片环境下跨语句可见性差异。
        jdbc.update("""
                WITH seeded AS (
                    INSERT INTO master_code_reservations (master_domain, normalized_code, first_code_snapshot, first_entity_id)
                    VALUES ('GOODS', '208035801', '208035801', gen_random_uuid()),
                            ('GOODS', '208035802', '208035802', gen_random_uuid())
                    ON CONFLICT DO NOTHING
                    RETURNING master_domain, normalized_code
                ), reserved AS (
                    SELECT master_domain, normalized_code FROM seeded
                    UNION SELECT 'GOODS', v.code FROM (VALUES ('208035801'), ('208035802')) AS v(code)
                )
                INSERT INTO master_code_reservation_members (master_domain, normalized_code, entity_id, code_snapshot)
                SELECT DISTINCT master_domain, normalized_code, gen_random_uuid(), normalized_code
                FROM reserved
                ON CONFLICT DO NOTHING
                """);

        var allocation = service.allocate(GOODS, category, null);
        assertEquals("208035803", allocation.code());
        assertEquals(11L, allocation.sequence());
        assertTrue(allocation.managed());
        assertEquals(category, allocation.prefixCategoryId());

        // 01..99 全被占用：短号自然进位到三位（100），不再停在 99 报错。
        jdbc.update("""
                WITH seeded AS (
                    INSERT INTO master_code_reservations (master_domain, normalized_code, first_code_snapshot, first_entity_id)
                    SELECT 'GOODS', '2080358' || to_char(n, 'FM00'), '2080358' || to_char(n, 'FM00'), gen_random_uuid()
                    FROM generate_series(3, 99) AS n
                    ON CONFLICT DO NOTHING
                    RETURNING master_domain, normalized_code
                ), reserved AS (
                    SELECT master_domain, normalized_code FROM seeded
                    UNION SELECT 'GOODS', '2080358' || to_char(n, 'FM00') FROM generate_series(3, 99) AS n
                )
                INSERT INTO master_code_reservation_members (master_domain, normalized_code, entity_id, code_snapshot)
                SELECT DISTINCT master_domain, normalized_code, gen_random_uuid(), normalized_code
                FROM reserved
                ON CONFLICT DO NOTHING
                """);
        var past99 = service.allocate(GOODS, category, null);
        assertEquals("2080358100", past99.code());
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

        // 2026-10-19 口径「改前缀=全部重新来过」：显式前缀下子树按现有编号顺序
        // 从头重排（V601、V602…），不再沿用旧后缀；历史/手工编号一并纳入。
        Integer affected = transaction.execute(status -> {
            jdbc.update(
                    "UPDATE material_categories SET code_prefix = 'V6' WHERE id = ?",
                    root);
            return service.reconcileSubtree(GOODS, root, "AA", "V6");
        });
        assertEquals(3, affected);

        assertCode(rootGoods, "V601", true, root);
        assertCode(inheritedGoods, "V602", true, root);
        assertCode(customGoods, "V603", true, root);
        assertCode(overrideGoods, "BB000003", true, overrideChild);
        assertEquals(3L, longValue("""
                SELECT count(*) FROM master_code_history
                WHERE master_type = 'GOODS' AND reason = 'CATEGORY_PREFIX_CHANGE'
                """));
        assertEquals(3L, longValue("""
                SELECT count(*) FROM audit_log
                WHERE target_type = 'goods' AND action = 'update'
                  AND "after" ->> 'code' IN ('V601', 'V602', 'V603')
                """));
        assertFalse(Boolean.TRUE.equals(jdbc.queryForObject("""
                SELECT bool_or("after" ? 'ground_graph') FROM audit_log
                WHERE target_type = 'goods' AND action = 'update'
                  AND "after" ->> 'code' IN ('V601', 'V602', 'V603')
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
        // 显式前缀下重排是「从头编号」口径：即使有效前缀不变，旧六位号也规划为
        // 重排成短号（AA01），与真正执行的 reconcileSubtree 同一套目标计算。
        assertEquals(1L, current.affectedRecords());
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
