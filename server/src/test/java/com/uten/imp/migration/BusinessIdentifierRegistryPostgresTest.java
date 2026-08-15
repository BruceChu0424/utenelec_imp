package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.MethodOrderer;
import org.junit.jupiter.api.Order;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestMethodOrder;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/** PostgreSQL 16 non-empty upgrade, legacy-conflict and allocator concurrency proof. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class BusinessIdentifierRegistryPostgresTest {

    private static final long VISITOR_ACCOUNT_LOCK_NAMESPACE = 0x5554454E5649534CL;

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static UUID legacyQuoteId;
    private static UUID legacyOrderId;
    private static UUID legacyProductionPlanId;
    private static UUID legacyProductionPlanItemId;
    private static UUID legacyProductionPackageId;
    private static UUID legacyProductionGoodsId;
    private static UUID legacyProductionUnitId;
    private static UUID legacyExecutionSegmentId;
    private static int migrationsExecuted;

    @BeforeAll
    static void migrateNonEmptyDatabase() throws Exception {
        POSTGRES.start();
        flyway("278").migrate();
        legacyQuoteId = UUID.randomUUID();
        legacyOrderId = UUID.randomUUID();
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            statement.executeUpdate("""
                    INSERT INTO colors (id, legacy_id, code, name, status, is_deleted)
                    VALUES (gen_random_uuid(), 979001, 'GLOBAL-DUP', 'legacy color', '使用', false),
                           (gen_random_uuid(), 979002, 'YS000999', 'counter seed', '使用', false)
                    """);
            statement.executeUpdate("""
                    INSERT INTO units (id, legacy_id, code, name, status, is_deleted)
                    VALUES (gen_random_uuid(), 979003, ' global-dup ', 'legacy unit', '使用', false)
                    """);
            statement.executeUpdate("""
                    INSERT INTO material_categories (
                        id, legacy_id, code, name, code_prefix, is_deleted)
                    VALUES (gen_random_uuid(), 979004, 'V279-CATEGORY',
                            'legacy prefix conflict', 'XD', false)
                    """);
            statement.executeUpdate("""
                    INSERT INTO visitor_accounts (
                        id, phone_enc, phone_hash, name, visitor_no, status)
                    VALUES (gen_random_uuid(), 'cipher', 'v279-phone-hash',
                            'legacy visitor', 'V00000007', 'active')
                    """);
        }
        try (Connection connection = connection()) {
            try (PreparedStatement quote = connection.prepareStatement("""
                    INSERT INTO sales_quotes (id, legacy_id, bill_no, bill_date, status)
                    VALUES (?, 979005, 'XD26070001', DATE '2026-07-01', 0)
                    """)) {
                quote.setObject(1, legacyQuoteId);
                quote.executeUpdate();
            }
            try (PreparedStatement order = connection.prepareStatement("""
                    INSERT INTO purchase_orders (id, legacy_id, bill_no, bill_date, status)
                    VALUES (?, 979006, 'XD26070001', DATE '2026-07-01', 0)
                    """)) {
                order.setObject(1, legacyOrderId);
                order.executeUpdate();
            }
        }
        try (Connection connection = connection()) {
            seedLegacyProductionIdentifiers(connection);
        }
        migrationsExecuted = flyway("279").migrate().migrationsExecuted;
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    @Order(1)
    void upgradePreservesHistoricalValuesAndRecordsEveryDuplicateMember()
            throws Exception {
        assertEquals(1, migrationsExecuted);
        try (Connection connection = connection()) {
            assertEquals("XD26070001", text(connection,
                    "SELECT bill_no FROM sales_quotes WHERE id=?", legacyQuoteId));
            assertEquals("XD26070001", text(connection,
                    "SELECT bill_no FROM purchase_orders WHERE id=?", legacyOrderId));
            assertEquals(2, scalar(connection, """
                    SELECT count(*) FROM business_identifier_reservation_members
                    WHERE normalized_identifier='XD26070001'
                    """));
            assertEquals(2, scalar(connection, """
                    SELECT count(*) FROM business_identifier_reservation_members
                    WHERE normalized_identifier='GLOBAL-DUP'
                    """));
            assertTrue(scalar(connection, """
                    SELECT count(*) FROM business_identifier_conflicts
                    WHERE conflict_kind='IDENTIFIER_DUPLICATE'
                      AND normalized_value IN ('XD26070001','GLOBAL-DUP')
                    """) >= 2);
            assertTrue(scalar(connection, """
                    SELECT count(*) FROM business_identifier_conflicts
                    WHERE conflict_kind='PREFIX_DUPLICATE'
                      AND normalized_value='XD'
                    """) >= 1);
            assertEquals(1, scalar(connection, """
                    SELECT count(*) FROM business_identifier_reservation_members
                    WHERE normalized_identifier='V279-PLAN-PRODUCT'
                      AND owner_domain='PRODUCTION_PLAN_ITEM'
                      AND entity_id='%s'
                    """.formatted(legacyProductionPlanId)));
            assertEquals(1, scalar(connection, """
                    SELECT count(*) FROM business_identifier_reservation_members
                    WHERE normalized_identifier='ZX00000013'
                      AND owner_domain='PRODUCTION_EXECUTION_SEGMENT'
                      AND entity_id='%s'
                    """.formatted(legacyExecutionSegmentId)));
        }
    }

    @Test
    @Order(2)
    void migrationSeedsMasterAndVisitorCountersFromHistoricalMaximum()
            throws Exception {
        try (Connection connection = connection()) {
            assertEquals(999, scalar(connection,
                    "SELECT last_seq FROM master_code_sequences WHERE prefix='YS'"));
            assertEquals(7, scalar(connection,
                    "SELECT last_seq FROM master_code_sequences WHERE prefix='V'"));
            assertEquals(13, scalar(connection,
                    "SELECT last_seq FROM master_code_sequences WHERE prefix='ZX'"));
            assertEquals(8, scalar(connection, """
                    UPDATE master_code_sequences
                    SET last_seq = last_seq + 1
                    WHERE prefix='V'
                    RETURNING last_seq
                    """));
        }
    }

    @Test
    @Order(3)
    void canonicalDirectSqlUsesDefaultAndStockDiscriminatorMappingsWhileBypassesFailClosed()
            throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            assertEquals(1, statement.executeUpdate("""
                    INSERT INTO sales_quotes (id, bill_no, bill_date, status)
                    VALUES (gen_random_uuid(), 'XB20260814000011', DATE '2026-08-14', 0)
                    """));
            assertEquals(1, statement.executeUpdate("""
                    INSERT INTO stock_documents (id, doc_type, bill_no, bill_date, status)
                    VALUES (gen_random_uuid(), 'OTHER_IN', 'QR20260814000012',
                            DATE '2026-08-14', 0)
                    """));
            assertEquals(1, statement.executeUpdate("""
                    INSERT INTO visitor_accounts (
                        id, phone_enc, phone_hash, name, visitor_no, status)
                    VALUES (gen_random_uuid(), 'cipher', 'v279-canonical-visitor',
                            'canonical visitor', 'V00000009', 'active')
                    """));
            assertEquals(1, scalar(connection, """
                    SELECT count(*) FROM business_identifier_reservation_members
                    WHERE normalized_identifier='XB20260814000011'
                      AND owner_domain='SALES_QUOTE'
                    """));
            assertEquals(1, scalar(connection, """
                    SELECT count(*) FROM business_identifier_reservation_members
                    WHERE normalized_identifier='QR20260814000012'
                      AND owner_domain='STOCK_OTHER_IN'
                    """));
            assertEquals(11, scalar(connection, """
                    SELECT last_seq FROM business_document_sequences
                    WHERE namespace_key='SALES_QUOTE'
                      AND sequence_date=DATE '2026-08-14'
                    """));
            assertEquals(12, scalar(connection, """
                    SELECT last_seq FROM business_document_sequences
                    WHERE namespace_key='STOCK_OTHER_IN'
                      AND sequence_date=DATE '2026-08-14'
                    """));
            assertEquals(9, scalar(connection,
                    "SELECT last_seq FROM master_code_sequences WHERE prefix='V'"));
            assertEquals(1, statement.executeUpdate("""
                    UPDATE material_categories
                    SET code_prefix='LZ'
                    WHERE legacy_id=979004
                    """));
        }
        assertSqlState("23505", """
                INSERT INTO colors (id, code, name, status, is_deleted)
                VALUES (gen_random_uuid(), ' global-dup ', 'online duplicate', '使用', false)
                """);
        assertSqlState("23505", """
                INSERT INTO colors (id, legacy_id, code, name, status, is_deleted)
                VALUES (gen_random_uuid(), 979101, 'V00000007',
                        'legacy-id must not bypass', '使用', false)
                """);
        assertSqlState("23505", """
                INSERT INTO units (id, legacy_id, code, name, status, is_deleted)
                VALUES (gen_random_uuid(), 979003, 'GLOBAL-DUP',
                        'reused legacy identity must not bypass', '使用', false)
                """);
        assertSqlState("23505", """
                INSERT INTO material_categories (id, code, name, code_prefix, is_deleted)
                VALUES (gen_random_uuid(), 'V279-NEW-CATEGORY', 'online prefix', 'XD', false)
                """);
        assertSqlState("23505", """
                INSERT INTO material_categories (
                    id, legacy_id, code, name, code_prefix, is_deleted)
                VALUES (gen_random_uuid(), 979102, 'V279-LEGACY-ID-CATEGORY',
                        'legacy-id prefix bypass', 'XD', false)
                """);
        assertSqlState("23505", """
                UPDATE material_categories
                SET code_prefix='XD'
                WHERE legacy_id=979004
                """);
        assertSqlState("23505", """
                INSERT INTO business_identifier_namespaces (
                    namespace_key, identifier_family, fixed_prefix,
                    source_table, identifier_column)
                VALUES ('TEST_DUP_PREFIX', 'SYSTEM', 'XD',
                        'test_duplicate_identifier', 'number')
                """);
        assertSqlState("23514", """
                INSERT INTO sales_quotes (id, bill_no, bill_date, status)
                VALUES (gen_random_uuid(), 'ONLINE-BYPASS-1', CURRENT_DATE, 0)
                """);
        assertSqlState("23514", """
                INSERT INTO sales_quotes (id, legacy_id, bill_no, bill_date, status)
                VALUES (gen_random_uuid(), 979103,
                        'LEGACY-ID-IS-NOT-A-MODE', CURRENT_DATE, 0)
                """);
        assertSqlState("23514", """
                INSERT INTO sales_quotes (id, bill_no, bill_date, status)
                VALUES (gen_random_uuid(), 'xb20260814000013', CURRENT_DATE, 0)
                """);
        assertSqlState("23514", """
                INSERT INTO sales_quotes (id, bill_no, bill_date, status)
                VALUES (gen_random_uuid(), ' XB20260814000014 ', CURRENT_DATE, 0)
                """);
        assertSqlState("23514", """
                INSERT INTO visitor_accounts (
                    id, phone_enc, phone_hash, name, visitor_no, status)
                VALUES (gen_random_uuid(), 'cipher', 'v279-zero-visitor-online',
                        'zero visitor', 'V00000000', 'active')
                """);
        assertSqlState("23514", """
                UPDATE sales_quotes SET bill_no='XD20260814000099'
                WHERE id='%s'
                """.formatted(legacyQuoteId));
    }

    @Test
    @Order(4)
    void productionLineOwnerSurvivesDraftRebuildAndExecutionSegmentsRequireZx()
            throws Exception {
        UUID firstPlan = UUID.randomUUID();
        UUID secondPlan = UUID.randomUUID();
        UUID firstItem = UUID.randomUUID();
        UUID rebuiltItem = UUID.randomUUID();
        String productNo = "V279-REBUILD-PRODUCT";
        try (Connection connection = connection()) {
            execute(connection, """
                    INSERT INTO production_plans(
                        id,bill_no,bill_date,status,is_closed)
                    VALUES(?, 'SJ20260814000021', DATE '2026-08-14', 0, false)
                    """, firstPlan);
            execute(connection, """
                    INSERT INTO production_plans(
                        id,bill_no,bill_date,status,is_closed)
                    VALUES(?, 'SJ20260814000022', DATE '2026-08-14', 0, false)
                    """, secondPlan);
            insertPlanItem(connection, firstItem, firstPlan,
                    "SJ20260814000021", productNo);
            execute(connection,
                    "DELETE FROM production_plan_items WHERE id=?", firstItem);
            insertPlanItem(connection, rebuiltItem, firstPlan,
                    "SJ20260814000021", productNo);
        }
        assertSqlState("23505", """
                INSERT INTO production_plan_items(
                    id,bill_no,bill_date,plan_id,product_no,
                    goods_id,unit_id,unit_rate,qty,fqty,iqty)
                VALUES(gen_random_uuid(), 'SJ20260814000022', DATE '2026-08-14',
                       '%s', '%s', '%s', '%s', 1, 1, 0, 0)
                """.formatted(secondPlan, productNo,
                legacyProductionGoodsId, legacyProductionUnitId));

        UUID segmentId = UUID.randomUUID();
        UUID demandId = UUID.randomUUID();
        UUID packageId = UUID.randomUUID();
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                UUID warehouseId;
                try (PreparedStatement query = connection.prepareStatement("""
                        SELECT warehouse_id
                        FROM production_planning_packages
                        WHERE id=?
                        """)) {
                    query.setObject(1, legacyProductionPackageId);
                    try (ResultSet result = query.executeQuery()) {
                        assertTrue(result.next());
                        warehouseId = result.getObject(1, UUID.class);
                    }
                }
                execute(connection, """
                        INSERT INTO production_planning_packages(
                            id,plan_id,warehouse_id,idempotency_key,
                            request_hash,preview_fingerprint,status,
                            execution_model_version)
                        VALUES(?,?,?,'v279-numbering-package',?,?,'CONFIRMED',1)
                        """, packageId, firstPlan, warehouseId,
                        "d".repeat(64), "e".repeat(64));
                insertExecutionSegment(connection, packageId, firstPlan,
                        rebuiltItem, segmentId, 1, "ZX00000014");
                insertExecutionDemand(connection, packageId, firstPlan,
                        rebuiltItem, demandId, segmentId);
                connection.commit();
            } catch (Throwable error) {
                connection.rollback();
                throw error;
            }
            assertEquals(1, scalar(connection, """
                    SELECT count(*) FROM business_identifier_reservation_members
                    WHERE normalized_identifier='ZX00000014'
                      AND owner_domain='PRODUCTION_EXECUTION_SEGMENT'
                    """));
        }
        assertSqlState("23514", """
                INSERT INTO production_execution_segments(
                    id,package_id,plan_id,source_plan_item_id,
                    segment_no,segment_code,client_segment_key,
                    product_goods_id,product_unit_id,product_unit_rate,
                    planned_qty,status,bom_fingerprint,idempotency_key)
                VALUES(gen_random_uuid(), '%s', '%s', '%s', 3,
                       'SEG-ONLINE-BYPASS', 'invalid-number', '%s', '%s', 1,
                       10, 'WAITING', '%s', 'invalid-segment-number')
                """.formatted(legacyProductionPackageId, legacyProductionPlanId,
                legacyProductionPlanItemId, legacyProductionGoodsId,
                legacyProductionUnitId, "f".repeat(64)));

        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            assertEquals(1, statement.executeUpdate("""
                    INSERT INTO finance_asset_categories(
                        object_type,code,name,effective_from,version)
                    VALUES('FIXED_ASSET','V279-ASSET-CATEGORY',
                           'asset category v1',CURRENT_DATE,1)
                    """));
            assertEquals(1, statement.executeUpdate("""
                    INSERT INTO finance_asset_categories(
                        object_type,code,name,effective_from,version)
                    VALUES('FIXED_ASSET','V279-ASSET-CATEGORY',
                           'asset category v2',CURRENT_DATE,2)
                    """));
        }
        assertSqlState("23505", """
                INSERT INTO finance_asset_categories(
                    object_type,code,name,effective_from,version)
                VALUES('DEFERRED_EXPENSE','V279-ASSET-CATEGORY',
                       'cross-domain reuse',CURRENT_DATE,1)
                """);
    }

    @Test
    @Order(5)
    void explicitLegacyModePreservesNonstandardHeaderAndLeadingToken()
            throws Exception {
        UUID importedId = UUID.randomUUID();
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            statement.execute("SELECT set_config('app.business_identifier_legacy_import', 'on', false)");
            try (PreparedStatement insert = connection.prepareStatement("""
                    INSERT INTO sales_quotes (id, bill_no, bill_date, status)
                    VALUES (?, ' lg-00042 ', CURRENT_DATE, 0)
                    """)) {
                insert.setObject(1, importedId);
                assertEquals(1, insert.executeUpdate());
            }
            assertEquals(1, statement.executeUpdate("""
                    INSERT INTO visitor_accounts (
                        id, phone_enc, phone_hash, name, visitor_no, status)
                    VALUES (gen_random_uuid(), 'cipher', 'v279-zero-visitor-legacy',
                            'legacy zero visitor', 'V00000000', 'active')
                    """));
            assertEquals(" lg-00042 ", text(connection,
                    "SELECT bill_no FROM sales_quotes WHERE id=?", importedId));
            assertEquals(1, scalar(connection, """
                    SELECT count(*) FROM business_prefix_reservation_members
                    WHERE normalized_prefix='LG'
                      AND owner_kind='NAMESPACE'
                      AND owner_key='SALES_QUOTE'
                    """));
            assertEquals(1, scalar(connection, """
                    SELECT count(*) FROM business_identifier_conflicts
                    WHERE conflict_kind='FORMAT_ANOMALY'
                      AND normalized_value='V00000000'
                      AND owner_key='VISITOR_ACCOUNT'
                    """));
        }
    }

    @Test
    @Order(6)
    void aNewDistinctNamespaceAtomicallyReservesItsPrefixAndHistoryIsAppendOnly()
            throws Exception {
        try (Connection connection = connection(); Statement statement = connection.createStatement()) {
            assertEquals(1, statement.executeUpdate("""
                    INSERT INTO business_identifier_namespaces (
                        namespace_key, identifier_family, fixed_prefix,
                        source_table, identifier_column)
                    VALUES ('TEST_DISTINCT_PREFIX', 'SYSTEM', 'ZZ',
                            'test_distinct_identifier', 'number')
                    """));
            assertEquals(1, scalar(connection, """
                    SELECT count(*) FROM business_prefix_reservation_members
                    WHERE normalized_prefix='ZZ'
                      AND owner_kind='NAMESPACE'
                      AND owner_key='TEST_DISTINCT_PREFIX'
                    """));
            assertTrue(scalar(connection, """
                    SELECT count(*) FROM audit_log
                    WHERE target_type IN (
                        'business_identifier_namespaces',
                        'business_prefix_reservations',
                        'business_prefix_reservation_members')
                    """) > 0);
        }
        assertSqlState("55000", """
                DELETE FROM business_prefix_reservations
                WHERE normalized_prefix='ZZ'
                """);
        assertSqlState("23505", """
                INSERT INTO business_identifier_namespaces (
                    namespace_key, identifier_family, fixed_prefix,
                    source_table, identifier_column, discriminator_value)
                VALUES ('TEST_DUP_SOURCE_MAPPING', 'SYSTEM', 'ZY',
                        'stock_documents', 'bill_no', 'TRANSFER')
                """);
        assertSqlState("23505", """
                INSERT INTO business_identifier_namespaces (
                    namespace_key, identifier_family, fixed_prefix,
                    source_table, identifier_column)
                VALUES ('TEST_DUP_DEFAULT_MAPPING', 'SYSTEM', 'ZX',
                        'sales_quotes', 'bill_no')
                """);
    }

    @Test
    @Order(7)
    void namespaceDayCounterIsAtomicUnderConcurrentAllocation() throws Exception {
        int workers = 32;
        ExecutorService executor = Executors.newFixedThreadPool(8);
        try {
            List<Callable<String>> tasks = new ArrayList<>();
            for (int index = 0; index < workers; index++) {
                tasks.add(BusinessIdentifierRegistryPostgresTest::allocateSubplanNumber);
            }
            List<Future<String>> futures = executor.invokeAll(tasks);
            Set<String> values = new HashSet<>();
            for (Future<String> future : futures) {
                values.add(future.get());
            }
            assertEquals(workers, values.size());
            assertTrue(values.stream().allMatch(value -> value.matches("SZ[0-9]{14}")));
        } finally {
            executor.shutdownNow();
        }
    }

    @Test
    @Order(8)
    void visitorFirstCreationIsSerializedByPhoneHashAcrossConnections()
            throws Exception {
        int workers = 16;
        String phoneHash = "v279-concurrent-first-login";
        CountDownLatch start = new CountDownLatch(1);
        ExecutorService executor = Executors.newFixedThreadPool(8);
        try {
            List<Future<VisitorIdentity>> futures = new ArrayList<>();
            for (int index = 0; index < workers; index++) {
                futures.add(executor.submit(() -> {
                    start.await();
                    return findOrCreateVisitor(phoneHash);
                }));
            }
            start.countDown();

            Set<VisitorIdentity> identities = new HashSet<>();
            for (Future<VisitorIdentity> future : futures) {
                identities.add(future.get());
            }
            assertEquals(1, identities.size());
            try (Connection connection = connection()) {
                assertEquals(1, scalar(connection, """
                        SELECT count(*) FROM visitor_accounts
                        WHERE phone_hash='v279-concurrent-first-login'
                        """));
            }
        } finally {
            executor.shutdownNow();
        }
    }

    @Test
    @Order(9)
    void productionProductNumberAllocatorUsesPlanIdentityAndSkipsGlobalHistory()
            throws Exception {
        UUID planId = UUID.randomUUID();
        UUID firstItemId = UUID.randomUUID();
        UUID secondItemId = UUID.randomUUID();
        UUID explicitItemId = UUID.randomUUID();
        String planNo = "SJ20260814000024";
        try (Connection connection = connection()) {
            execute(connection, """
                    INSERT INTO production_plans(
                        id,bill_no,bill_date,status,is_closed)
                    VALUES(?,?,DATE '2026-08-14',0,false)
                    """, planId, planNo);
            execute(connection, """
                    INSERT INTO colors(id,code,name,status,is_deleted)
                    VALUES(gen_random_uuid(),?,'historical product candidate','使用',false)
                    """, planNo + "-001");

            String first = text(connection,
                    "SELECT fn_allocate_production_product_no(?)", planId);
            String second = text(connection,
                    "SELECT fn_allocate_production_product_no(?)", planId);
            assertEquals(planNo + "-002", first);
            assertEquals(planNo + "-003", second);
            insertPlanItem(connection, firstItemId, planId, planNo, first);
            insertPlanItem(connection, secondItemId, planId, planNo, second);
            insertPlanItem(connection, explicitItemId, planId, planNo,
                    planNo + "-010");
            assertEquals(planNo + "-011", text(connection,
                    "SELECT fn_allocate_production_product_no(?)", planId));
            assertEquals(11, scalar(connection, """
                    SELECT last_seq
                    FROM production_product_no_sequences
                    WHERE plan_id=?
                    """, planId));
            assertEquals(2, scalar(connection, """
                    SELECT count(*)
                    FROM business_identifier_reservation_members
                    WHERE owner_domain='PRODUCTION_PLAN_ITEM'
                      AND entity_id=?
                      AND normalized_identifier IN (?,?)
                    """, planId, first, second));
        }
    }

    private static String allocateSubplanNumber() throws Exception {
        try (Connection connection = connection(); PreparedStatement query = connection.prepareStatement("""
                WITH day AS (
                    SELECT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Shanghai')::date sequence_date
                ), advanced AS (
                    INSERT INTO business_document_sequences (
                        namespace_key, sequence_date, last_seq)
                    SELECT 'PRODUCTION_SUBPLAN', day.sequence_date, 1 FROM day
                    ON CONFLICT (namespace_key, sequence_date)
                    DO UPDATE SET last_seq = business_document_sequences.last_seq + 1
                    RETURNING sequence_date, last_seq)
                SELECT 'SZ' || to_char(sequence_date, 'YYYYMMDD')
                            || lpad(last_seq::text, 6, '0')
                FROM advanced
                """)) {
            try (ResultSet result = query.executeQuery()) {
                assertTrue(result.next());
                return result.getString(1);
            }
        }
    }

    private static VisitorIdentity findOrCreateVisitor(String phoneHash)
            throws Exception {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                try (PreparedStatement lock = connection.prepareStatement("""
                        SELECT pg_advisory_xact_lock(
                            hashtextextended(CAST(? AS text), CAST(? AS bigint)))
                        """)) {
                    lock.setString(1, phoneHash);
                    lock.setLong(2, VISITOR_ACCOUNT_LOCK_NAMESPACE);
                    lock.executeQuery().close();
                }

                VisitorIdentity existing = findVisitor(connection, phoneHash);
                if (existing != null) {
                    connection.commit();
                    return existing;
                }

                String visitorNo;
                try (PreparedStatement allocate = connection.prepareStatement("""
                        WITH advanced AS (
                            INSERT INTO master_code_sequences (prefix, last_seq)
                            VALUES ('V', 1)
                            ON CONFLICT (prefix) DO UPDATE
                            SET last_seq = master_code_sequences.last_seq + 1
                            RETURNING last_seq)
                        SELECT 'V' || CASE
                                   WHEN length(last_seq::text) < 8
                                   THEN lpad(last_seq::text, 8, '0')
                                   ELSE last_seq::text
                               END
                        FROM advanced
                        """)) {
                    try (ResultSet result = allocate.executeQuery()) {
                        assertTrue(result.next());
                        visitorNo = result.getString(1);
                    }
                }

                UUID id = UUID.randomUUID();
                try (PreparedStatement insert = connection.prepareStatement("""
                        INSERT INTO visitor_accounts (
                            id, phone_enc, phone_hash, name, visitor_no, status)
                        VALUES (?, 'cipher', ?, ?, ?, 'active')
                        """)) {
                    insert.setObject(1, id);
                    insert.setString(2, phoneHash);
                    insert.setString(3, visitorNo);
                    insert.setString(4, visitorNo);
                    assertEquals(1, insert.executeUpdate());
                }
                connection.commit();
                return new VisitorIdentity(id, visitorNo);
            } catch (Exception exception) {
                connection.rollback();
                throw exception;
            }
        }
    }

    private static VisitorIdentity findVisitor(Connection connection, String phoneHash)
            throws Exception {
        try (PreparedStatement query = connection.prepareStatement("""
                SELECT id, visitor_no FROM visitor_accounts WHERE phone_hash=?
                """)) {
            query.setString(1, phoneHash);
            try (ResultSet result = query.executeQuery()) {
                if (!result.next()) {
                    return null;
                }
                return new VisitorIdentity(
                        result.getObject(1, UUID.class), result.getString(2));
            }
        }
    }

    private static void seedLegacyProductionIdentifiers(Connection connection)
            throws Exception {
        legacyProductionPlanId = UUID.randomUUID();
        legacyProductionPlanItemId = UUID.randomUUID();
        legacyProductionPackageId = UUID.randomUUID();
        legacyProductionGoodsId = UUID.randomUUID();
        legacyProductionUnitId = UUID.randomUUID();
        legacyExecutionSegmentId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID demandId = UUID.randomUUID();

        execute(connection, "INSERT INTO units(id,code,name) VALUES(?,?,'piece')",
                legacyProductionUnitId, "V279-UNIT-" + legacyProductionUnitId);
        execute(connection, """
                INSERT INTO goods(id,code,name,min_qty,code_sequence)
                VALUES(?,?,'V279 product',0,
                       (SELECT COALESCE(max(code_sequence),0)+1 FROM goods))
                """, legacyProductionGoodsId,
                "V279-GOODS-" + legacyProductionGoodsId);
        execute(connection,
                "INSERT INTO warehouses(id,code,name) VALUES(?,?,'V279 warehouse')",
                warehouseId, "V279-WH-" + warehouseId);
        execute(connection, """
                INSERT INTO production_plans(
                    id,bill_no,bill_date,status,is_closed)
                VALUES(?,'SJ20260814000001',DATE '2026-08-14',1,false)
                """, legacyProductionPlanId);
        execute(connection, """
                INSERT INTO production_plan_items(
                    id,bill_no,bill_date,plan_id,product_no,
                    goods_id,unit_id,unit_rate,qty,fqty,iqty)
                VALUES(?,'SJ20260814000001',DATE '2026-08-14',?,
                       'V279-PLAN-PRODUCT',?,?,1,10,0,0)
                """, legacyProductionPlanItemId, legacyProductionPlanId,
                legacyProductionGoodsId, legacyProductionUnitId);

        connection.setAutoCommit(false);
        try {
            execute(connection, """
                    INSERT INTO production_planning_packages(
                        id,plan_id,warehouse_id,idempotency_key,
                        request_hash,preview_fingerprint,status,
                        execution_model_version)
                    VALUES(?,?,?,'v279-legacy-package',?,?,'CONFIRMED',1)
                    """, legacyProductionPackageId, legacyProductionPlanId,
                    warehouseId, "a".repeat(64), "b".repeat(64));
            execute(connection, """
                    INSERT INTO production_execution_segments(
                        id,package_id,plan_id,source_plan_item_id,
                        segment_no,segment_code,client_segment_key,
                        product_goods_id,product_unit_id,product_unit_rate,
                        planned_qty,status,bom_fingerprint,idempotency_key)
                    VALUES(?,?,?,?,1,'ZX00000013','v279-legacy-segment',?,?,1,
                           10,'WAITING',?,'v279-legacy-segment')
                    """, legacyExecutionSegmentId, legacyProductionPackageId,
                    legacyProductionPlanId, legacyProductionPlanItemId,
                    legacyProductionGoodsId, legacyProductionUnitId,
                    "c".repeat(64));
            execute(connection, """
                    INSERT INTO production_material_demands(
                        id,package_id,plan_id,warehouse_id,goods_id,unit_id,
                        required_qty,supply_route,status,idempotency_key,
                        execution_segment_id,source_plan_item_id,per_product_qty)
                    VALUES(?,?,?,?,?,?,10,'BUY','WAITING_SUPPLY',?,?,?,1)
                    """, demandId, legacyProductionPackageId,
                    legacyProductionPlanId, warehouseId, legacyProductionGoodsId,
                    legacyProductionUnitId, "v279-legacy-demand", legacyExecutionSegmentId,
                    legacyProductionPlanItemId);
            connection.commit();
        } catch (Throwable error) {
            connection.rollback();
            throw error;
        }
    }

    private static void insertPlanItem(
            Connection connection,
            UUID itemId,
            UUID planId,
            String billNo,
            String productNo) throws Exception {
        execute(connection, """
                INSERT INTO production_plan_items(
                    id,bill_no,bill_date,plan_id,product_no,
                    goods_id,unit_id,unit_rate,qty,fqty,iqty)
                VALUES(?,?,DATE '2026-08-14',?,?,?, ?,1,1,0,0)
                """, itemId, billNo, planId, productNo,
                legacyProductionGoodsId, legacyProductionUnitId);
    }

    private static void insertExecutionSegment(
            Connection connection,
            UUID packageId,
            UUID planId,
            UUID planItemId,
            UUID segmentId,
            int segmentNo,
            String segmentCode)
            throws Exception {
        execute(connection, """
                INSERT INTO production_execution_segments(
                    id,package_id,plan_id,source_plan_item_id,
                    segment_no,segment_code,client_segment_key,
                    product_goods_id,product_unit_id,product_unit_rate,
                    planned_qty,status,bom_fingerprint,idempotency_key)
                VALUES(?,?,?,?,?,?,?, ?,?,1,1,'WAITING',?,?)
                """, segmentId, packageId,
                planId, planItemId,
                segmentNo, segmentCode, "client-" + segmentId,
                legacyProductionGoodsId, legacyProductionUnitId,
                "d".repeat(64), "segment-" + segmentId);
    }

    private static void insertExecutionDemand(
            Connection connection,
            UUID packageId,
            UUID planId,
            UUID planItemId,
            UUID demandId,
            UUID segmentId) throws Exception {
        UUID warehouseId;
        try (PreparedStatement query = connection.prepareStatement("""
                SELECT warehouse_id FROM production_planning_packages WHERE id=?
                """)) {
            query.setObject(1, packageId);
            try (ResultSet result = query.executeQuery()) {
                assertTrue(result.next());
                warehouseId = result.getObject(1, UUID.class);
            }
        }
        execute(connection, """
                INSERT INTO production_material_demands(
                    id,package_id,plan_id,warehouse_id,goods_id,unit_id,
                    required_qty,supply_route,status,idempotency_key,
                    execution_segment_id,source_plan_item_id,per_product_qty)
                VALUES(?,?,?,?,?,?,1,'BUY','WAITING_SUPPLY',?,?,?,1)
                """, demandId, packageId,
                planId, warehouseId, legacyProductionGoodsId,
                legacyProductionUnitId, "demand-" + demandId, segmentId,
                planItemId);
    }

    private static int execute(Connection connection, String sql, Object... parameters)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < parameters.length; index++) {
                statement.setObject(index + 1, parameters[index]);
            }
            return statement.executeUpdate();
        }
    }

    private record VisitorIdentity(UUID id, String visitorNo) {}

    private static void assertSqlState(String expected, String sql) {
        SQLException exception = assertThrows(SQLException.class, () -> {
            try (Connection connection = connection(); Statement statement = connection.createStatement()) {
                statement.executeUpdate(sql);
            }
        });
        assertEquals(expected, exception.getSQLState(), exception.getMessage());
    }

    private static int scalar(
            Connection connection, String sql, Object... parameters) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < parameters.length; index++) {
                statement.setObject(index + 1, parameters[index]);
            }
            try (ResultSet result = statement.executeQuery()) {
                assertTrue(result.next());
                return result.getInt(1);
            }
        }
    }

    private static String text(Connection connection, String sql, UUID id) throws Exception {
        try (PreparedStatement query = connection.prepareStatement(sql)) {
            query.setObject(1, id);
            try (ResultSet result = query.executeQuery()) {
                assertTrue(result.next());
                return result.getString(1);
            }
        }
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private static Flyway flyway(String target) {
        return Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .target(target)
                .load();
    }
}
