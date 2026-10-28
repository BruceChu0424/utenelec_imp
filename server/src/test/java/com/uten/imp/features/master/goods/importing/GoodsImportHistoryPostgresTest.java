package com.uten.imp.features.master.goods.importing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.GoodsMasterWriteAccessPort;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.*;
import com.uten.imp.features.master.goods.history.GoodsOperationHistoryService;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.features.master.lifecycle.MasterReferenceGuard;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.*;
import com.uten.imp.support.MigratedSchemaBaseline;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.aop.framework.ProxyFactory;
import org.springframework.transaction.annotation.AnnotationTransactionAttributeSource;
import org.springframework.transaction.interceptor.TransactionInterceptor;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;

import java.io.ByteArrayOutputStream;
import java.time.Instant;
import java.util.*;
import java.util.function.Supplier;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real import and goods services, Hibernate and migrated PostgreSQL history/undo guards. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsImportHistoryPostgresTest {
    static MigratedSchemaBaseline.ScopedDatabase database;
    static EntityManagerFactory factory;
    static JpaTransactionManager transactions;
    EntityManager em;
    GoodsImportService importer;
    GoodsService goodsService;
    OwnerVisibility goodsOwners;
    GoodsOperationHistoryService history;
    SecurityContextCurrentUser current;
    UUID actor, categoryId, existingId;
    String existingCode, newCode;

    @BeforeAll static void start() throws Exception {
        database = MigratedSchemaBaseline.openDatabase("goods_import_merge");
        var bean = new LocalContainerEntityManagerFactoryBean();
        bean.setDataSource(new DriverManagerDataSource(database.getJdbcUrl(), database.getUsername(), database.getPassword()));
        bean.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        bean.setPackagesToScan("com.uten.imp");
        bean.setJpaPropertyMap(Map.of("hibernate.hbm2ddl.auto", "none"));
        bean.afterPropertiesSet(); factory = bean.getObject(); transactions = new JpaTransactionManager(factory);
    }
    @AfterAll static void stop() throws Exception {
        if (factory != null) factory.close();
        if (database != null) database.close();
    }
    @AfterEach void close() {
        if (em != null) {
            em.close();
        }
        SecurityContextHolder.clearContext();
    }
    @BeforeEach void prepare() {
        em = SharedEntityManagerCreator.createSharedEntityManager(factory); actor = UUID.randomUUID(); categoryId = UUID.randomUUID(); existingId = UUID.randomUUID();
        existingCode = ("IE" + UUID.randomUUID().toString().replace("-", "")).toUpperCase(Locale.ROOT);
        newCode = ("IN" + UUID.randomUUID().toString().replace("-", "")).toUpperCase(Locale.ROOT);
        Set<String> permissions = Set.of("goods:view", "goods:edit", "goods:purchase:edit", "goods:sales:edit", "goods:import", "goods:import:undo", "goods:price:edit", "goods:price:view");
        var principal = new AuthUser(actor, UUID.randomUUID(), "import-test", permissions, false, true, true);
        current = mock(SecurityContextCurrentUser.class);
        when(current.requireId()).thenReturn(actor); when(current.get()).thenReturn(Optional.of(principal));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal, "n/a",
                permissions.stream().map(SimpleGrantedAuthority::new).toList()));
        var goods = mock(GoodsRepository.class);
        when(goods.findById(any())).thenAnswer(call -> Optional.ofNullable(em.find(Goods.class, call.getArgument(0))));
        when(goods.findByCodeAndDeletedFalse(anyString())).thenAnswer(call -> em.createQuery(
                "from Goods g where g.code=:code and g.deleted=false", Goods.class)
                .setParameter("code", call.getArgument(0)).getResultStream().findFirst());
        when(goods.findFirstByCodeAndDeletedTrueOrderByIdAsc(anyString())).thenAnswer(call -> em.createQuery(
                        "from Goods g where g.code=:code and g.deleted=true order by g.id", Goods.class)
                .setParameter("code", call.getArgument(0)).setMaxResults(1).getResultStream().findFirst());
        when(goods.findImportIdentities()).thenAnswer(call -> em.createQuery("""
                select new com.uten.imp.features.master.goods.importing.GoodsImportIdentity(
                  g.id,g.version,g.code,g.name,c.id,g.deleted,g.ownerEmployeeId)
                from Goods g left join g.category c
                """, GoodsImportIdentity.class).getResultList());
        when(goods.quantityUnitInUse(any())).thenAnswer(call -> em.createNativeQuery("SELECT fn_goods_quantity_unit_in_use(:id)")
                .setParameter("id", call.getArgument(0)).getSingleResult());
        when(goods.save(any())).thenAnswer(call -> {
            Goods value = call.getArgument(0);
            if (!em.contains(value)) {
                value.setCreatedAt(Instant.now()); value.setUpdatedAt(Instant.now()); em.persist(value);
            }
            return value;
        });
        var categories = mock(MaterialCategoryRepository.class);
        when(categories.findByDeletedFalseOrderBySortOrderAscNameAsc()).thenAnswer(call -> em.createQuery(
                "from MaterialCategory c where c.deleted=false order by c.sortOrder,c.name", MaterialCategory.class).getResultList());
        when(categories.findById(any())).thenAnswer(call -> Optional.ofNullable(em.find(MaterialCategory.class, call.getArgument(0))));
        var colors = mock(ColorRepository.class); when(colors.findAll()).thenAnswer(call -> em.createQuery("from Color", Color.class).getResultList());
        var units = mock(UnitRepository.class); when(units.findAll()).thenAnswer(call -> em.createQuery("from Unit", Unit.class).getResultList());
        var tx = mock(TxSessionVars.class);
        goodsOwners = mock(OwnerVisibility.class);
        goodsService = transactional(new GoodsService(goods, categories, colors, units, null, tx, em,
                new CategoryDrivenCodeService(em), goodsOwners, current, new GoodsCostMasker(current), null));
        var importTarget = new GoodsImportService(goodsService, goods, null, categories, null, colors, null, units, em, current, null);
        ReflectionTestUtils.setField(importTarget, "identifierAvailability",
                new com.uten.imp.common.mastercode.MasterIdentifierAvailabilityService(em));
        ReflectionTestUtils.setField(importTarget, "writeAccess", (GoodsMasterWriteAccessPort) id -> {
            Goods value = em.find(Goods.class, id);
            if (value == null || value.isDeleted()) throw new IllegalStateException("goods not available");
        });
        var access = mock(MasterObjectAccess.class); when(access.readableLabelOwner(anyString())).thenReturn(owner -> true);
        history = transactional(new GoodsOperationHistoryService(em, new ObjectMapper(), current, tx,
                new MasterReferenceGuard(em, access), mock(OwnerVisibility.class), mock(BusinessEventPublisher.class)));
        ReflectionTestUtils.setField(importTarget, "operationHistory", history);
        importer = transactional(importTarget);
        inTx(() -> {
            em.createNativeQuery("INSERT INTO material_categories(id,code,name) VALUES(:id,:code,:name)")
                    .setParameter("id", categoryId).setParameter("code", "IC" + categoryId.toString().replace("-", ""))
                    .setParameter("name", categoryName()).executeUpdate();
            em.createNativeQuery("""
                    INSERT INTO goods(id,code,name,category_id,c_number,spec,price,name_en,name_en_source,code_sequence)
                    VALUES(:id,:code,'现有货品',:category,'111','保留规格',12.3400,'Learned English','LEARNED',(SELECT coalesce(max(code_sequence),0)+1 FROM goods))
                    """).setParameter("id", existingId).setParameter("code", existingCode).setParameter("category", categoryId).executeUpdate();
            em.createNativeQuery("UPDATE category_master_code_sequences SET last_seq=(SELECT max(code_sequence) FROM goods) WHERE master_type='GOODS'").executeUpdate();
            return null;
        });
    }

    @Test void mixedInsertFillAndReplacementUndoAndRedoRestoreTheExactBeforeAndAfter() throws Exception {
        byte[] file = workbook();
        var detected = inTx(() -> importer.detect(file));
        assertTrue(detected.errors().isEmpty(), detected.errors().toString());
        var result = inTx(() -> { provenance("/api/master/goods/import/commit", "POST"); return importer.commit(detected.planId(), file, "mixed.xlsx", Set.of("goods:2")); });
        assertEquals(2, result.importedCount()); assertEquals(1, result.createdCount());
        assertEquals(1, result.updatedCount()); assertEquals(1, result.filledCount());
        assertEquals("222", scalar("SELECT c_number FROM goods WHERE id=:id", existingId));
        assertEquals("客户新名", scalar("SELECT client_goods_name FROM goods WHERE id=:id", existingId));
        assertEquals("保留规格", scalar("SELECT spec FROM goods WHERE id=:id", existingId));
        assertEquals("Learned English", scalar("SELECT name_en FROM goods WHERE id=:id", existingId));
        assertEquals("LEARNED", scalar("SELECT name_en_source FROM goods WHERE id=:id", existingId));
        UUID newId = (UUID) em.createNativeQuery("SELECT id FROM goods WHERE code=:code").setParameter("code", newCode).getSingleResult();
        UUID operation = (UUID) em.createNativeQuery("SELECT id FROM goods_operation_history WHERE actor_id=:actor AND operation_type='GOODS_IMPORT'")
                .setParameter("actor", actor).getSingleResult();

        inTx(() -> { provenance("/api/master/goods/import/" + result.batchId(), "DELETE"); return importer.undo(result.batchId()); });

        assertEquals("111", scalar("SELECT c_number FROM goods WHERE id=:id", existingId));
        assertNull(scalar("SELECT client_goods_name FROM goods WHERE id=:id", existingId));
        assertEquals("false", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", existingId));
        assertEquals("true", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", newId));
        assertEquals("UNDONE", scalar("SELECT status FROM goods_import_batches WHERE id=:id", result.batchId()));
        inTx(() -> { provenance("/api/master/goods/history/" + operation + "/redo", "POST"); return history.redo(operation, 1); });
        assertEquals("222", scalar("SELECT c_number FROM goods WHERE id=:id", existingId));
        assertEquals("false", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", newId));
    }

    @Test void laterChangesBlockTheEntireMixedBatchUndoWithoutDeletingTheNewGoods() throws Exception {
        byte[] file = workbook();
        var detected = inTx(() -> importer.detect(file));
        var result = inTx(() -> { provenance("/api/master/goods/import/commit", "POST"); return importer.commit(detected.planId(), file, "mixed.xlsx", Set.of("goods:2")); });
        inTx(() -> {
            provenance("/api/master/goods/" + existingId, "PUT");
            em.createNativeQuery("UPDATE goods SET c_number='333',version=version+1 WHERE id=:id").setParameter("id", existingId).executeUpdate(); return null;
        });
        assertThrows(ApiException.class, () -> inTx(() -> { provenance("/api/master/goods/import/" + result.batchId(), "DELETE"); return importer.undo(result.batchId()); }));
        assertEquals("333", scalar("SELECT c_number FROM goods WHERE id=:id", existingId));
        assertEquals(1L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods WHERE code=:code AND NOT is_deleted").setParameter("code", newCode).getSingleResult()).longValue());
        assertEquals("IMPORTED", scalar("SELECT status FROM goods_import_batches WHERE id=:id", result.batchId()));
    }

    @Test void committedChangeAfterDetectionRejectsBeforeAnyNewGoodsOrBatchIsWritten() throws Exception {
        byte[] file = workbook();
        var detected = inTx(() -> importer.detect(file));
        inTx(() -> { em.createNativeQuery("UPDATE goods SET c_number='其他人补齐',version=version+1 WHERE id=:id").setParameter("id", existingId).executeUpdate(); return null; });
        assertThrows(ApiException.class, () -> inTx(() -> { provenance("/api/master/goods/import/commit", "POST"); return importer.commit(detected.planId(), file, "mixed.xlsx", Set.of("goods:2")); }));
        assertEquals(0L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods WHERE code=:code").setParameter("code", newCode).getSingleResult()).longValue());
        assertEquals(0L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods_import_batches WHERE created_by=:actor").setParameter("actor", actor).getSingleResult()).longValue());
    }

    @Test void successiveImportsOfTheSameGoodsHaveIndependentReceiptsAndCanUndoInOrder() throws Exception {
        byte[] firstFile = workbook();
        var firstPlan = inTx(() -> importer.detect(firstFile));
        var first = inTx(() -> { provenance("/api/master/goods/import/commit", "POST"); return importer.commit(firstPlan.planId(), firstFile, "first.xlsx", Set.of("goods:2")); });
        byte[] secondFile = workbook("333");
        var secondPlan = inTx(() -> importer.detect(secondFile));
        var second = inTx(() -> { provenance("/api/master/goods/import/commit", "POST"); return importer.commit(secondPlan.planId(), secondFile, "second.xlsx", Set.of("goods:2")); });
        assertNotEquals(scalar("SELECT operation_id::text FROM goods_import_batches WHERE id=:id", first.batchId()),
                scalar("SELECT operation_id::text FROM goods_import_batches WHERE id=:id", second.batchId()));
        inTx(() -> { provenance("/api/master/goods/import/" + second.batchId(), "DELETE"); return importer.undo(second.batchId()); });
        assertEquals("222", scalar("SELECT c_number FROM goods WHERE id=:id", existingId));
        assertEquals("IMPORTED", scalar("SELECT status FROM goods_import_batches WHERE id=:id", first.batchId()));
        assertEquals("UNDONE", scalar("SELECT status FROM goods_import_batches WHERE id=:id", second.batchId()));
        inTx(() -> { provenance("/api/master/goods/import/" + first.batchId(), "DELETE"); return importer.undo(first.batchId()); });
        assertEquals("111", scalar("SELECT c_number FROM goods WHERE id=:id", existingId));
        assertEquals("UNDONE", scalar("SELECT status FROM goods_import_batches WHERE id=:id", first.batchId()));
        assertEquals("UNDONE", scalar("SELECT status FROM goods_import_batches WHERE id=:id", second.batchId()));
    }

    @Test void reviewedCodeChangeKeepsUuidAndBothPermanentNumberReservations() throws Exception {
        byte[] file = identityWorkbook(newCode, existingId.toString());
        var detected = inTx(() -> importer.detect(file));
        assertTrue(detected.errors().isEmpty(), detected.errors().toString());
        assertEquals(List.of("code"), detected.reviewRows().getFirst().changes().stream()
                .map(GoodsImportReviewRow.Change::field).toList());

        var result = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(detected.planId(), file, "renumber.xlsx", Set.of("goods:2"));
        });

        assertEquals(1, result.updatedCount());
        assertEquals(0, result.createdCount());
        assertEquals(newCode, scalar("SELECT code FROM goods WHERE id=:id", existingId));
        assertEquals("111", scalar("SELECT c_number FROM goods WHERE id=:id", existingId));
        assertEquals(2L, ((Number) em.createNativeQuery("""
                SELECT count(*) FROM master_code_reservation_members
                WHERE master_domain='GOODS' AND entity_id=:id AND normalized_code IN (:old,:next)
                """).setParameter("id", existingId).setParameter("old", existingCode).setParameter("next", newCode)
                .getSingleResult()).longValue());
        assertEquals(2L, ((Number) em.createNativeQuery("""
                SELECT count(*) FROM business_identifier_reservation_members
                WHERE owner_domain='GOODS' AND entity_id=:id AND normalized_identifier IN (:old,:next)
                """).setParameter("id", existingId).setParameter("old", existingCode).setParameter("next", newCode)
                .getSingleResult()).longValue());

        // Code changes keep the existing controlled-version-restore contract;
        // the ordinary import undo cannot bypass current identifier safeguards.
        var undoError = assertThrows(ApiException.class, () -> inTx(() -> {
            provenance("/api/master/goods/import/" + result.batchId(), "DELETE");
            return importer.undo(result.batchId());
        }));
        assertTrue(undoError.getMessage().contains("编号变化"));
        assertEquals(newCode, scalar("SELECT code FROM goods WHERE id=:id", existingId));
        assertEquals("IMPORTED", scalar("SELECT status FROM goods_import_batches WHERE id=:id", result.batchId()));
    }

    @Test void exportedUuidWithBlankNumberDoesNotAllocateANewNumberOrGoods() throws Exception {
        byte[] file = identityWorkbook("", existingId.toString());
        var detected = inTx(() -> importer.detect(file));
        assertTrue(detected.errors().isEmpty(), detected.errors().toString());
        assertEquals(1, detected.unchangedRows());

        var result = inTx(() -> importer.commit(detected.planId(), file, "blank-code.xlsx"));

        assertNull(result.batchId());
        assertEquals(existingCode, scalar("SELECT code FROM goods WHERE id=:id", existingId));
        assertEquals(1L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods WHERE category_id=:id")
                .setParameter("id", categoryId).getSingleResult()).longValue());
    }

    @Test void removingTheNumberColumnStillKeepsTheExportedLocalIdentity() throws Exception {
        byte[] file = workbookWithoutNumber(existingId.toString());
        var detected = inTx(() -> importer.detect(file));
        assertTrue(detected.errors().isEmpty(), detected.errors().toString());
        assertEquals(1, detected.unchangedRows());

        var result = inTx(() -> importer.commit(detected.planId(), file, "removed-number.xlsx"));

        assertNull(result.batchId());
        assertEquals(existingCode, scalar("SELECT code FROM goods WHERE id=:id", existingId));
        assertEquals(1L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods WHERE category_id=:id")
                .setParameter("id", categoryId).getSingleResult()).longValue());
    }

    @Test void missingNumberAndForeignUuidsAllocateDistinctLocalGoodsAndRemainUndoable() throws Exception {
        UUID foreignId = UUID.randomUUID();
        byte[] file = workbookWithoutNumber(foreignId.toString(), foreignId.toString(), "");
        var detected = inTx(() -> importer.detect(file));
        assertTrue(detected.errors().isEmpty(), detected.errors().toString());
        assertEquals(3, detected.addedRows());
        var result = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(detected.planId(), file, "foreign-without-numbers.xlsx");
        });

        assertEquals(3, result.createdCount());
        List<UUID> createdIds = em.createQuery("select g.id from Goods g where g.category.id=:category and g.id<>:existing", UUID.class)
                .setParameter("category", categoryId).setParameter("existing", existingId).getResultList();
        assertEquals(3, createdIds.size());
        assertFalse(createdIds.contains(foreignId));
        assertEquals(4L, ((Number) em.createNativeQuery("SELECT count(DISTINCT code) FROM goods WHERE category_id=:id")
                .setParameter("id", categoryId).getSingleResult()).longValue());
        assertEquals(existingCode, scalar("SELECT code FROM goods WHERE id=:id", existingId));
        assertEquals("111", scalar("SELECT c_number FROM goods WHERE id=:id", existingId));
        assertThrows(ApiException.class, () -> inTx(() -> importer.commit(detected.planId(), file, "replayed.xlsx")));
        assertEquals(4L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods WHERE category_id=:id")
                .setParameter("id", categoryId).getSingleResult()).longValue());

        UUID operation = UUID.fromString(scalar("SELECT operation_id::text FROM goods_import_batches WHERE id=:id", result.batchId()));
        inTx(() -> {
            provenance("/api/master/goods/import/" + result.batchId(), "DELETE");
            return importer.undo(result.batchId());
        });
        assertEquals("false", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", existingId));
        for (UUID id : createdIds) assertEquals("true", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", id));
        assertEquals("UNDONE", scalar("SELECT status FROM goods_import_batches WHERE id=:id", result.batchId()));

        inTx(() -> {
            provenance("/api/master/goods/history/" + operation + "/redo", "POST");
            return history.redo(operation, 1);
        });
        for (UUID id : createdIds) assertEquals("false", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", id));
        assertEquals(existingCode, scalar("SELECT code FROM goods WHERE id=:id", existingId));
    }

    private byte[] workbookWithoutNumber(String... goodsIds) {
        var columns = List.of(
                new com.uten.imp.common.export.ExportColumn("name", "货品名称", "text"),
                new com.uten.imp.common.export.ExportColumn("category", "类别", "text"),
                new com.uten.imp.common.export.ExportColumn("id", "系统标识", "text"));
        List<Map<String, Object>> rows = Arrays.stream(goodsIds).map(id -> Map.<String, Object>of(
                "name", "现有货品", "category", categoryName(), "id", id)).toList();
        // Use raw SXSSF export bytes: the user's files must not require a resave.
        return new com.uten.imp.common.export.XlsxExportService().build(columns, rows);
    }

    @Test void newNumberWithoutUuidCreatesASameNameVariantWithoutChangingTheExistingGoods() throws Exception {
        byte[] file = identityWorkbook(newCode, "");
        var detected = inTx(() -> importer.detect(file));
        assertTrue(detected.errors().isEmpty(), detected.errors().toString());
        assertEquals(1, detected.addedRows());

        var result = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(detected.planId(), file, "new-variant.xlsx");
        });

        assertEquals(1, result.createdCount());
        UUID createdId = (UUID) em.createNativeQuery("SELECT id FROM goods WHERE code=:code")
                .setParameter("code", newCode).getSingleResult();
        assertNotEquals(existingId, createdId);
        assertEquals("现有货品", scalar("SELECT name FROM goods WHERE id=:id", createdId));
        assertEquals(existingCode, scalar("SELECT code FROM goods WHERE id=:id", existingId));
        assertEquals("111", scalar("SELECT c_number FROM goods WHERE id=:id", existingId));
    }

    @Test void historicalUuidWithChangedOrBlankNumberCreatesFreshGoodsWithoutChangingCurrentGoods() throws Exception {
        UUID historicalId = UUID.randomUUID();
        for (String code : List.of(newCode, "")) {
            byte[] file = identityWorkbook(code, historicalId.toString());
            var detected = inTx(() -> importer.detect(file));
            assertTrue(detected.errors().isEmpty(), detected.errors().toString());
            assertEquals(1, detected.addedRows());
            var result = inTx(() -> {
                provenance("/api/master/goods/import/commit", "POST");
                return importer.commit(detected.planId(), file, "historical-number.xlsx");
            });
            assertEquals(1, result.createdCount());
            assertEquals(0, result.updatedCount());
        }
        List<UUID> createdIds = em.createQuery("select g.id from Goods g where g.category.id=:category and g.id<>:existing", UUID.class)
                .setParameter("category", categoryId).setParameter("existing", existingId).getResultList();
        assertEquals(2, createdIds.size());
        assertFalse(createdIds.contains(historicalId));
        assertEquals(3L, ((Number) em.createNativeQuery("SELECT count(DISTINCT code) FROM goods WHERE category_id=:id")
                .setParameter("id", categoryId).getSingleResult()).longValue());
        assertEquals(existingCode, scalar("SELECT code FROM goods WHERE id=:id", existingId));
        assertEquals("111", scalar("SELECT c_number FROM goods WHERE id=:id", existingId));
    }

    @Test void identityUuidRestoreLeavesUnselectedConflictsUntouched() {
        UUID otherId = UUID.randomUUID();
        inTx(() -> {
            em.createNativeQuery("UPDATE goods SET is_deleted=true,deleted_at=now(),version=version+1 WHERE id=:id")
                    .setParameter("id", existingId).executeUpdate();
            em.createNativeQuery("""
                    INSERT INTO goods(id,code,name,category_id,code_sequence)
                    VALUES(:id,:code,'其他货品',:category,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))
                    """).setParameter("id", otherId).setParameter("code", newCode).setParameter("category", categoryId).executeUpdate();
            return null;
        });
        var columns = List.of(
                new com.uten.imp.common.export.ExportColumn("code", "编号", "text"),
                new com.uten.imp.common.export.ExportColumn("name", "货品名称", "text"),
                new com.uten.imp.common.export.ExportColumn("category", "类别", "text"),
                new com.uten.imp.common.export.ExportColumn("id", "系统标识", "text"));
        byte[] file = new com.uten.imp.common.export.XlsxExportService().build(columns, List.of(
                Map.of("code", existingCode, "name", "现有货品", "category", categoryName(), "id", existingId.toString()),
                Map.of("code", newCode, "name", "未选择的新名称", "category", categoryName(), "id", otherId.toString())));
        var detected = inTx(() -> importer.detect(file));
        assertTrue(detected.errors().isEmpty(), detected.errors().toString());
        assertEquals(1, detected.restorableRows());
        assertEquals(1, detected.conflictRows());

        var result = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(detected.planId(), file, "restore-and-ignore.xlsx", Set.of());
        });
        assertEquals(1, result.restoredCount());
        assertEquals(1, result.ignoredCount());
        assertEquals(0, result.createdCount());
        assertEquals("false", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", existingId));
        assertEquals("111", scalar("SELECT c_number FROM goods WHERE id=:id", existingId));
        assertEquals("其他货品", scalar("SELECT name FROM goods WHERE id=:id", otherId));
        inTx(() -> {
            provenance("/api/master/goods/import/" + result.batchId(), "DELETE");
            return importer.undo(result.batchId());
        });
        assertEquals("true", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", existingId));
        assertEquals("其他货品", scalar("SELECT name FROM goods WHERE id=:id", otherId));
    }

    @Test void normalSubsetThenCellCorrectionsCreateOnlyRemainingGoodsAndHaveIndependentUndo() throws Exception {
        byte[] file;
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品"); var header = sheet.createRow(0);
            String[] titles = {"编号", "名称", "类别", "来源", "价格", "规格"};
            for (int i = 0; i < titles.length; i++) header.createCell(i).setCellValue(titles[i]);
            String[][] values = {
                    {newCode, "正常新货品", categoryName(), "采购", "1.2345", "正常规格"},
                    {"DUP" + categoryId, "", categoryName(), "错误来源", "无效价格", "问题规格一"},
                    {"DUP" + categoryId, "待修复货品", categoryName(), "错误来源", "无效价格", "问题规格二"}};
            for (int n = 0; n < values.length; n++) {
                var row = sheet.createRow(n + 1);
                for (int i = 0; i < titles.length; i++) row.createCell(i).setCellValue(values[n][i]);
            }
            book.write(out); file = out.toByteArray();
        }
        byte[] originalBytes = file.clone();
        var firstPlan = inTx(() -> importer.detect(file));
        assertEquals(List.of(2), firstPlan.readyRowNums());
        assertEquals(List.of(3, 4), firstPlan.problemRows().stream().map(GoodsImportProblemRow::rowNum).toList());
        var first = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(firstPlan.planId(), file, "partial.xlsx");
        });
        assertEquals(1, first.createdCount());
        UUID normalId = (UUID) em.createNativeQuery("SELECT id FROM goods WHERE code=:code")
                .setParameter("code", newCode).getSingleResult();

        Map<Integer, Map<String, String>> corrections = Map.of(
                3, Map.of("code", "C" + categoryId, "name", "已修复一", "sourceType", "采购", "price", "12.3456"),
                4, Map.of("code", "", "name", "已修复二", "sourceType", "自制", "price", "7.8901"));
        var secondPlan = inTx(() -> importer.detect(file, Map.of(), Set.of(2), corrections));
        assertTrue(secondPlan.errors().isEmpty(), secondPlan.errors().toString());
        assertEquals(List.of(3, 4), secondPlan.readyRowNums());
        var second = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(secondPlan.planId(), file, "repaired.xlsx", Set.of(), Map.of(), Set.of(2), corrections);
        });
        assertEquals(2, second.createdCount());
        assertNotEquals(first.batchId(), second.batchId());
        assertEquals("1.2345", scalar("SELECT price::text FROM goods WHERE id=:id", normalId));
        assertEquals("正常规格", scalar("SELECT spec FROM goods WHERE id=:id", normalId));
        List<Goods> repaired = em.createQuery("from Goods g where g.category.id=:category and g.name in ('已修复一','已修复二') order by g.name", Goods.class)
                .setParameter("category", categoryId).getResultList();
        assertEquals(2, repaired.size());
        assertEquals(new java.math.BigDecimal("12.3456"), repaired.getFirst().getPrice());
        assertEquals("采购", repaired.getFirst().getSourceType());
        assertEquals("问题规格一", repaired.getFirst().getSpec());
        assertEquals(new java.math.BigDecimal("7.8901"), repaired.get(1).getPrice());
        assertEquals("自制", repaired.get(1).getSourceType());
        assertNotEquals(repaired.getFirst().getCode(), repaired.get(1).getCode());
        assertEquals(4L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods WHERE category_id=:id")
                .setParameter("id", categoryId).getSingleResult()).longValue());
        assertArrayEquals(originalBytes, file);
        assertThrows(ApiException.class, () -> inTx(() -> importer.commit(secondPlan.planId(), file,
                "replay.xlsx", Set.of(), Map.of(), Set.of(2), corrections)));
        inTx(() -> {
            provenance("/api/master/goods/import/" + second.batchId(), "DELETE");
            return importer.undo(second.batchId());
        });
        assertEquals("false", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", normalId));
        for (Goods value : repaired) assertEquals("true", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", value.getId()));
        inTx(() -> {
            provenance("/api/master/goods/import/" + first.batchId(), "DELETE");
            return importer.undo(first.batchId());
        });
        assertEquals("true", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", normalId));
        assertEquals("false", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", existingId));
    }

    @Test void deniedRestorationDoesNotPoisonTheNormalSubsetTransaction() throws Exception {
        UUID owner = UUID.randomUUID();
        inTx(() -> {
            em.createNativeQuery("""
                    INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                    VALUES(:id,:code,'范围测试','其他',
                      (SELECT id FROM departments WHERE NOT is_deleted ORDER BY id LIMIT 1),current_date,'active','regular')
                    """).setParameter("id", owner).setParameter("code", "IO" + owner.toString().replace("-", "")).executeUpdate();
            em.createNativeQuery("UPDATE goods SET owner_employee_id=:owner,is_deleted=true,deleted_at=now(),version=version+1 WHERE id=:id")
                    .setParameter("owner", owner).setParameter("id", existingId).executeUpdate();
            return null;
        });
        GoodsService target = (GoodsService) ((org.springframework.aop.framework.Advised) goodsService)
                .getTargetSource().getTarget();
        ReflectionTestUtils.setField(ReflectionTestUtils.getField(target, "goodsReadScopePolicy"), "ownerScopeEnabled", true);
        when(goodsOwners.evaluate("goods", "goods:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(owner), Set.of()));
        byte[] file = workbook();

        // Both services use real Spring transaction proxies. A caught denial in
        // the nested read-only guard must not mark this transaction rollback-only.
        var detected = inTx(() -> importer.detect(file));
        assertEquals(List.of(3), detected.readyRowNums());
        assertEquals(List.of(2), detected.problemRows().stream().map(GoodsImportProblemRow::rowNum).toList());
        assertEquals(0, detected.restorableRows());
        assertTrue(detected.reviewRows().isEmpty());
        assertTrue(detected.errors().stream().anyMatch(error -> error.message().contains("权限")));
        var result = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(detected.planId(), file, "denied-restore-with-normal.xlsx");
        });
        assertEquals(1, result.createdCount());
        assertEquals(0, result.restoredCount());
        assertEquals("true", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", existingId));
        assertEquals(1L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods WHERE code=:code AND NOT is_deleted")
                .setParameter("code", newCode).getSingleResult()).longValue());
    }

    @Test void reviewedRenameCannotTakeAnotherGoodsHistoricalNumberAtDetection() throws Exception {
        UUID otherId = UUID.randomUUID();
        String movedCode = "H" + UUID.randomUUID().toString().replace("-", "").toUpperCase(Locale.ROOT);
        inTx(() -> {
            em.createNativeQuery("""
                    INSERT INTO goods(id,code,name,category_id,code_sequence)
                    VALUES(:id,:code,'其他货品',:category,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))
                    """).setParameter("id", otherId).setParameter("code", newCode).setParameter("category", categoryId).executeUpdate();
            em.createNativeQuery("UPDATE goods SET code=:code,version=version+1 WHERE id=:id")
                    .setParameter("code", movedCode).setParameter("id", otherId).executeUpdate();
            return null;
        });
        byte[] file = identityWorkbook(newCode, existingId.toString());
        var detected = inTx(() -> importer.detect(file));
        assertEquals(1, detected.errors().size(), detected.errors().toString());
        assertEquals("编号", detected.errors().getFirst().column());
        assertEquals(2, detected.errors().getFirst().rowNum());
        assertEquals(0, detected.readyToImport());
        assertNull(detected.planId());

        assertEquals(existingCode, scalar("SELECT code FROM goods WHERE id=:id", existingId));
        assertEquals(movedCode, scalar("SELECT code FROM goods WHERE id=:id", otherId));
        assertEquals(0L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods_import_batches WHERE created_by=:actor")
                .setParameter("actor", actor).getSingleResult()).longValue());
    }

    @Test void deletedHistoricalNumberIsRejectedBeforeConfirmationAndCanBeCorrectedInPlace() throws Exception {
        UUID deletedId = UUID.randomUUID();
        inTx(() -> {
            // Old/imported identities deliberately have no complete nonuse proof.
            em.createNativeQuery("SELECT set_config('app.business_identifier_legacy_import','on',true)").getSingleResult();
            em.createNativeQuery("""
                    INSERT INTO goods(id,code,name,category_id,code_sequence,is_deleted)
                    VALUES(:id,:code,'历史已删货品',:category,(SELECT coalesce(max(code_sequence),0)+1 FROM goods),true)
                    """).setParameter("id", deletedId).setParameter("code", newCode)
                    .setParameter("category", categoryId).executeUpdate();
            return null;
        });
        byte[] file = identityWorkbook(newCode, "");
        var detected = inTx(() -> importer.detect(file));
        assertEquals(1, detected.errors().size(), detected.errors().toString());
        assertEquals("编号", detected.errors().getFirst().column());
        assertEquals(List.of(2), detected.problemRows().stream().map(GoodsImportProblemRow::rowNum).toList());
        assertNull(detected.planId());
        assertEquals(0, detected.readyToImport());

        Map<Integer, String> corrections = Map.of(2, "");
        var corrected = inTx(() -> importer.detect(file, corrections, Set.of()));
        assertTrue(corrected.errors().isEmpty(), corrected.errors().toString());
        var imported = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(corrected.planId(), file, "corrected-history.xlsx", Set.of(), corrections, Set.of());
        });
        assertEquals(1, imported.createdCount());
        assertEquals("true", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", deletedId));
        assertEquals(1L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods WHERE code=:code")
                .setParameter("code", newCode).getSingleResult()).longValue());
    }

    @Test void anotherMasterFamilyLifetimeReservationIsRejectedAtDetection() throws Exception {
        inTx(() -> {
            em.createNativeQuery("INSERT INTO colors(id,code,name,is_deleted) VALUES(:id,:code,'已删颜色',true)")
                    .setParameter("id", UUID.randomUUID()).setParameter("code", newCode).executeUpdate();
            return null;
        });
        byte[] file = identityWorkbook(newCode, "");
        var detected = inTx(() -> importer.detect(file));
        assertEquals(1, detected.errors().size(), detected.errors().toString());
        assertEquals("编号", detected.errors().getFirst().column());
        assertNull(detected.planId());
        assertEquals(0L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods_import_batches WHERE created_by=:actor")
                .setParameter("actor", actor).getSingleResult()).longValue());
    }

    @Test void usedDeletedNumberIsIsolatedWhileUnusedDeletedAndFreshNumbersCommitTogether() throws Exception {
        UUID usedId = UUID.randomUUID(), componentId = UUID.randomUUID();
        String freshCode = "F" + UUID.randomUUID().toString().replace("-", "").toUpperCase(Locale.ROOT);
        inTx(() -> {
            for (var row : Map.of(usedId, newCode, componentId, freshCode + "C").entrySet()) {
                em.createNativeQuery("""
                        INSERT INTO goods(id,code,name,category_id,code_sequence)
                        VALUES(:id,:code,'组装历史货品',:category,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))
                        """).setParameter("id", row.getKey()).setParameter("code", row.getValue())
                        .setParameter("category", categoryId).executeUpdate();
            }
            em.createNativeQuery("INSERT INTO goods_bom_items(goods_id,component_goods_id) VALUES(:id,:component)")
                    .setParameter("id", usedId).setParameter("component", componentId).executeUpdate();
            // Removing the visible BOM must not erase its lifetime usage fact.
            em.createNativeQuery("UPDATE goods_bom_items SET is_deleted=true WHERE goods_id=:id")
                    .setParameter("id", usedId).executeUpdate();
            em.createNativeQuery("UPDATE goods SET is_deleted=true WHERE id IN (:used,:unused)")
                    .setParameter("used", usedId).setParameter("unused", existingId).executeUpdate();
            em.createNativeQuery("UPDATE category_master_code_sequences SET last_seq=(SELECT max(code_sequence) FROM goods) WHERE master_type='GOODS'")
                    .executeUpdate();
            return null;
        });
        assertEquals("goods_bom_items.goods_id", scalar("SELECT first_source FROM goods_code_usage_facts WHERE goods_id=:id", usedId));
        byte[] file;
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品");
            String[] titles = {"编号", "名称", "类别", "系统标识"};
            var header = sheet.createRow(0);
            for (int i = 0; i < titles.length; i++) header.createCell(i).setCellValue(titles[i]);
            List<String> codes = List.of(newCode, existingCode, freshCode);
            for (int index = 0; index < codes.size(); index++) {
                var row = sheet.createRow(index + 1);
                row.createCell(0).setCellValue(codes.get(index));
                row.createCell(1).setCellValue("待导入货品" + index);
                row.createCell(2).setCellValue(categoryName());
            }
            book.write(out); file = out.toByteArray();
        }
        var detected = inTx(() -> importer.detect(file));
        assertEquals(List.of(2), detected.problemRows().stream().map(GoodsImportProblemRow::rowNum).toList());
        assertEquals(List.of(3, 4), detected.readyRowNums());
        assertEquals(2, detected.readyToImport());
        var imported = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(detected.planId(), file, "used-unused-fresh.xlsx");
        });
        assertEquals(2, imported.createdCount());
        assertEquals(0, imported.restoredCount());
        assertEquals("true", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", usedId));
        assertEquals("true", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", existingId));
        assertEquals(0L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods WHERE code=:code AND NOT is_deleted")
                .setParameter("code", newCode).getSingleResult()).longValue());
        for (String code : List.of(existingCode, freshCode)) {
            assertEquals(1L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods WHERE code=:code AND NOT is_deleted")
                    .setParameter("code", code).getSingleResult()).longValue());
        }
    }

    @Test void provenUnusedDeletedNumberPassesDetectionAndCommitsToANewIdentity() throws Exception {
        long originalSequence = ((Number) em.createNativeQuery("SELECT code_sequence FROM goods WHERE id=:id")
                .setParameter("id", existingId).getSingleResult()).longValue();
        String reusedCode = CategoryDrivenCodeService.format("9U", originalSequence, 6);
        inTx(() -> {
            em.createNativeQuery("UPDATE material_categories SET code_prefix='9U' WHERE id=:id")
                    .setParameter("id", categoryId).executeUpdate();
            em.createNativeQuery("UPDATE goods SET code=:code,is_deleted=true WHERE id=:id")
                    .setParameter("code", reusedCode).setParameter("id", existingId).executeUpdate();
            return null;
        });
        byte[] file = identityWorkbook(reusedCode, "");
        var detected = inTx(() -> importer.detect(file));
        assertTrue(detected.errors().isEmpty(), detected.errors().toString());
        assertEquals(1, detected.readyToImport());
        var imported = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(detected.planId(), file, "reuse-unused.xlsx");
        });
        assertEquals(1, imported.createdCount());
        assertEquals(0, imported.restoredCount());
        UUID createdId = (UUID) em.createNativeQuery("SELECT id FROM goods WHERE code=:code AND NOT is_deleted")
                .setParameter("code", reusedCode).getSingleResult();
        assertNotEquals(existingId, createdId);
        assertEquals("true", scalar("SELECT is_deleted::text FROM goods WHERE id=:id", existingId));
        assertEquals(1L, ((Number) em.createNativeQuery("SELECT count(*) FROM goods_code_reuse_releases WHERE old_goods_id=:id AND new_goods_id=:next")
                .setParameter("id", existingId).setParameter("next", createdId).getSingleResult()).longValue());
        long newSequence = ((Number) em.createNativeQuery("SELECT code_sequence FROM goods WHERE id=:id")
                .setParameter("id", createdId).getSingleResult()).longValue();
        assertNotEquals(originalSequence, newSequence, "A reused label must get a fresh stable identity counter");
        var identifiers = new com.uten.imp.common.mastercode.MasterIdentifierAvailabilityService(em);
        assertTrue(inTx(() -> identifiers.check(
                com.uten.imp.common.mastercode.MasterIdentifierAvailabilityService.Domain.GOODS,
                reusedCode, createdId, categoryId)).available(), "Keeping the reused label must not reclaim its old suffix counter");
        inTx(() -> {
            em.createNativeQuery("UPDATE goods SET is_deleted=true WHERE id=:id").setParameter("id", createdId).executeUpdate();
            return null;
        });
        assertTrue(inTx(() -> identifiers.checkForRestore(
                com.uten.imp.common.mastercode.MasterIdentifierAvailabilityService.Domain.GOODS,
                reusedCode, createdId, categoryId)).available(), "Restoring the original identity retains its fresh counter");
    }

    @Test void newChildCategoryStillChecksItsInheritedLongManagedSuffixBeforeConfirmation() throws Exception {
        long sequence = ((Number) em.createNativeQuery("SELECT code_sequence FROM goods WHERE id=:id")
                .setParameter("id", existingId).getSingleResult()).longValue();
        inTx(() -> {
            em.createNativeQuery("UPDATE material_categories SET code_prefix='9I' WHERE id=:id")
                    .setParameter("id", categoryId).executeUpdate();
            return null;
        });
        byte[] file = identityWorkbook(CategoryDrivenCodeService.format("9I", sequence, 6), "");
        Map<Integer, Map<String, String>> corrections = Map.of(2, Map.of("categoryPath", categoryName() + " / 新建子分类"));
        var detected = inTx(() -> importer.detect(file, Map.of(), Set.of(), corrections));
        assertEquals(1, detected.errors().size(), detected.errors().toString());
        assertEquals("编号", detected.errors().getFirst().column());
        assertTrue(detected.errors().getFirst().message().contains("数字序号"));
        assertNull(detected.planId());
        assertEquals(0L, ((Number) em.createNativeQuery("SELECT count(*) FROM material_categories WHERE name='新建子分类'")
                .getSingleResult()).longValue());
    }

    @Test void uuidUpdateIntoAWhollyNewCategoryChecksTheFallbackPrefixRatherThanItsOldCategory() throws Exception {
        UUID otherId = UUID.randomUUID();
        long occupied = inTx(() -> {
            em.createNativeQuery("UPDATE material_categories SET code_prefix='9N' WHERE id=:id")
                    .setParameter("id", categoryId).executeUpdate();
            em.createNativeQuery("""
                    INSERT INTO goods(id,code,name,category_id,code_sequence)
                    VALUES(:id,:code,'序号占用货品',:category,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))
                    """).setParameter("id", otherId).setParameter("code", newCode)
                    .setParameter("category", categoryId).executeUpdate();
            return ((Number) em.createNativeQuery("SELECT code_sequence FROM goods WHERE id=:id")
                    .setParameter("id", otherId).getSingleResult()).longValue();
        });
        byte[] file = identityWorkbook(CategoryDrivenCodeService.format("HP", occupied, 6), existingId.toString());
        Map<Integer, Map<String, String>> corrections = Map.of(2, Map.of("categoryPath", "全新根分类" + categoryId));
        var detected = inTx(() -> importer.detect(file, Map.of(), Set.of(), corrections, GoodsImportMode.UPDATE_ONLY));
        assertEquals(1, detected.errors().size(), detected.errors().toString());
        assertEquals("编号", detected.errors().getFirst().column());
        assertTrue(detected.errors().getFirst().message().contains("数字序号"));
        assertNull(detected.planId());
    }

    @Test void updateOnlyReviewedWorkbookNameIsAppliedAndOmittedValuesArePreserved() throws Exception {
        byte[] file;
        try (var book = new XSSFWorkbook(new java.io.ByteArrayInputStream(identityWorkbook(existingCode, existingId.toString())));
             var out = new ByteArrayOutputStream()) {
            book.getSheetAt(0).getRow(1).getCell(1).setCellValue("123");
            book.write(out); file = out.toByteArray();
        }
        var detected = inTx(() -> importer.detect(file, Map.of(), Set.of(), Map.of(), GoodsImportMode.UPDATE_ONLY));
        assertTrue(detected.errors().isEmpty(), detected.errors().toString());
        var nameChange = detected.reviewRows().getFirst().changes().stream()
                .filter(change -> "name".equals(change.field())).findFirst().orElseThrow();
        assertEquals("现有货品", nameChange.oldValue());
        assertEquals("123", nameChange.newValue());
        assertEquals("CONFLICT", nameChange.kind());
        var imported = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(detected.planId(), file, "update-name.xlsx", Set.of("goods:2"),
                    Map.of(), Set.of(), Map.of(), GoodsImportMode.UPDATE_ONLY);
        });
        assertEquals(1, imported.importedCount());
        assertEquals(1, imported.updatedCount());
        assertEquals(0, imported.ignoredCount());
        assertEquals("123", scalar("SELECT name FROM goods WHERE id=:id", existingId));
        assertEquals("保留规格", scalar("SELECT spec FROM goods WHERE id=:id", existingId));
        assertEquals("111", scalar("SELECT c_number FROM goods WHERE id=:id", existingId));
        assertEquals("12.3400", scalar("SELECT price::text FROM goods WHERE id=:id", existingId));
        assertEquals(existingCode, scalar("SELECT code FROM goods WHERE id=:id", existingId));
    }

    @Test void mixedImportAppliesReviewedNameChangeAndCreatesNewRowWithoutClearingOmittedFields() throws Exception {
        byte[] file;
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品");
            String[] titles = {"编号", "货品名称", "类别", "系统标识"};
            String[][] values = {
                    {existingCode, "456", categoryName(), existingId.toString()},
                    {newCode, "混合导入新货品", categoryName(), ""}};
            var header = sheet.createRow(0);
            for (int column = 0; column < titles.length; column++) header.createCell(column).setCellValue(titles[column]);
            for (int index = 0; index < values.length; index++) {
                var row = sheet.createRow(index + 1);
                for (int column = 0; column < titles.length; column++) row.createCell(column).setCellValue(values[index][column]);
            }
            book.write(out); file = out.toByteArray();
        }
        var detected = inTx(() -> importer.detect(file, Map.of(), Set.of(), Map.of(), GoodsImportMode.MIXED));
        assertTrue(detected.errors().isEmpty(), detected.errors().toString());
        assertEquals(1, detected.addedRows());
        assertEquals(1, detected.conflictRows());
        assertEquals(2, detected.readyToImport());
        assertEquals(1, detected.reviewRows().size());
        var reviewed = detected.reviewRows().getFirst();
        assertEquals(existingId, reviewed.goodsId());
        assertEquals("goods:2", reviewed.rowKey());
        assertEquals(1, reviewed.changes().size());
        var nameChange = reviewed.changes().getFirst();
        assertEquals("name", nameChange.field());
        assertEquals("现有货品", nameChange.oldValue());
        assertEquals("456", nameChange.newValue());
        assertEquals("CONFLICT", nameChange.kind());
        var imported = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(detected.planId(), file, "mixed-name-and-new.xlsx", Set.of(reviewed.rowKey()),
                    Map.of(), Set.of(), Map.of(), GoodsImportMode.MIXED);
        });
        assertEquals(2, imported.importedCount());
        assertEquals(1, imported.createdCount());
        assertEquals(1, imported.updatedCount());
        assertEquals(0, imported.filledCount());
        assertEquals(0, imported.ignoredCount());
        assertEquals("456", scalar("SELECT name FROM goods WHERE id=:id", existingId));
        assertEquals(existingCode, scalar("SELECT code FROM goods WHERE id=:id", existingId));
        assertEquals("保留规格", scalar("SELECT spec FROM goods WHERE id=:id", existingId));
        assertEquals("111", scalar("SELECT c_number FROM goods WHERE id=:id", existingId));
        assertEquals("12.3400", scalar("SELECT price::text FROM goods WHERE id=:id", existingId));
        assertEquals("Learned English", scalar("SELECT name_en FROM goods WHERE id=:id", existingId));
        UUID createdId = (UUID) em.createNativeQuery("SELECT id FROM goods WHERE code=:code AND NOT is_deleted")
                .setParameter("code", newCode).getSingleResult();
        assertNotEquals(existingId, createdId);
        assertEquals("混合导入新货品", scalar("SELECT name FROM goods WHERE id=:id", createdId));
    }

    @Test void numericCellTailsNormalizeAtTheBoundaryWhileExactLargeDecimalsSurviveReviewAndCommit() throws Exception {
        byte[] file;
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品");
            String[] titles = {"编号", "货品名称", "类别", "系统标识", "价格", "最小起订量", "订货倍数"};
            String[][] rows = {
                    {existingCode, "现有货品", categoryName(), existingId.toString(), "35.299999999999997", "0.30000000000000004", "1.0000000000000002"},
                    {newCode, "大额精确价格", categoryName(), "", "12345678901234.1234", "1", "0"}};
            var header = sheet.createRow(0);
            for (int column = 0; column < titles.length; column++) header.createCell(column).setCellValue(titles[column]);
            for (int index = 0; index < rows.length; index++) {
                var row = sheet.createRow(index + 1);
                for (int column = 0; column < titles.length; column++) {
                    var cell = row.createCell(column);
                    if (column >= 4) {
                        cell.setCellValue(0d);
                        cell.getCTCell().setV(rows[index][column]);
                    } else cell.setCellValue(rows[index][column]);
                }
            }
            book.write(out); file = out.toByteArray();
        }
        var detected = inTx(() -> importer.detect(file));
        assertTrue(detected.errors().isEmpty(), detected.errors().toString());
        assertEquals("35.3", detected.previewRows().getFirst().cells().get("price"));
        assertEquals("0.3", detected.previewRows().getFirst().cells().get("minOrderQty"));
        assertEquals("1", detected.previewRows().getFirst().cells().get("orderMultipleQty"));
        assertEquals("12345678901234.1234", detected.previewRows().get(1).cells().get("price"));
        var priceChange = detected.reviewRows().getFirst().changes().stream()
                .filter(change -> "price".equals(change.field())).findFirst().orElseThrow();
        var json = new ObjectMapper().readTree(new ObjectMapper().writeValueAsBytes(priceChange));
        assertTrue(json.get("oldValue").isTextual());
        assertTrue(json.get("newValue").isTextual());
        assertEquals("12.3400", json.get("oldValue").asText());
        assertEquals("35.3", json.get("newValue").asText());
        var imported = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(detected.planId(), file, "numeric-cell-boundary.xlsx", Set.of("goods:2"));
        });
        assertEquals(1, imported.updatedCount());
        assertEquals(1, imported.createdCount());
        assertEquals("35.3000", scalar("SELECT price::text FROM goods WHERE id=:id", existingId));
        assertEquals("0.3000", scalar("SELECT min_order_qty::text FROM goods WHERE id=:id", existingId));
        assertEquals("1.0000", scalar("SELECT order_multiple_qty::text FROM goods WHERE id=:id", existingId));
        assertEquals("12345678901234.1234", em.createNativeQuery("SELECT price::text FROM goods WHERE code=:code")
                .setParameter("code", newCode).getSingleResult());
    }

    @Test void managedCategoryMoveChecksTheRenderedTargetLabelBeforeConfirmationWithoutReservingAnything() throws Exception {
        UUID targetCategory = UUID.randomUUID(), holderId = UUID.randomUUID();
        long sequence = ((Number) em.createNativeQuery("SELECT code_sequence FROM goods WHERE id=:id")
                .setParameter("id", existingId).getSingleResult()).longValue();
        String oldCode = CategoryDrivenCodeService.format("HP", sequence, 6);
        String targetCode = CategoryDrivenCodeService.format("9M", sequence, 6);
        String targetName = "目标分类" + targetCategory;
        inTx(() -> {
            em.createNativeQuery("INSERT INTO material_categories(id,code,name,code_prefix) VALUES(:id,:code,:name,'9M')")
                    .setParameter("id", targetCategory).setParameter("code", "MC" + targetCategory.toString().replace("-", ""))
                    .setParameter("name", targetName).executeUpdate();
            em.createNativeQuery("UPDATE goods SET code=:code,code_managed=true WHERE id=:id")
                    .setParameter("code", oldCode).setParameter("id", existingId).executeUpdate();
            em.createNativeQuery("""
                    INSERT INTO goods(id,code,name,category_id,code_sequence)
                    VALUES(:id,:code,'历史编号所有者',:category,(SELECT coalesce(max(code_sequence),0)+1 FROM goods))
                    """).setParameter("id", holderId).setParameter("code", targetCode)
                    .setParameter("category", categoryId).executeUpdate();
            em.createNativeQuery("UPDATE goods SET code=:code WHERE id=:id")
                    .setParameter("code", newCode).setParameter("id", holderId).executeUpdate();
            return null;
        });
        long beforeCounter = ((Number) em.createNativeQuery("SELECT last_seq FROM category_master_code_sequences WHERE master_type='GOODS'")
                .getSingleResult()).longValue();
        long beforeClaims = ((Number) em.createNativeQuery("SELECT count(*) FROM business_identifier_reservation_members")
                .getSingleResult()).longValue();
        byte[] file = identityWorkbook(oldCode, existingId.toString());
        var detected = inTx(() -> importer.detect(file, Map.of(), Set.of(),
                Map.of(2, Map.of("categoryPath", targetName)), GoodsImportMode.UPDATE_ONLY));
        assertEquals(1, detected.errors().size(), detected.errors().toString());
        assertEquals("编号", detected.errors().getFirst().column());
        assertTrue(detected.errors().getFirst().message().contains(targetCode));
        assertNull(detected.planId());
        assertEquals(oldCode, scalar("SELECT code FROM goods WHERE id=:id", existingId));
        assertEquals(beforeCounter, ((Number) em.createNativeQuery("SELECT last_seq FROM category_master_code_sequences WHERE master_type='GOODS'")
                .getSingleResult()).longValue());
        assertEquals(beforeClaims, ((Number) em.createNativeQuery("SELECT count(*) FROM business_identifier_reservation_members")
                .getSingleResult()).longValue());
    }

    @Test void pureNumericManagedCategoryMoveKeepsTheLabelAndStableCounter() throws Exception {
        UUID targetCategory = UUID.randomUUID();
        String numericCode = "2801511001", targetName = "数字编号目标" + targetCategory;
        long sequence = ((Number) em.createNativeQuery("SELECT code_sequence FROM goods WHERE id=:id")
                .setParameter("id", existingId).getSingleResult()).longValue();
        inTx(() -> {
            em.createNativeQuery("INSERT INTO material_categories(id,code,name,code_prefix) VALUES(:id,:code,:name,'9P')")
                    .setParameter("id", targetCategory).setParameter("code", "NC" + targetCategory.toString().replace("-", ""))
                    .setParameter("name", targetName).executeUpdate();
            em.createNativeQuery("UPDATE goods SET code=:code,code_managed=true WHERE id=:id")
                    .setParameter("code", numericCode).setParameter("id", existingId).executeUpdate();
            return null;
        });
        byte[] file = identityWorkbook(numericCode, existingId.toString());
        Map<Integer, Map<String, String>> corrections = Map.of(2, Map.of("categoryPath", targetName));
        var detected = inTx(() -> importer.detect(file, Map.of(), Set.of(), corrections, GoodsImportMode.UPDATE_ONLY));
        assertTrue(detected.errors().isEmpty(), detected.errors().toString());
        var imported = inTx(() -> {
            provenance("/api/master/goods/import/commit", "POST");
            return importer.commit(detected.planId(), file, "numeric-category-move.xlsx", Set.of("goods:2"),
                    Map.of(), Set.of(), corrections, GoodsImportMode.UPDATE_ONLY);
        });
        assertEquals(1, imported.updatedCount());
        assertEquals(numericCode, scalar("SELECT code FROM goods WHERE id=:id", existingId));
        assertEquals(targetCategory.toString(), scalar("SELECT category_id::text FROM goods WHERE id=:id", existingId));
        assertEquals(sequence, ((Number) em.createNativeQuery("SELECT code_sequence FROM goods WHERE id=:id")
                .setParameter("id", existingId).getSingleResult()).longValue());
    }

    private byte[] identityWorkbook(String code, String goodsId) throws Exception {
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品");
            var header = sheet.createRow(0); var row = sheet.createRow(1);
            String[] titles = {"编号", "名称", "类别", "系统标识"};
            String[] values = {code, "现有货品", categoryName(), goodsId};
            for (int i = 0; i < titles.length; i++) {
                header.createCell(i).setCellValue(titles[i]); row.createCell(i).setCellValue(values[i]);
            }
            book.write(out); return out.toByteArray();
        }
    }

    @Test void salesImportCanUpdateCustomerModelWithoutGeneralGoodsEdit() throws Exception {
        authorize("goods:view","goods:import","goods:sales:edit");
        byte[] file=fieldWorkbook("客户型号","333");
        var plan=inTx(()->importer.detect(file));
        inTx(()-> { provenance("/api/master/goods/import/commit","POST"); return importer.commit(plan.planId(),file,"sales-only.xlsx",Set.of("goods:2")); });
        assertEquals("333",scalar("SELECT c_number FROM goods WHERE id=:id",existingId));
        assertEquals("保留规格",scalar("SELECT spec FROM goods WHERE id=:id",existingId));
    }
    @Test void purchaseImportCanUpdateOrderPolicyWithoutGeneralGoodsEdit() throws Exception {
        authorize("goods:view","goods:import","goods:purchase:edit");
        byte[] file=fieldWorkbook("最小起订量","25");
        var plan=inTx(()->importer.detect(file));
        inTx(()-> { provenance("/api/master/goods/import/commit","POST"); return importer.commit(plan.planId(),file,"purchase-only.xlsx",Set.of()); });
        assertEquals(new java.math.BigDecimal("25"),new java.math.BigDecimal(scalar("SELECT min_order_qty FROM goods WHERE id=:id",existingId)).stripTrailingZeros());
        assertEquals("111",scalar("SELECT c_number FROM goods WHERE id=:id",existingId));
    }
    @Test void importCannotCrossFieldGroupsAndRejectedBatchesLeaveNoWrites() throws Exception {
        for(String permission:List.of("goods:sales:edit","goods:purchase:edit","goods:edit")) {
            authorize("goods:view","goods:import",permission);
            String field=permission.equals("goods:purchase:edit")?"客户型号":permission.equals("goods:edit")?"最小起订量":"规格";
            byte[] file=fieldWorkbook(field,field.equals("最小起订量")?"25":"越权变更");
            var plan=inTx(()->importer.detect(file));
            Set<String> replace=plan.conflictRows()>0?Set.of("goods:2"):Set.of();
            assertThrows(ApiException.class,()->inTx(()-> { provenance("/api/master/goods/import/commit","POST"); return importer.commit(plan.planId(),file,"denied.xlsx",replace); }));
        }
        assertEquals("111",scalar("SELECT c_number FROM goods WHERE id=:id",existingId));
        assertEquals("保留规格",scalar("SELECT spec FROM goods WHERE id=:id",existingId));
        assertEquals(0L,((Number)em.createNativeQuery("SELECT count(*) FROM goods_import_batches WHERE created_by=:actor").setParameter("actor",actor).getSingleResult()).longValue());
    }
    @Test void restoringImportedGoodsPreservesInvisibleHistoricalCostsAndPrices() throws Exception {
        inTx(()-> { em.createNativeQuery("UPDATE goods SET source_e=42.1234,g_total=17.0000,is_deleted=true,deleted_at=now(),version=version+1 WHERE id=:id").setParameter("id",existingId).executeUpdate();return null; });
        authorize("goods:view","goods:import","goods:edit","goods:sales:edit","goods:purchase:edit");
        byte[] file=fieldWorkbook("客户型号","111");
        var plan=inTx(()->importer.detect(file));
        assertTrue(plan.errors().isEmpty(),plan.errors().toString());
        var result=inTx(()->{provenance("/api/master/goods/import/commit","POST");return importer.commit(plan.planId(),file,"restore-costs.xlsx",Set.of());});
        assertEquals(1,result.restoredCount());
        assertEquals("42.1234",scalar("SELECT source_e::text FROM goods WHERE id=:id",existingId));
        assertEquals("17.0000",scalar("SELECT g_total::text FROM goods WHERE id=:id",existingId));
        assertEquals("12.3400",scalar("SELECT price::text FROM goods WHERE id=:id",existingId));
    }
    @Test void restoringDeletedGoodsPreservesMissingColumnsThroughUndoAndRedo() throws Exception {
        verifyRestoredWorkbookPreservesUnprovidedValues(false);
    }
    @Test void restoringDeletedGoodsPreservesBlankColumnsThroughUndoAndRedo() throws Exception {
        verifyRestoredWorkbookPreservesUnprovidedValues(true);
    }
    private void verifyRestoredWorkbookPreservesUnprovidedValues(boolean blankColumns) throws Exception {
        inTx(() -> {
            em.createNativeQuery("""
                    UPDATE goods SET short_name='保留简称',model='保留型号',series='保留系列',
                      stock_place='A-01',material='ABS',thickness=2.5000,m_weight=3.2500,
                      pack='保留包装',pieces=12,paper='保留备注',rear_insert_code='MR-7',
                      source_type='采购',min_order_qty=25.1250,order_multiple_qty=5,
                      client_goods_name='保留客户名称',status='禁用',source_e=42.1234,g_total=17,
                      color_legacy_id=991001,unit_legacy_id=991002,mould_legacy_id=991003,
                      client_legacy_id=991004,vend_legacy_id=991005,vend2_legacy_id=991006,
                      thickness_unit_legacy_id=991007,m_weight_unit_legacy_id=991008,
                      is_deleted=true,deleted_at=now(),version=version+1 WHERE id=:id
                    """).setParameter("id",existingId).executeUpdate();
            return null;
        });
        // Restoration alone does not grant sales, procurement, status or price edits.
        authorize("goods:view","goods:import","goods:import:undo","goods:edit");
        String before=preservedRestoreFacts();
        byte[] file=restorePreservationWorkbook(blankColumns);
        var plan=inTx(() -> importer.detect(file));
        assertTrue(plan.errors().isEmpty(),plan.errors().toString());
        assertEquals(1,plan.restorableRows());
        var result=inTx(() -> {
            provenance("/api/master/goods/import/commit","POST");
            return importer.commit(plan.planId(),file,"restore-preserve.xlsx",Set.of());
        });
        assertEquals(1,result.restoredCount());
        assertEquals(before,preservedRestoreFacts());
        assertEquals("false",scalar("SELECT is_deleted::text FROM goods WHERE id=:id",existingId));
        UUID operation=UUID.fromString(scalar("SELECT operation_id::text FROM goods_import_batches WHERE id=:id",result.batchId()));
        inTx(() -> {
            provenance("/api/master/goods/import/"+result.batchId(),"DELETE");
            return importer.undo(result.batchId());
        });
        assertEquals(before,preservedRestoreFacts());
        assertEquals("true",scalar("SELECT is_deleted::text FROM goods WHERE id=:id",existingId));
        inTx(() -> {
            provenance("/api/master/goods/history/"+operation+"/redo","POST");
            return history.redo(operation,1);
        });
        assertEquals(before,preservedRestoreFacts());
        assertEquals("false",scalar("SELECT is_deleted::text FROM goods WHERE id=:id",existingId));
    }
    private String preservedRestoreFacts() {
        return scalar("""
                SELECT jsonb_build_array(code,name,short_name,model,spec,series,stock_place,material,
                  thickness,m_weight,pack,pieces,paper,rear_insert_code,source_type,min_order_qty,
                  order_multiple_qty,c_number,client_goods_name,name_en,name_en_source,
                  color_id,color_legacy_id,unit_id,unit_legacy_id,mould_id,mould_legacy_id,
                  client_id,client_legacy_id,default_supplier_id,vend_legacy_id,
                  secondary_supplier_id,vend2_legacy_id,thickness_unit_id,thickness_unit_legacy_id,
                  m_weight_unit_id,m_weight_unit_legacy_id,status,price,source_e,g_total)::text
                FROM goods WHERE id=:id
                """,existingId);
    }
    private byte[] restorePreservationWorkbook(boolean blankColumns) throws Exception {
        try(var book=new XSSFWorkbook();var out=new ByteArrayOutputStream()) {
            var sheet=book.createSheet("货品");var header=sheet.createRow(0);var row=sheet.createRow(1);
            var titles=new ArrayList<>(List.of("编号","名称","类别"));
            if(blankColumns) titles.addAll(List.of("客户型号","客户货品名称","英文名称","系列","型号",
                    "规格","材质","后模镶件编号","备注","来源","价格","最小起订量","订货倍数","状态","主颜色","单位"));
            String[] required={existingCode,"现有货品",categoryName()};
            for(int i=0;i<titles.size();i++) {
                header.createCell(i).setCellValue(titles.get(i));
                row.createCell(i).setCellValue(i<required.length?required[i]:"  \t  ");
            }
            // 恢复只认系统标识：核对文件必须携带被恢复货品的 UUID。
            header.createCell(titles.size()).setCellValue("系统标识");
            row.createCell(titles.size()).setCellValue(existingId.toString());
            book.write(out);return out.toByteArray();
        }
    }
    private void authorize(String... permissions) {
        var codes=Set.of(permissions);
        var principal=new AuthUser(actor,UUID.randomUUID(),"import-field-test",codes,false,true,false);
        when(current.get()).thenReturn(Optional.of(principal));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(principal,"n/a",principal.getAuthorities()));
    }
    private byte[] fieldWorkbook(String field,String value) throws Exception {
        try(var book=new XSSFWorkbook();var out=new ByteArrayOutputStream()) {
            var sheet=book.createSheet("货品");var header=sheet.createRow(0);var row=sheet.createRow(1);
            String[] titles={"编号","名称","类别",field,"系统标识"},values={existingCode,"现有货品",categoryName(),value,existingId.toString()};
            for(int i=0;i<titles.length;i++) {header.createCell(i).setCellValue(titles[i]);row.createCell(i).setCellValue(values[i]);}
            book.write(out);return out.toByteArray();
        }
    }
    private String categoryName() { return "导入核对" + categoryId; }
    private byte[] workbook() throws Exception { return workbook("222"); }
    private byte[] workbook(String customerModel) throws Exception {
        try (var book = new XSSFWorkbook(); var out = new ByteArrayOutputStream()) {
            var sheet = book.createSheet("货品"); var header = sheet.createRow(0);
            String[] titles = {"编号", "名称", "类别", "客户型号", "客户品名", "规格", "系统标识"};
            for (int n = 0; n < titles.length; n++) header.createCell(n).setCellValue(titles[n]);
            String[][] values = {{existingCode, "现有货品", categoryName(), customerModel, "客户新名", "", existingId.toString()},
                    {newCode, "新货品", categoryName(), "新客户型号", "", "", ""}};
            for (int n = 0; n < values.length; n++) { var row = sheet.createRow(n + 1); for (int c = 0; c < titles.length; c++) row.createCell(c).setCellValue(values[n][c]); }
            book.write(out); return out.toByteArray();
        }
    }
    private String scalar(String sql, UUID id) { Object value = em.createNativeQuery(sql).setParameter("id", id).getSingleResult(); return value == null ? null : value.toString(); }
    private void provenance(String path, String method) {
        em.createNativeQuery("SELECT set_config('app.actor_id',:actor,true),set_config('app.audit_request_id',:request,true),set_config('app.audit_request_path',:path,true),set_config('app.audit_request_method',:method,true)")
                .setParameter("actor", actor.toString()).setParameter("request", UUID.randomUUID().toString()).setParameter("path", path).setParameter("method", method).getSingleResult();
        em.createNativeQuery("SELECT fn_begin_goods_history_request()").getSingleResult();
    }
    private <T> T inTx(Supplier<T> action) {
        return new TransactionTemplate(transactions).execute(status -> { T result = action.get(); em.flush(); return result; });
    }
    @SuppressWarnings("unchecked")
    private static <T> T transactional(T target) {
        var proxy = new ProxyFactory(target); proxy.setProxyTargetClass(true);
        var advice = new TransactionInterceptor();
        advice.setTransactionManager(transactions);
        advice.setTransactionAttributeSource(new AnnotationTransactionAttributeSource());
        proxy.addAdvice(advice);
        return (T) proxy.getProxy();
    }
}
