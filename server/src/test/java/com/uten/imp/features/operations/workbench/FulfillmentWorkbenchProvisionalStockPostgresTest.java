package com.uten.imp.features.operations.workbench;

import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneOffset;
import java.util.List;
import java.util.Properties;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * PostgreSQL evidence that WAITING segments do not reserve partial kits and
 * that the purchase workbench does not overstate a shortage for free stock.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class FulfillmentWorkbenchProvisionalStockPostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static EntityManagerFactory entityManagerFactory;
    private static EntityManager entityManager;
    private static TransactionTemplate transactions;

    @BeforeAll
    static void migrate() {
        POSTGRES.start();
        Flyway.configure()
                .dataSource(
                        POSTGRES.getJdbcUrl(),
                        POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();

        DriverManagerDataSource dataSource = new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
        LocalContainerEntityManagerFactoryBean factory =
                new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(dataSource);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setPackagesToScan(
                "com.uten.imp.features.production.fulfillment");
        Properties properties = new Properties();
        properties.setProperty("hibernate.hbm2ddl.auto", "none");
        properties.setProperty("hibernate.show_sql", "false");
        properties.setProperty("hibernate.jdbc.time_zone", "UTC");
        factory.setJpaProperties(properties);
        factory.afterPropertiesSet();

        entityManagerFactory = factory.getObject();
        assertNotNull(entityManagerFactory);
        entityManager = SharedEntityManagerCreator.createSharedEntityManager(
                entityManagerFactory);
        transactions = new TransactionTemplate(
                new JpaTransactionManager(entityManagerFactory));
        transactions.setTimeout(20);
    }

    @AfterAll
    static void stop() {
        if (entityManagerFactory != null) {
            entityManagerFactory.close();
        }
        POSTGRES.stop();
    }

    @Test
    void freeStockIsSuggestedOnceByNeedDateWithoutBecomingAReservation()
            throws Exception {
        try (Connection connection = connection()) {
            Fixture fixture = fixture(connection);

            assertQuantity(
                    connection,
                    """
                    SELECT COUNT(*)
                    FROM v_fulfillment_workbench
                    WHERE department = 'WAREHOUSE'
                      AND task_id IN (?, ?, ?)
                    """,
                    "0",
                    fixture.earlyA(),
                    fixture.laterA(),
                    fixture.laterB());

            // A has six on hand and one safety-stock unit. The earlier demand
            // receives four units of advisory coverage; the later demand sees
            // the one remaining unit and therefore asks Purchase for three.
            assertNoPurchaseTask(connection, fixture.earlyA());
            assertOpenQty(connection, fixture.laterA(), "3");
            assertOpenQty(connection, fixture.laterB(), "4");

            update(
                    connection,
                    "UPDATE stock_balances SET qty = 10 WHERE id = ?",
                    fixture.balanceA());

            // Nine free A units now cover both four-unit WAITING demands.
            // Neither demand is reserved, and neither is shown as a purchase
            // request. B remains the only true shortage.
            assertNoPurchaseTask(connection, fixture.earlyA());
            assertNoPurchaseTask(connection, fixture.laterA());
            assertOpenQty(connection, fixture.laterB(), "4");
            assertQuantity(
                    connection,
                    """
                    SELECT COUNT(*)
                    FROM stock_reservations
                    WHERE demand_id IN (?, ?, ?)
                      AND is_deleted = FALSE
                    """,
                    "0",
                    fixture.earlyA(),
                    fixture.laterA(),
                    fixture.laterB());
        }
    }

    @Test void warehouseUnionExecutesAgainstTheFullSchemaWithoutMakingUnrequestedDemandsActionable() throws Exception {
        Fixture data;
        try (Connection connection = connection()) { data = fixture(connection); }
        FulfillmentWorkbenchAccessPolicy access = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(access.canAccessWarehouseTasks()).thenReturn(true);
        // ADR-184: 状态分段计数按「能动手」口径把关(领料任务中心执行发料), 与列表的门分开。
        when(access.canHandleWarehouseTasks()).thenReturn(true);
        var service = new FulfillmentWorkbenchQueryService(entityManager, access);
        var page = transactions.execute(status -> service.query("WAREHOUSE", "OPEN_ANY", data.planNo(),
                "", null, null, 1, 20));
        assertNotNull(page);
        assertTrue(page.items().isEmpty());
        assertEquals(0L, page.summary().pendingTasks());
        var counts = transactions.execute(status -> service.warehouseStatusBreakdown());
        assertNotNull(counts);
        assertEquals(0L, counts.get("MATERIALS_TO_DEFINE"));
    }

    @Test
    void nonEmptyPostgresProjectionMapsHibernateInstantToUtc() throws Exception {
        Fixture fixture;
        UUID purchaseTaskId;
        try (Connection connection = connection()) {
            fixture = fixture(connection);
            purchaseTaskId = insertPurchaseDecompositionTask(connection, fixture);
        }

        Object projectedUpdatedAt = transactions.execute(status ->
                entityManager.createNativeQuery("""
                                SELECT updated_at
                                FROM v_procurement_decomposition_tasks
                                WHERE department = 'PURCHASE'
                                  AND task_id = :taskId
                                """)
                        .setParameter("taskId", purchaseTaskId)
                        .getSingleResult());
        assertNotNull(projectedUpdatedAt);
        assertTrue(
                projectedUpdatedAt instanceof Instant,
                () -> "Expected Hibernate UTC projection to be Instant, got "
                        + projectedUpdatedAt.getClass().getName());

        FulfillmentWorkbenchAccessPolicy accessPolicy =
                mock(FulfillmentWorkbenchAccessPolicy.class);
        when(accessPolicy.documentAccess("PURCHASE", "PURCHASE_REQUEST"))
                .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(
                        false,
                        false));
        FulfillmentWorkbenchQueryService service =
                new FulfillmentWorkbenchQueryService(entityManager, accessPolicy);
        // Purchase tasks retain the real request item; document metadata remains fenced.
        UUID requestId = transactions.execute(status ->
                (UUID) entityManager.createNativeQuery("""
                                SELECT request_id FROM purchase_request_items WHERE id = :itemId
                                """)
                        .setParameter("itemId", purchaseTaskId)
                        .getSingleResult());
        // Other scenarios insert over 100 rows into this class's shared database.
        // Scope this timestamp/authorization assertion to its own document.
        String requestNo = transactions.execute(status -> (String) entityManager.createNativeQuery(
                "SELECT bill_no FROM purchase_requests WHERE id=:id")
                .setParameter("id", requestId).getSingleResult());
        FulfillmentWorkbenchPage page = transactions.execute(status ->
                service.query("PURCHASE", "", requestNo, "", null, null, 1, 100));
        assertNotNull(page);
        FulfillmentTaskRow task = page.items().stream()
                .filter(row -> row.taskId().equals(purchaseTaskId))
                .findFirst()
                .orElseThrow();

        assertNotNull(task.updatedAt());
        assertEquals(ZoneOffset.UTC, task.updatedAt().getOffset());
        assertEquals(projectedUpdatedAt, task.updatedAt().toInstant());

        // 2026-09-05 修复回归锁：归组行的明细 id 集不能为空——stringArray
        // 需兼容 Hibernate 直接返回的 String[]/Object[]（只认 java.sql.Array
        // 时恒为空，前端批量「生成采购订货单」会永远报「先生成/挂接采购申请」）。
        Object rawIds = transactions.execute(status ->
                entityManager.createNativeQuery("""
                                SELECT COALESCE(
                                           ARRAY_AGG(action_item_id::TEXT)
                                               FILTER (WHERE action_item_id IS NOT NULL),
                                           ARRAY[]::TEXT[])
                                FROM v_procurement_decomposition_tasks
                                WHERE department = 'PURCHASE'
                                  AND action_doc_id = :requestId
                                """)
                        .setParameter("requestId", requestId)
                        .getSingleResult());
        assertTrue(
                !FulfillmentWorkbenchQueryService.stringArray(rawIds).isEmpty(),
                () -> "aggregate text[] must map to non-empty ids, raw type: "
                        + rawIds.getClass().getName());
        // 受限行（上方 canView=false mock）单据元数据必须脱敏为空集；
        // 放开可见性后同一行必须带回完整明细 id 集。
        assertTrue(task.actionItemIds().isEmpty(),
                "restricted row must not leak document item ids");
        when(accessPolicy.documentAccess("PURCHASE", "PURCHASE_REQUEST"))
                .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(
                        true,
                        false));
        FulfillmentWorkbenchPage openPage = transactions.execute(status ->
                service.query("PURCHASE", "", requestNo, "", null, null, 1, 100));
        FulfillmentTaskRow openTask = openPage.items().stream()
                .filter(row -> row.taskId().equals(purchaseTaskId))
                .findFirst()
                .orElseThrow();
        assertEquals(
                List.of(purchaseTaskId.toString()),
                openTask.actionItemIds(),
                "visible grouped row must expose its request item ids");
    }

    @Test
    void itemGoodsSearchFindsEveryRealLineAndRanksNamesBeforeCodesBeforePaging() throws Exception {
        String word = "KW" + UUID.randomUUID().toString().replace("-", "");
        UUID[] requests = new UUID[3];
        try (Connection connection = connection()) {
            for (int index = 0; index < 3; index++) {
                Fixture data = fixture(connection);
                if (index == 1) insert(connection, "UPDATE goods SET code=?,name='普通件' WHERE id=?", word, data.materialB());
                else insert(connection, "UPDATE goods SET name=? WHERE id=?", index == 0 ? word : word + " M3_20%", data.materialB());
                UUID item = insertPurchaseDecompositionTask(connection, data);
                try (PreparedStatement statement = connection.prepareStatement("SELECT request_id FROM purchase_request_items WHERE id=?")) {
                    statement.setObject(1, item);
                    try (ResultSet result = statement.executeQuery()) { result.next(); requests[index] = result.getObject(1, UUID.class); }
                }
                if (index == 2) {
                    insert(connection, """
                            INSERT INTO purchase_request_items(id,bill_no,bill_date,request_id,line_no,goods_id,unit_id,
                                unit_rate,qty,ordered_qty,deliver_date,production_plan_no,source_doc_no,goods_snapshot_source)
                            SELECT ?,first.bill_no,first.bill_date,first.request_id,2,stock.goods_id,first.unit_id,
                                   1,4,0,first.deliver_date,first.production_plan_no,first.source_doc_no,'MASTER_AT_SAVE'
                            FROM purchase_request_items first CROSS JOIN stock_balances stock
                            WHERE first.id=? AND stock.id=?
                            """, UUID.randomUUID(), item, data.balanceA());
                }
            }
        }
        FulfillmentWorkbenchAccessPolicy access = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(access.documentAccess("PURCHASE", "PURCHASE_REQUEST"))
                .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, false));
        var service = new FulfillmentWorkbenchQueryService(entityManager, access);
        List<UUID> ranked = new java.util.ArrayList<>();
        for (int page = 1; page <= 3; page++) {
            final int current = page;
            var result = transactions.execute(status -> service.query("PURCHASE", "", word, "", null, null, current, 1));
            assertNotNull(result);
            assertEquals(3L, result.total());
            assertEquals(3L, result.summary().totalTasks());
            ranked.add(result.items().getFirst().actionDocId());
        }
        assertEquals(List.of(requests[0], requests[2], requests[1]), ranked);
        var literal = transactions.execute(status -> service.query("PURCHASE", "", word + " M3_20%", "", null, null, 1, 1));
        assertNotNull(literal);
        assertEquals(1L, literal.total());
        assertEquals(requests[2], literal.items().getFirst().actionDocId());
        assertEquals(1L, literal.items().getFirst().goodsCount());
        assertEquals(1L, literal.summary().pendingTasks());
        assertTrue(transactions.execute(status -> service.query("PURCHASE", "", word + " M3X20A", "", null, null, 1, 20)).items().isEmpty());
    }

    @Test
    void purchaseOrderHistoryKeepsEveryItemQuantitySupplierAndIndependentColumnSearch() throws Exception {
        UUID order = UUID.randomUUID();
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        UUID supplier = UUID.randomUUID();
        String supplierName = "供应商" + supplier;
        String number = businessIdentifier("CD", LocalDate.now());
        try (Connection connection = connection()) {
            Fixture data = fixture(connection);
            // Deliberately put A in B's code: name-column words must never match the separate code column.
            insert(connection, "UPDATE goods SET code=? WHERE id=?", "MATERIALB-" + data.materialB(), data.materialB());
            insert(connection, """
                    INSERT INTO suppliers(id,code,name,status,category_id,code_sequence,code_managed,code_prefix_category_id)
                    SELECT ?,?,?,'使用',category.id,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM suppliers),FALSE,NULL
                    FROM supplier_categories category WHERE NOT category.is_deleted ORDER BY category.id LIMIT 1
                    """, supplier, "S-" + supplier, supplierName);
            insert(connection, """
                    INSERT INTO purchase_orders(id,bill_no,bill_date,supplier_id,warehouse_id,status)
                    VALUES(?,?,CURRENT_DATE,?,?,1)
                    """, order, number, supplier, data.warehouse());
            UUID materialA;
            try (PreparedStatement statement = connection.prepareStatement("SELECT goods_id FROM stock_balances WHERE id=?")) {
                statement.setObject(1, data.balanceA());
                try (ResultSet result = statement.executeQuery()) { result.next(); materialA = result.getObject(1, UUID.class); }
            }
            insert(connection, """
                    INSERT INTO purchase_order_items(id,bill_no,bill_date,order_id,line_no,goods_id,unit_id,
                        unit_rate,qty,received_qty,returned_qty,goods_snapshot_source)
                    VALUES(?,?,CURRENT_DATE,?,1,?,?,1,10,4,1,'MASTER_AT_SAVE'),
                          (?,?,CURRENT_DATE,?,2,?,?,1,20,20,0,'MASTER_AT_SAVE')
                    """, first, number, order, materialA, data.unit(),
                    second, number, order, data.materialB(), data.unit());
        }
        FulfillmentWorkbenchAccessPolicy access = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(access.documentAccess("PURCHASE", "PURCHASE_ORDER"))
                .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, false));
        var service = new FulfillmentWorkbenchQueryService(entityManager, access);
        var table = FulfillmentWorkbenchTableQuery.from("docNo", "asc", java.util.Map.of("f.docNo", number),
                null, null, null, null);
        var page = transactions.execute(status -> service.query("PURCHASE", "", "", "", null, null, 1, 1, table));
        assertNotNull(page);
        assertEquals(2, page.total());
        assertEquals(2, page.totalPages());
        assertEquals(1L, page.summary().statusCounts().get("FINANCE_APPROVED"));
        var exceeded = org.junit.jupiter.api.Assertions.assertThrows(com.uten.imp.common.web.ApiException.class,
                () -> transactions.execute(status -> service.exportPurchase("", "", "", null, null, table, 1)));
        assertEquals(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED, exceeded.getCode());
        assertTrue(exceeded.getMessage().contains("1 行上限"));
        var export = transactions.execute(status -> service.exportPurchase("", "", "", null, null, table, 2));
        assertNotNull(export);
        assertEquals(2, export.rows().size());
        assertEquals(java.util.Set.of(first, second), transactions.execute(status -> service
                .query("PURCHASE", "", "", "", null, null, 1, 100, table)).items().stream()
                .map(FulfillmentTaskRow::taskId).collect(java.util.stream.Collectors.toSet()));
        var rows = export.rows().stream().collect(java.util.stream.Collectors.toMap(row -> row.get("goodsName"), row -> row));
        assertEquals(0, new BigDecimal("10").compareTo((BigDecimal) rows.get("物料 A").get("requiredQty")));
        assertEquals(0, new BigDecimal("3").compareTo((BigDecimal) rows.get("物料 A").get("fulfilledQty")));
        assertEquals(0, new BigDecimal("7").compareTo((BigDecimal) rows.get("物料 A").get("openQty")));
        assertEquals(0, new BigDecimal("20").compareTo((BigDecimal) rows.get("物料 B").get("requiredQty")));
        assertEquals(0, BigDecimal.ZERO.compareTo((BigDecimal) rows.get("物料 B").get("openQty")));
        assertTrue(export.rows().stream().allMatch(row -> number.equals(row.get("actionDocNo"))
                && supplierName.equals(row.get("supplierName"))));
        var searched = FulfillmentWorkbenchTableQuery.from("docNo", "asc", java.util.Map.of(
                "f.docNo", number, "search.goods", "物料 A", "search.supplierName", supplierName),
                null, null, null, null);
        assertEquals(1, transactions.execute(status -> service.exportPurchase("", "", "", null, null, searched, 1)).total());
        var nameCannotMatchCode = FulfillmentWorkbenchTableQuery.from("docNo", "asc", java.util.Map.of(
                "f.docNo", number, "search.goods", "MATERIALB"), null, null, null, null);
        assertEquals(0, transactions.execute(status -> service.exportPurchase("", "", "", null, null, nameCannotMatchCode, 1)).total());
        var codeSearch = FulfillmentWorkbenchTableQuery.from("docNo", "asc", java.util.Map.of(
                "f.docNo", number, "search.goodsCode", "MATERIALB"), null, null, null, null);
        var byCode = transactions.execute(status -> service.exportPurchase("", "", "", null, null, codeSearch, 1));
        assertNotNull(byCode);
        assertEquals(1, byCode.total());
        assertEquals("物料 B", byCode.rows().getFirst().get("goodsName"));
        when(access.documentAccess("PURCHASE", "PURCHASE_ORDER"))
                .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(false, false));
        var restricted = transactions.execute(status -> service.query("PURCHASE", "", number, "", null, null, 1, 100));
        assertNotNull(restricted);
        assertTrue(restricted.items().stream().allMatch(row -> row.actionDocNo() == null && row.supplierName() == null));
        assertEquals(0, transactions.execute(status -> service.exportPurchase("", "", "", null, null, searched, 1)).total());
    }

    @Test
    void subcontractItemsKeepIndependentQuantitiesStagesAndDocumentFiltering() throws Exception {
        UUID application = UUID.randomUUID();
        UUID firstApplicationItem = UUID.randomUUID();
        UUID secondApplicationItem = UUID.randomUUID();
        UUID order = UUID.randomUUID();
        UUID firstOrderItem = UUID.randomUUID();
        UUID secondOrderItem = UUID.randomUUID();
        UUID settlement = UUID.randomUUID();
        String applicationNo = businessIdentifier("EB", LocalDate.now());
        String orderNo = businessIdentifier("EO", LocalDate.now());
        try (Connection connection = connection()) {
            Fixture data = fixture(connection);
            insert(connection, "INSERT INTO settlement_methods(id,code,name) VALUES(?,?,'现结')",
                    settlement, "SETTLE-" + settlement);
            UUID materialA;
            try (PreparedStatement statement = connection.prepareStatement("SELECT goods_id FROM stock_balances WHERE id=?")) {
                statement.setObject(1, data.balanceA());
                try (ResultSet result = statement.executeQuery()) { result.next(); materialA = result.getObject(1, UUID.class); }
            }
            insert(connection, """
                    INSERT INTO subcontract_applications(id,bill_no,bill_date,warehouse_id,status)
                    VALUES(?,?,CURRENT_DATE,?,1)
                    """, application, applicationNo, data.warehouse());
            insert(connection, """
                    INSERT INTO subcontract_application_items(id,bill_no,bill_date,application_id,line_no,
                        goods_id,unit_id,unit_rate,qty,ordered_qty,goods_snapshot_source)
                    VALUES(?,?,CURRENT_DATE,?,1,?,?,1,10,3,'MASTER_AT_SAVE'),
                          (?,?,CURRENT_DATE,?,2,?,?,1,20,4,'MASTER_AT_SAVE')
                    """, firstApplicationItem, applicationNo, application, materialA, data.unit(),
                    secondApplicationItem, applicationNo, application, data.materialB(), data.unit());
            insert(connection, """
                    INSERT INTO subcontract_orders(id,bill_no,bill_date,warehouse_id,settlement_method_id,status)
                    VALUES(?,?,CURRENT_DATE,?,?,1)
                    """, order, orderNo, data.warehouse(), settlement);
            insert(connection, """
                    INSERT INTO subcontract_order_items(id,bill_no,bill_date,order_id,line_no,goods_id,unit_id,
                        unit_rate,qty,received_qty,returned_qty,goods_snapshot_source)
                    VALUES(?,?,CURRENT_DATE,?,1,?,?,1,10,3,1,'MASTER_AT_SAVE'),
                          (?,?,CURRENT_DATE,?,2,?,?,1,20,20,0,'MASTER_AT_SAVE')
                    """, firstOrderItem, orderNo, order, materialA, data.unit(),
                    secondOrderItem, orderNo, order, data.materialB(), data.unit());
        }
        FulfillmentWorkbenchAccessPolicy access = mock(FulfillmentWorkbenchAccessPolicy.class);
        for (String type : List.of("SUBCONTRACT_APPLICATION", "SUBCONTRACT_ORDER")) {
            when(access.documentAccess("SUBCONTRACT", type))
                    .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, false));
        }
        var service = new FulfillmentWorkbenchQueryService(entityManager, access);
        for (String number : List.of(applicationNo, orderNo)) {
            var filter = FulfillmentWorkbenchTableQuery.from("docNo", "asc", java.util.Map.of("f.docNo", number),
                    null, null, null, null);
            var firstPage = transactions.execute(status -> service.query("SUBCONTRACT", "", "", "", null, null, 1, 1, filter));
            var secondPage = transactions.execute(status -> service.query("SUBCONTRACT", "", "", "", null, null, 2, 1, filter));
            assertNotNull(firstPage);
            assertNotNull(secondPage);
            assertEquals(2L, firstPage.total());
            assertEquals(2, firstPage.totalPages());
            var items = List.of(firstPage.items().getFirst(), secondPage.items().getFirst());
            assertEquals(2L, items.stream().map(FulfillmentTaskRow::taskId).distinct().count());
            assertTrue(items.stream().allMatch(row -> !row.isDocumentGrouped()
                    && row.actionItemIds().equals(List.of(row.taskId().toString()))
                    && number.equals(row.actionDocNo()) && "件".equals(row.unitName())));
            var byItem = items.stream().collect(java.util.stream.Collectors.toMap(FulfillmentTaskRow::taskId, row -> row));
            UUID firstId = number.equals(applicationNo) ? firstApplicationItem : firstOrderItem;
            UUID secondId = number.equals(applicationNo) ? secondApplicationItem : secondOrderItem;
            assertEquals(0, new BigDecimal("10").compareTo(byItem.get(firstId).requiredQty()));
            assertEquals(0, new BigDecimal("20").compareTo(byItem.get(secondId).requiredQty()));
            assertEquals(0, new BigDecimal(number.equals(applicationNo) ? "7" : "8").compareTo(byItem.get(firstId).openQty()));
            assertEquals(0, new BigDecimal(number.equals(applicationNo) ? "16" : "0").compareTo(byItem.get(secondId).openQty()));
            if (number.equals(orderNo)) {
                assertEquals("PARTIAL_RECEIVED", byItem.get(firstId).displayStage());
                assertEquals("RECEIVED_PENDING_STOCK", byItem.get(secondId).displayStage());
            }
            var goodsFilter = FulfillmentWorkbenchTableQuery.from("docNo", "asc",
                    java.util.Map.of("f.docNo", number, "search.goods", "物料 A"), null, null, null, null);
            var searched = transactions.execute(status -> service.query("SUBCONTRACT", "", "", "", null, null, 1, 20, goodsFilter));
            assertNotNull(searched);
            assertEquals(1L, searched.total());
            assertEquals(firstId, searched.items().getFirst().actionDocItemId());
        }
    }

    @Test
    void pendingExportIncludesRowsBeyondTheCurrentPageAndRetainsExactQuantityUnits() throws Exception {
        String unique = "EXPORT" + UUID.randomUUID();
        try (Connection connection = connection()) {
            Fixture data = fixture(connection);
            UUID item = insertPurchaseDecompositionTask(connection, data);
            insert(connection, "UPDATE goods SET name=? WHERE id=?", unique, data.materialB());
            insert(connection, """
                    INSERT INTO purchase_request_items(id,bill_no,bill_date,request_id,line_no,goods_id,unit_id,
                        unit_rate,qty,ordered_qty,deliver_date,production_plan_no,source_doc_no,goods_snapshot_source)
                    SELECT gen_random_uuid(),first.bill_no,first.bill_date,first.request_id,number,
                           first.goods_id,first.unit_id,1,0.05,0,first.deliver_date,
                           first.production_plan_no,first.source_doc_no,'MASTER_AT_SAVE'
                    FROM purchase_request_items first CROSS JOIN generate_series(2,105) AS number WHERE first.id=?
                    """, item);
        }
        FulfillmentWorkbenchAccessPolicy access = mock(FulfillmentWorkbenchAccessPolicy.class);
        when(access.documentAccess("PURCHASE", "PURCHASE_REQUEST"))
                .thenReturn(new FulfillmentWorkbenchAccessPolicy.DocumentAccess(true, false));
        var service = new FulfillmentWorkbenchQueryService(entityManager, access);
        var table = new FulfillmentWorkbenchTableQuery("goods", "asc", java.util.Map.of("search.goods", unique),
                null, null, null, null);
        var firstPage = transactions.execute(status -> service.query("PURCHASE", "WAITING_ORDER", "", "", null, null, 1, 50, table));
        assertNotNull(firstPage);
        assertEquals(50, firstPage.items().size());
        assertEquals(105, firstPage.total());
        var exceeded = org.junit.jupiter.api.Assertions.assertThrows(com.uten.imp.common.web.ApiException.class,
                () -> transactions.execute(status -> service.exportPurchase("WAITING_ORDER", "", "", null, null, table, 104)));
        assertEquals(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED, exceeded.getCode());
        assertTrue(exceeded.getMessage().contains("104 行上限"));
        var export = transactions.execute(status -> service.exportPurchase("WAITING_ORDER", "", "", null, null, table, 105));
        assertNotNull(export);
        assertEquals(105, export.total());
        assertEquals(104, export.rows().stream().filter(row -> new BigDecimal("0.05").compareTo((BigDecimal) row.get("requiredQty")) == 0).count());
        assertTrue(export.rows().stream().allMatch(row -> "件".equals(row.get("unitName"))));
    }

    private static Fixture fixture(Connection connection) throws Exception {
        UUID warehouse = UUID.randomUUID();
        UUID unit = UUID.randomUUID();
        UUID materialA = UUID.randomUUID();
        UUID materialB = UUID.randomUUID();
        UUID product = UUID.randomUUID();
        UUID balanceA = UUID.randomUUID();
        UUID plan = UUID.randomUUID();
        UUID earlyPlanItem = UUID.randomUUID();
        UUID laterPlanItem = UUID.randomUUID();
        UUID planningPackage = UUID.randomUUID();
        UUID earlySegment = UUID.randomUUID();
        UUID laterSegment = UUID.randomUUID();
        UUID earlyA = UUID.randomUUID();
        UUID laterA = UUID.randomUUID();
        UUID laterB = UUID.randomUUID();
        LocalDate planDate = LocalDate.of(2026, 7, 31);
        String planNo = businessIdentifier("SJ", planDate);

        insert(
                connection,
                "INSERT INTO warehouses(id,code,name) VALUES(?,?,'仓库')",
                warehouse,
                "W-" + warehouse);
        insert(
                connection,
                "INSERT INTO units(id,code,name) VALUES(?,?,'件')",
                unit,
                "U-" + unit);
        insert(
                connection,
                """
                INSERT INTO goods(id,code,name,min_qty,code_sequence)
                VALUES(?,?,'物料 A',1,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))
                """,
                materialA,
                "A-" + materialA);
        insert(
                connection,
                """
                INSERT INTO goods(id,code,name,min_qty,code_sequence)
                VALUES(?,?,'物料 B',0,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))
                """,
                materialB,
                "B-" + materialB);
        insert(
                connection,
                """
                INSERT INTO goods(id,code,name,min_qty,code_sequence)
                VALUES(?,?,'成品',0,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))
                """,
                product,
                "P-" + product);
        insert(
                connection,
                """
                INSERT INTO stock_balances(id,warehouse_id,goods_id,qty)
                VALUES(?,?,?,6)
                """,
                balanceA,
                warehouse,
                materialA);
        insert(
                connection,
                """
                INSERT INTO production_plans(
                    id,bill_no,bill_date,status,is_closed
                ) VALUES(?,?,?,1,FALSE)
                """,
                plan,
                planNo,
                planDate);
        insertPlanItem(
                connection,
                earlyPlanItem,
                plan,
                product,
                unit,
                "EARLY-" + earlyPlanItem);
        insertPlanItem(
                connection,
                laterPlanItem,
                plan,
                product,
                unit,
                "LATER-" + laterPlanItem);

        connection.setAutoCommit(false);
        try {
            insert(
                    connection,
                    """
                    INSERT INTO production_planning_packages(
                        id,plan_id,warehouse_id,idempotency_key,request_hash,
                        preview_fingerprint,status,execution_model_version
                    ) VALUES(?,?,?,?,?,?,'CONFIRMED',1)
                    """,
                    planningPackage,
                    plan,
                    warehouse,
                    "PKG-" + planningPackage,
                    "a".repeat(64),
                    "b".repeat(64));
            insertSegment(
                    connection,
                    earlySegment,
                    planningPackage,
                    plan,
                    earlyPlanItem,
                    product,
                    unit,
                    1,
                    "EARLY-" + earlySegment,
                    LocalDate.of(2026, 8, 1));
            insertSegment(
                    connection,
                    laterSegment,
                    planningPackage,
                    plan,
                    laterPlanItem,
                    product,
                    unit,
                    2,
                    "LATER-" + laterSegment,
                    LocalDate.of(2026, 8, 2));
            insertDemand(
                    connection,
                    earlyA,
                    planningPackage,
                    plan,
                    warehouse,
                    materialA,
                    unit,
                    earlySegment,
                    earlyPlanItem,
                    LocalDate.of(2026, 8, 1));
            insertDemand(
                    connection,
                    laterA,
                    planningPackage,
                    plan,
                    warehouse,
                    materialA,
                    unit,
                    laterSegment,
                    laterPlanItem,
                    LocalDate.of(2026, 8, 2));
            insertDemand(
                    connection,
                    laterB,
                    planningPackage,
                    plan,
                    warehouse,
                    materialB,
                    unit,
                    laterSegment,
                    laterPlanItem,
                    LocalDate.of(2026, 8, 2));
            connection.commit();
        } catch (Throwable error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
        return new Fixture(
                balanceA,
                earlyA,
                laterA,
                laterB,
                warehouse,
                unit,
                materialB,
                plan,
                planNo);
    }

    private static UUID insertPurchaseDecompositionTask(
            Connection connection,
            Fixture fixture) throws Exception {
        UUID requestId = UUID.randomUUID();
        UUID requestItemId = UUID.randomUUID();
        LocalDate needDate = LocalDate.of(2026, 8, 2);
        String billNo = businessIdentifier("CS", needDate);
        String planNo = fixture.planNo();

        connection.setAutoCommit(false);
        try {
            insert(
                    connection,
                    """
                    INSERT INTO purchase_requests(
                        id,bill_no,bill_date,warehouse_id,need_date,status,source_doc_no
                    ) VALUES(?,?,?,?,?,1,?)
                    """,
                    requestId,
                    billNo,
                    needDate,
                    fixture.warehouse(),
                    needDate,
                    planNo);
            insert(
                    connection,
                    """
                    INSERT INTO purchase_request_items(
                        id,bill_no,bill_date,request_id,line_no,goods_id,unit_id,
                        unit_rate,qty,ordered_qty,deliver_date,production_plan_no,
                        source_doc_no,goods_snapshot_source
                    ) VALUES(?,?,?,?,1,?,?,1,4,0,?,?,?,'MASTER_AT_SAVE')
                    """,
                    requestItemId,
                    billNo,
                    needDate,
                    requestId,
                    fixture.materialB(),
                    fixture.unit(),
                    needDate,
                    planNo,
                    planNo);
            connection.commit();
        } catch (Throwable error) {
            connection.rollback();
            throw error;
        } finally {
            connection.setAutoCommit(true);
        }
        return requestItemId;
    }

    private static void insertPlanItem(
            Connection connection,
            UUID id,
            UUID plan,
            UUID goods,
            UUID unit,
            String productNo) throws Exception {
        insert(
                connection,
                """
                INSERT INTO production_plan_items(
                    id,bill_no,bill_date,plan_id,product_no,goods_id,
                    unit_id,unit_rate,qty,fqty,iqty
                ) VALUES(?,?,?,?,?,?,?,1,4,0,0)
                """,
                id,
                "ITEM-" + id,
                LocalDate.of(2026, 7, 31),
                plan,
                productNo,
                goods,
                unit);
    }

    private static void insertSegment(
            Connection connection,
            UUID id,
            UUID planningPackage,
            UUID plan,
            UUID planItem,
            UUID goods,
            UUID unit,
            int number,
            String key,
            LocalDate begin) throws Exception {
        insert(
                connection,
                """
                INSERT INTO production_execution_segments(
                    id,package_id,plan_id,source_plan_item_id,segment_no,
                    segment_code,client_segment_key,product_goods_id,
                    product_unit_id,product_unit_rate,planned_qty,status,
                    plan_begin_date,bom_fingerprint,idempotency_key
                ) VALUES(?,?,?,?,?,?,?,?,?,1,4,'WAITING',?,?,?)
                """,
                id,
                planningPackage,
                plan,
                planItem,
                number,
                canonicalSegmentCode(id),
                key,
                goods,
                unit,
                begin,
                "c".repeat(64),
                "SEGMENT-" + id);
    }

    private static void insertDemand(
            Connection connection,
            UUID id,
            UUID planningPackage,
            UUID plan,
            UUID warehouse,
            UUID goods,
            UUID unit,
            UUID segment,
            UUID planItem,
            LocalDate needDate) throws Exception {
        insert(
                connection,
                """
                INSERT INTO production_material_demands(
                    id,package_id,plan_id,warehouse_id,goods_id,unit_id,
                    required_qty,supply_route,status,idempotency_key,
                    execution_segment_id,source_plan_item_id,
                    per_product_qty,need_date
                ) VALUES(?,?,?,?,?,?,4,'BUY','WAITING_SUPPLY',?,?,?,?,?)
                """,
                id,
                planningPackage,
                plan,
                warehouse,
                goods,
                unit,
                "DEMAND-" + id,
                segment,
                planItem,
                BigDecimal.ONE,
                needDate);
    }

    private static void assertNoPurchaseTask(
            Connection connection,
            UUID demandId) throws Exception {
        assertQuantity(
                connection,
                """
                SELECT COUNT(*)
                FROM v_fulfillment_workbench
                WHERE department = 'PURCHASE' AND task_id = ?
                """,
                "0",
                demandId);
    }

    private static void assertOpenQty(
            Connection connection,
            UUID demandId,
            String expected) throws Exception {
        assertQuantity(
                connection,
                """
                SELECT open_qty
                FROM v_fulfillment_workbench
                WHERE department = 'PURCHASE' AND task_id = ?
                """,
                expected,
                demandId);
    }

    private static void assertQuantity(
            Connection connection,
            String sql,
            String expected,
            Object... parameters) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < parameters.length; index++) {
                statement.setObject(index + 1, parameters[index]);
            }
            try (ResultSet result = statement.executeQuery()) {
                result.next();
                assertEquals(
                        0,
                        new BigDecimal(expected).compareTo(
                                new BigDecimal(result.getObject(1).toString())));
            }
        }
    }

    private static void insert(
            Connection connection,
            String sql,
            Object... parameters) throws Exception {
        update(connection, sql, parameters);
    }

    private static void update(
            Connection connection,
            String sql,
            Object... parameters) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < parameters.length; index++) {
                statement.setObject(index + 1, parameters[index]);
            }
            statement.executeUpdate();
        }
    }

    private static String canonicalSegmentCode(UUID segmentId) {
        return "ZX%08d".formatted(
                Math.floorMod(segmentId.hashCode(), 99_999_999) + 1);
    }

    private static String businessIdentifier(String prefix, LocalDate date) {
        int sequence = BUSINESS_IDENTIFIER_SEQUENCE.incrementAndGet();
        if (sequence > 999_999) {
            throw new IllegalStateException("test business identifier sequence exhausted");
        }
        return prefix + date.toString().replace("-", "") + "%06d".formatted(sequence);
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(
                POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(),
                POSTGRES.getPassword());
    }

    private record Fixture(
            UUID balanceA,
            UUID earlyA,
            UUID laterA,
            UUID laterB,
            UUID warehouse,
            UUID unit,
            UUID materialB,
            UUID plan,
            String planNo) {
    }
}
