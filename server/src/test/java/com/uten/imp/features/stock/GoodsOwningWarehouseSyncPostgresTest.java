package com.uten.imp.features.stock;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

/**
 * V590 归属仓入库自动回写的真库行为（GoodsOwningWarehouseSyncService）。
 *
 * <p>锁三件事：① 入库回写为最新入库仓；② 值没变不写（version 不动——
 * goods 带审计/版本触发器，无谓回写会刷审计噪音）；③ 货品不存在/参数为空时
 * 静默跳过。调用方 StockService 只在 DIR_IN 分支调用（出库/红冲不翻转）。
 */
@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsOwningWarehouseSyncPostgresTest {

    @Container
    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine");

    private static final UUID WAREHOUSE_A = UUID.fromString("20000000-0000-4000-8000-00000000000a");
    private static final UUID WAREHOUSE_B = UUID.fromString("20000000-0000-4000-8000-00000000000b");
    private static final UUID LINE_SIDE = UUID.fromString("20000000-0000-4000-8000-00000000000c");
    private static final UUID GOODS_PLAIN = UUID.fromString("10000000-0000-4000-8000-000000000001");
    private static final UUID GOODS_AT_A = UUID.fromString("10000000-0000-4000-8000-000000000002");
    private static final UUID GOODS_ABSENT = UUID.fromString("10000000-0000-4000-8000-0000000000ff");

    private static JdbcTemplate jdbc;
    private static jakarta.persistence.EntityManagerFactory entityManagers;
    private static jakarta.persistence.EntityManager em;
    private GoodsOwningWarehouseSyncService service;
    private InventoryMutationLock inventory;

    @BeforeAll
    static void schema() {
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        jdbc.execute("""
                CREATE TABLE warehouses(
                    id uuid PRIMARY KEY,
                    is_line_side boolean NOT NULL DEFAULT false,
                    is_deleted boolean NOT NULL DEFAULT false,
                    name text)
                """);
        jdbc.execute("""
                CREATE TABLE goods(
                    id uuid PRIMARY KEY,
                    name text,
                    owning_warehouse_id uuid REFERENCES warehouses(id) ON DELETE RESTRICT,
                    version bigint NOT NULL DEFAULT 0,
                    is_deleted boolean NOT NULL DEFAULT false,
                    updated_at timestamptz,
                    updated_by uuid, default_purchase_price_color_id uuid, default_purchase_price_currency_id uuid, default_purchase_price_supplier_id uuid, default_purchase_price_tax_rate numeric(18,4), default_purchase_price_unit_id uuid, default_subcontract_price_color_id uuid, default_subcontract_price_currency_id uuid, default_subcontract_price_supplier_id uuid, default_subcontract_price_tax_rate numeric(18,4), default_subcontract_price_unit_id uuid)
                """);
        // Production uses JPA @Version, not a database version trigger.
        // The native learning command itself must advance the optimistic-lock token.
        var factory = new org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(jdbc.getDataSource());
        factory.setJpaVendorAdapter(new org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter());
        factory.setJpaDialect(new com.uten.imp.support.NativeSavepointJpaDialect());
        factory.setPackagesToScan("com.uten.imp.features.sales.order");
        var properties = new java.util.Properties(); properties.setProperty("hibernate.hbm2ddl.auto", "none");
        factory.setJpaProperties(properties); factory.afterPropertiesSet();
        entityManagers = factory.getObject();
        em = org.springframework.orm.jpa.SharedEntityManagerCreator.createSharedEntityManager(entityManagers);
    }

    @AfterAll static void closeEntityManagers() { if (entityManagers != null) entityManagers.close(); }

    @BeforeEach
    void fixture() {
        jdbc.update("DELETE FROM goods");
        jdbc.update("DELETE FROM warehouses");
        jdbc.update("INSERT INTO warehouses(id, name) VALUES (?, 'A'), (?, 'B')",
                WAREHOUSE_A, WAREHOUSE_B);
        jdbc.update("INSERT INTO warehouses(id, name, is_line_side) VALUES (?, '车间流转位置', true)", LINE_SIDE);
        jdbc.update("INSERT INTO goods(id, name) VALUES (?, 'plain')", GOODS_PLAIN);
        jdbc.update(
                "INSERT INTO goods(id, name, owning_warehouse_id) VALUES (?, 'at-a', ?)",
                GOODS_AT_A, WAREHOUSE_A);
        service = new GoodsOwningWarehouseSyncService(jdbc);
        inventory = new InventoryMutationLock(em);
    }

    @Test
    void inboundWritesLatestWarehouse() {
        service.syncOnInbound(GOODS_PLAIN, WAREHOUSE_A);
        assertEquals(WAREHOUSE_A, owningWarehouse(GOODS_PLAIN));
        assertEquals(1L, version(GOODS_PLAIN));

        // 换仓入库：归属仓跟随最新入库仓。
        service.syncOnInbound(GOODS_PLAIN, WAREHOUSE_B);
        assertEquals(WAREHOUSE_B, owningWarehouse(GOODS_PLAIN));
        assertEquals(2L, version(GOODS_PLAIN));
    }

    @Test
    void unchangedWarehouseIsNoop() {
        service.syncOnInbound(GOODS_AT_A, WAREHOUSE_A);
        assertEquals(WAREHOUSE_A, owningWarehouse(GOODS_AT_A));
        assertEquals(0L, version(GOODS_AT_A), "值没变不能落盘（审计/版本不刷）");
    }

    @Test
    void nullArgsAndAbsentGoodsAreSilent() {
        service.syncOnInbound(null, WAREHOUSE_A);
        service.syncOnInbound(GOODS_PLAIN, null);
        service.syncOnInbound(GOODS_ABSENT, WAREHOUSE_A);
        assertNull(owningWarehouse(GOODS_PLAIN));
    }

    @Test
    void directTransferNeverLearnsWorkshopLocationAsOrdinaryStorage() {
        service.syncOnInbound(GOODS_AT_A, LINE_SIDE);
        service.syncOnInbound(GOODS_PLAIN, LINE_SIDE);
        assertEquals(WAREHOUSE_A, owningWarehouse(GOODS_AT_A));
        assertNull(owningWarehouse(GOODS_PLAIN));
        assertEquals(0L, version(GOODS_AT_A));
        assertEquals(0L, version(GOODS_PLAIN));
        service.syncOnInbound(GOODS_AT_A, WAREHOUSE_B);
        assertEquals(WAREHOUSE_B, owningWarehouse(GOODS_AT_A));
    }

    @Test
    void completePostingScopeRejectsLateGoodsButDoesNotLeakToTheNextTransaction() {
        var transactions = transactions();
        transactions.executeWithoutResult(status -> {
            inventory.lock(new InventoryKey(GOODS_AT_A, null));
            service.lockForPosting(inventory);
            assertThrows(com.uten.imp.common.web.ApiException.class, () ->
                    GoodsOwningWarehouseSyncService.requireDeclaredInventory(
                            java.util.List.of(new InventoryKey(GOODS_PLAIN, null))));
            service.syncOnInbound(GOODS_AT_A, WAREHOUSE_B);
        });
        transactions.executeWithoutResult(status -> {
            inventory.lock(new InventoryKey(GOODS_PLAIN, null)); service.lockForPosting(inventory);
            service.syncOnInbound(GOODS_PLAIN, WAREHOUSE_A);
        });
        assertEquals(WAREHOUSE_B, owningWarehouse(GOODS_AT_A));
        assertEquals(WAREHOUSE_A, owningWarehouse(GOODS_PLAIN));
    }

    @Test
    void savepointRollbackRequiresTheGoodsLocksToBeTakenAgain() {
        var transactions = transactions();
        var scope = java.util.List.of(new InventoryKey(GOODS_AT_A, null), new InventoryKey(GOODS_PLAIN, null));
        transactions.executeWithoutResult(status -> {
            Object savepoint = status.createSavepoint();
            inventory.lockAll(scope); service.lockForPosting(inventory);
            assertGoodsRowLocked(true);
            status.rollbackToSavepoint(savepoint);
            assertGoodsRowLocked(false);
            for (InventoryKey key : scope) {
                assertThrows(IllegalStateException.class, () -> inventory.requireHeld(key));
                assertInventoryLocked(key, false);
            }
            assertThrows(com.uten.imp.common.web.ApiException.class, () -> service.syncOnInbound(GOODS_AT_A, WAREHOUSE_B));
            inventory.lockAll(scope); service.lockForPosting(inventory);
            assertGoodsRowLocked(true);
            for (InventoryKey key : scope) assertInventoryLocked(key, true);
        });
    }

    @Test void savepointKeepsEarlierInventoryProofAndDropsLaterGoodsAndColorProof() {
        var first = new InventoryKey(GOODS_PLAIN, UUID.randomUUID());
        var later = new InventoryKey(GOODS_AT_A, UUID.randomUUID());
        transactions().executeWithoutResult(status -> {
            inventory.lock(first);
            Object checkpoint = status.createSavepoint();
            inventory.lock(later);
            service.lockForPosting(inventory);
            status.rollbackToSavepoint(checkpoint);
            inventory.requireHeld(first); assertInventoryLocked(first, true);
            assertThrows(IllegalStateException.class, () -> inventory.requireHeld(later));
            assertInventoryLocked(later, false); assertGoodsRowLocked(false);
            inventory.lockAll(java.util.List.of(first, later)); service.lockForPosting(inventory);
            assertInventoryLocked(first, true); assertInventoryLocked(later, true); assertGoodsRowLocked(true);
        });
    }

    @Test void lateColorIsRejectedBeforeWaitingOnAnAdvisoryLockAndRequiresNewDoesNotInheritTheFence() {
        var red = new InventoryKey(GOODS_AT_A, UUID.randomUUID());
        var blue = new InventoryKey(GOODS_AT_A, UUID.randomUUID());
        transactions().executeWithoutResult(status -> {
            inventory.lock(red); service.lockForPosting(inventory);
            try (var blocker = jdbc.getDataSource().getConnection()) {
                blocker.setAutoCommit(false);
                try (var lock = blocker.prepareStatement("SELECT pg_advisory_xact_lock(hashtextextended(?,?))")) {
                    lock.setString(1, blue.canonical()); lock.setLong(2, InventoryMutationLock.HASH_NAMESPACE);
                    lock.executeQuery().close();
                    jdbc.execute("SET LOCAL lock_timeout='250ms'");
                    assertThrows(com.uten.imp.common.web.ApiException.class, () -> inventory.lock(blue));
                    assertEquals(1, jdbc.queryForObject("SELECT 1", Integer.class), "Failure must precede SQL and leave this transaction valid");
                } finally { blocker.rollback(); }
            } catch (java.sql.SQLException failure) { throw new AssertionError(failure); }
            var nested = transactions();
            nested.setPropagationBehavior(org.springframework.transaction.TransactionDefinition.PROPAGATION_REQUIRES_NEW);
            nested.executeWithoutResult(inner -> {
                inventory.lock(new InventoryKey(GOODS_PLAIN, null)); service.lockForPosting(inventory);
                service.syncOnInbound(GOODS_PLAIN, WAREHOUSE_A);
            });
            inventory.requireHeld(red);
            assertThrows(com.uten.imp.common.web.ApiException.class, () -> inventory.lock(blue));
            service.syncOnInbound(GOODS_AT_A, WAREHOUSE_B);
        });
    }

    @Test void afterCommitCannotReusePostingOwnershipEvenWhenTheCallbackWasRegisteredFirst() {
        var rejected = new java.util.concurrent.atomic.AtomicBoolean();
        transactions().executeWithoutResult(status -> {
            org.springframework.transaction.support.TransactionSynchronizationManager.registerSynchronization(
                    new org.springframework.transaction.support.TransactionSynchronization() {
                        @Override public void afterCommit() {
                            assertThrows(com.uten.imp.common.web.ApiException.class,
                                    () -> service.syncOnInbound(GOODS_AT_A, WAREHOUSE_B));
                            rejected.set(true);
                        }
                    });
            inventory.lock(new InventoryKey(GOODS_AT_A, null)); service.lockForPosting(inventory);
        });
        assertEquals(true, rejected.get());
        assertEquals(WAREHOUSE_A, owningWarehouse(GOODS_AT_A));
    }

    private static org.springframework.transaction.support.TransactionTemplate transactions() {
        var manager = new org.springframework.orm.jpa.JpaTransactionManager(entityManagers);
        manager.setNestedTransactionAllowed(true);
        return new org.springframework.transaction.support.TransactionTemplate(manager);
    }

    private void assertInventoryLocked(InventoryKey key, boolean expected) {
        try (var connection = jdbc.getDataSource().getConnection()) {
            connection.setAutoCommit(false);
            try (var statement = connection.prepareStatement("SELECT pg_try_advisory_xact_lock(hashtextextended(?,?))")) {
                statement.setString(1, key.canonical()); statement.setLong(2, InventoryMutationLock.HASH_NAMESPACE);
                try (var result = statement.executeQuery()) { result.next(); assertEquals(!expected, result.getBoolean(1)); }
            } finally { connection.rollback(); }
        } catch (java.sql.SQLException failure) { throw new AssertionError(failure); }
    }

    private void assertGoodsRowLocked(boolean expected) {
        try (var connection = java.util.Objects.requireNonNull(jdbc.getDataSource()).getConnection()) {
            connection.setAutoCommit(false);
            try (var statement = connection.prepareStatement("SELECT id FROM goods WHERE id=? FOR UPDATE NOWAIT")) {
                statement.setObject(1, GOODS_AT_A);
                try {
                    statement.executeQuery().close();
                    assertEquals(false, expected, "a second transaction unexpectedly acquired the row");
                } catch (java.sql.SQLException failure) {
                    assertEquals("55P03", failure.getSQLState());
                    assertEquals(true, expected);
                } finally { connection.rollback(); }
            }
        } catch (java.sql.SQLException failure) { throw new AssertionError(failure); }
    }

    private UUID owningWarehouse(UUID goodsId) {
        return jdbc.queryForObject(
                "SELECT owning_warehouse_id FROM goods WHERE id = ?", UUID.class, goodsId);
    }

    private long version(UUID goodsId) {
        return jdbc.queryForObject(
                "SELECT version FROM goods WHERE id = ?", Long.class, goodsId);
    }
}
