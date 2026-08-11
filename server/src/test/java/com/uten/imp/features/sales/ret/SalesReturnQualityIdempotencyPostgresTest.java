package com.uten.imp.features.sales.ret;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.ret.dto.ReturnQualityDispositionRequest;
import com.uten.imp.features.sales.ret.dto.ReturnQualityItemDto;
import com.uten.imp.features.stock.InventoryMutationLock;
import com.uten.imp.features.stock.StockBalanceRepository;
import com.uten.imp.features.stock.StockMovement;
import com.uten.imp.features.stock.StockMovementRepository;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.Duration;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.Properties;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.function.Consumer;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTimeoutPreemptively;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.spy;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Real PostgreSQL evidence for sales-return quality disposition idempotency.
 *
 * <p>The production StockService runs unchanged. Transaction-bound test adapters
 * persist its repository writes into the real stock movement and balance tables,
 * so the test covers quality state, event evidence, stock posting, and rollback
 * without loading unrelated application security or schedulers.
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SalesReturnQualityIdempotencyPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");
    private static final UUID ACTOR_ID =
            UUID.fromString("10000000-0000-0000-0000-000000000001");

    private static JdbcTemplate jdbc;
    private static EntityManagerFactory entityManagerFactory;
    private static EntityManager entityManager;
    private static TransactionTemplate transactions;

    private StockService stockService;
    private SalesReturnRepository returnRepository;
    private SalesReturnQualityService service;
    private Consumer<StockService.MovementRequest> movementHook;

    @BeforeAll
    static void migrateAndCreateHarness() {
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
        jdbc = new JdbcTemplate(dataSource);
        jdbc.execute("""
                CREATE OR REPLACE FUNCTION test_reject_quality_disposition_event()
                RETURNS trigger
                LANGUAGE plpgsql
                AS $$
                BEGIN
                    IF NEW.reason = 'force-late-failure' THEN
                        RAISE EXCEPTION 'forced late disposition failure';
                    END IF;
                    RETURN NEW;
                END;
                $$
                """);
        jdbc.execute("""
                CREATE TRIGGER trg_test_reject_quality_disposition_event
                BEFORE INSERT ON sales_return_quality_events
                FOR EACH ROW
                EXECUTE FUNCTION test_reject_quality_disposition_event()
                """);

        LocalContainerEntityManagerFactoryBean factory =
                new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(dataSource);
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setPackagesToScan("com.uten.imp.features.sales.ret");
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
    static void stopPostgres() {
        if (entityManagerFactory != null) {
            entityManagerFactory.close();
        }
        POSTGRES.stop();
    }

    @BeforeEach
    void setUp() {
        SecurityContextCurrentUser currentUser =
                mock(SecurityContextCurrentUser.class);
        TxSessionVars tx = mock(TxSessionVars.class);
        returnRepository = mock(SalesReturnRepository.class);
        SalesDocumentAccessPolicy accessPolicy =
                mock(SalesDocumentAccessPolicy.class);
        StockMovementRepository movementRepository =
                mock(StockMovementRepository.class);
        StockBalanceRepository balanceRepository =
                mock(StockBalanceRepository.class);
        movementHook = ignored -> {
        };

        when(currentUser.requireEmployeeId()).thenReturn(ACTOR_ID);
        when(movementRepository.save(any(StockMovement.class)))
                .thenAnswer(invocation -> {
                    StockMovement movement = invocation.getArgument(
                            0, StockMovement.class);
                    entityManager.createNativeQuery("""
                                    INSERT INTO stock_movements (
                                        id, transaction_date, movement_type,
                                        source_doc_type, source_doc_id, source_item_id,
                                        goods_id, color_id, warehouse_id, direction, qty,
                                        unit_id, unit_rate, amount_local, remark,
                                        created_at, updated_at
                                    ) VALUES (
                                        :id, :transactionDate, :movementType,
                                        :sourceDocType, :sourceDocId, :sourceItemId,
                                        :goodsId, CAST(:colorId AS uuid), :warehouseId,
                                        :direction, :qty, CAST(:unitId AS uuid),
                                        :unitRate, :amountLocal, :remark, now(), now()
                                    )
                                    """)
                            .setParameter("id", movement.getId())
                            .setParameter("transactionDate",
                                    movement.getTransactionDate())
                            .setParameter("movementType",
                                    movement.getMovementType())
                            .setParameter("sourceDocType",
                                    movement.getSourceDocType())
                            .setParameter("sourceDocId",
                                    movement.getSourceDocId())
                            .setParameter("sourceItemId",
                                    movement.getSourceItemId())
                            .setParameter("goodsId", movement.getGoodsId())
                            .setParameter("colorId", movement.getColorId())
                            .setParameter("warehouseId",
                                    movement.getWarehouseId())
                            .setParameter("direction", movement.getDirection())
                            .setParameter("qty", movement.getQty())
                            .setParameter("unitId", movement.getUnitId())
                            .setParameter("unitRate", movement.getUnitRate())
                            .setParameter("amountLocal",
                                    movement.getAmountLocal())
                            .setParameter("remark", movement.getRemark())
                            .executeUpdate();
                    return movement;
                });
        doAnswer(invocation -> {
            UUID warehouseId = invocation.getArgument(0, UUID.class);
            UUID goodsId = invocation.getArgument(1, UUID.class);
            UUID colorId = invocation.getArgument(2, UUID.class);
            BigDecimal quantity = invocation.getArgument(3, BigDecimal.class);
            BigDecimal amount = invocation.getArgument(4, BigDecimal.class);
            OffsetDateTime movementAt = invocation.getArgument(
                    6, OffsetDateTime.class);
            entityManager.createNativeQuery("""
                            INSERT INTO stock_balances (
                                id, warehouse_id, goods_id, color_id, qty,
                                amount_local, last_movement_date, created_at, updated_at
                            ) VALUES (
                                gen_random_uuid(), :warehouseId, :goodsId,
                                CAST(:colorId AS uuid), :qty, :amount,
                                :movementAt, now(), now()
                            )
                            ON CONFLICT (warehouse_id, goods_id, color_id)
                            DO UPDATE SET
                                qty = stock_balances.qty + EXCLUDED.qty,
                                amount_local = COALESCE(
                                    stock_balances.amount_local, 0)
                                    + EXCLUDED.amount_local,
                                last_movement_date = EXCLUDED.last_movement_date,
                                updated_at = now()
                            """)
                    .setParameter("warehouseId", warehouseId)
                    .setParameter("goodsId", goodsId)
                    .setParameter("colorId", colorId)
                    .setParameter("qty", quantity)
                    .setParameter("amount", amount)
                    .setParameter("movementAt", movementAt)
                    .executeUpdate();
            return null;
        }).when(balanceRepository).upsertBalance(
                any(), any(), any(), any(), any(), any(), any());

        StockService realStockService = new StockService(
                movementRepository,
                balanceRepository,
                tx,
                new InventoryMutationLock(entityManager));
        stockService = spy(realStockService);
        doAnswer(invocation -> {
            StockService.MovementRequest request =
                    invocation.getArgument(0, StockService.MovementRequest.class);
            Object result = invocation.callRealMethod();
            movementHook.accept(request);
            return result;
        }).when(stockService).recordMovement(
                any(StockService.MovementRequest.class));

        service = new SalesReturnQualityService(
                entityManager,
                stockService,
                currentUser,
                tx,
                returnRepository,
                accessPolicy);
    }

    @Test
    void firstCommandAndExactReplayCommitOneStockEffectAndOneEvent() {
        Fixture fixture = seedFixture();
        ReturnQualityDispositionRequest request = request(
                "GOOD_RELEASE", "2.0000", "inspection-pass", "quality-pg-replay-001");

        List<ReturnQualityItemDto> first = dispose(fixture, request);
        List<ReturnQualityItemDto> replay = dispose(fixture, request);

        assertEquals(0, new BigDecimal("2").compareTo(
                first.getFirst().releasedBaseQty()));
        assertEquals(0, new BigDecimal("2").compareTo(
                replay.getFirst().releasedBaseQty()));
        assertEquals(0, new BigDecimal("2").compareTo(
                releasedQuantity(fixture.qualityItemId())));
        assertEquals(1L, dispositionEventCount(fixture.qualityItemId()));
        assertEquals(1L, stockEffectCount(fixture.returnId()));
        assertEquals(0, new BigDecimal("2").compareTo(balanceQuantity(fixture)));
        assertEquals(0, new BigDecimal("2").compareTo(balanceAmount(fixture)));
        verify(stockService).recordMovement(
                any(StockService.MovementRequest.class));
    }

    @Test
    void sameKeyRejectsEveryDifferentPayloadBeforeAnotherStockEffect() {
        Fixture fixture = seedFixture();
        String key = "quality-pg-conflict-001";
        dispose(fixture, request(
                "GOOD_RELEASE", "1", "inspection-pass", key));

        ApiException differentQuantity = assertThrows(
                ApiException.class,
                () -> dispose(fixture, request(
                        "GOOD_RELEASE", "2", "inspection-pass", key)));
        ApiException differentAction = assertThrows(
                ApiException.class,
                () -> dispose(fixture, request(
                        "SCRAP", "1", "inspection-pass", key)));
        ApiException differentReason = assertThrows(
                ApiException.class,
                () -> dispose(fixture, request(
                        "GOOD_RELEASE", "1", "different-reason", key)));

        assertEquals(ErrorCode.CONFLICT, differentQuantity.getCode());
        assertEquals(ErrorCode.CONFLICT, differentAction.getCode());
        assertEquals(ErrorCode.CONFLICT, differentReason.getCode());
        assertEquals(1L, dispositionEventCount(fixture.qualityItemId()));
        assertEquals(1L, stockEffectCount(fixture.returnId()));
        assertEquals(0, BigDecimal.ONE.compareTo(balanceQuantity(fixture)));
        assertEquals(0, BigDecimal.ONE.compareTo(balanceAmount(fixture)));
        assertEquals(0, BigDecimal.ONE.compareTo(
                releasedQuantity(fixture.qualityItemId())));
    }

    @Test
    void concurrentExactReplaySerializesOnQualityRowAndCommitsOnce() {
        assertTimeoutPreemptively(Duration.ofSeconds(20), () -> {
            Fixture fixture = seedFixture();
            ReturnQualityDispositionRequest request = request(
                    "GOOD_RELEASE", "1", "inspection-pass", "quality-pg-race-001");
            CountDownLatch firstReachedMovement = new CountDownLatch(1);
            CountDownLatch allowFirstCommit = new CountDownLatch(1);
            AtomicBoolean firstMovement = new AtomicBoolean(true);
            movementHook = ignored -> {
                if (!firstMovement.compareAndSet(true, false)) {
                    return;
                }
                firstReachedMovement.countDown();
                try {
                    if (!allowFirstCommit.await(5, TimeUnit.SECONDS)) {
                        throw new AssertionError(
                                "timed out waiting to release the first transaction");
                    }
                } catch (InterruptedException error) {
                    Thread.currentThread().interrupt();
                    throw new AssertionError(error);
                }
            };

            try (ExecutorService executor = Executors.newFixedThreadPool(2)) {
                Future<List<ReturnQualityItemDto>> first =
                        executor.submit(() -> dispose(fixture, request));
                if (!firstReachedMovement.await(5, TimeUnit.SECONDS)) {
                    throw new AssertionError(
                            "the first transaction did not reach the stock effect");
                }
                Future<List<ReturnQualityItemDto>> second =
                        executor.submit(() -> dispose(fixture, request));

                Thread.sleep(300);
                assertFalse(
                        second.isDone(),
                        "the replay must wait for the first quality-row transaction");

                allowFirstCommit.countDown();
                assertEquals(0, BigDecimal.ONE.compareTo(
                        first.get(5, TimeUnit.SECONDS)
                                .getFirst()
                                .releasedBaseQty()));
                assertEquals(0, BigDecimal.ONE.compareTo(
                        second.get(5, TimeUnit.SECONDS)
                                .getFirst()
                                .releasedBaseQty()));
            } finally {
                allowFirstCommit.countDown();
            }

            assertEquals(1L, dispositionEventCount(fixture.qualityItemId()));
            assertEquals(1L, stockEffectCount(fixture.returnId()));
            assertEquals(0, BigDecimal.ONE.compareTo(balanceQuantity(fixture)));
            assertEquals(0, BigDecimal.ONE.compareTo(balanceAmount(fixture)));
            assertEquals(0, BigDecimal.ONE.compareTo(
                    releasedQuantity(fixture.qualityItemId())));
        });
    }

    @Test
    void lateEventFailureRollsBackStockEffectAndQualityProjection() {
        Fixture fixture = seedFixture();

        assertThrows(
                RuntimeException.class,
                () -> dispose(fixture, request(
                        "GOOD_RELEASE",
                        "3",
                        "force-late-failure",
                        "quality-pg-rollback-001")));

        assertEquals(0L, dispositionEventCount(fixture.qualityItemId()));
        assertEquals(0L, stockEffectCount(fixture.returnId()));
        assertEquals(0, BigDecimal.ZERO.compareTo(balanceQuantity(fixture)));
        assertEquals(0, BigDecimal.ZERO.compareTo(balanceAmount(fixture)));
        assertEquals(0, BigDecimal.ZERO.compareTo(
                releasedQuantity(fixture.qualityItemId())));
    }

    private List<ReturnQualityItemDto> dispose(
            Fixture fixture,
            ReturnQualityDispositionRequest request) {
        List<ReturnQualityItemDto> result = transactions.execute(status ->
                service.dispose(
                        fixture.returnId(),
                        fixture.returnItemId(),
                        request));
        return result == null ? List.of() : result;
    }

    private Fixture seedFixture() {
        UUID returnId = UUID.randomUUID();
        UUID returnItemId = UUID.randomUUID();
        UUID qualityItemId = UUID.randomUUID();
        UUID clientId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        String suffix = returnId.toString().substring(0, 8);
        String billNo = "XT-QUALITY-" + suffix;

        jdbc.update(
                "INSERT INTO clients(id, name) VALUES (?, ?)",
                clientId,
                "Quality test client " + suffix);
        jdbc.update(
                "INSERT INTO warehouses(id, code, name) VALUES (?, ?, ?)",
                warehouseId,
                "QW-" + suffix,
                "Quality test warehouse " + suffix);
        jdbc.update(
                "INSERT INTO goods(id, code, name) VALUES (?, ?, ?)",
                goodsId,
                "QG-" + suffix,
                "Quality test goods " + suffix);
        jdbc.update("""
                INSERT INTO sales_returns (
                    id, bill_no, bill_date, client_id, warehouse_id,
                    total_original, total_local, status
                ) VALUES (
                    ?, ?, CURRENT_DATE, ?, ?, 10, 10, 1
                )
                """,
                returnId,
                billNo,
                clientId,
                warehouseId);
        jdbc.update("""
                INSERT INTO sales_return_items (
                    id, bill_no, bill_date, return_id, line_no,
                    goods_id, unit_rate, qty, amount_original, amount_local
                ) VALUES (
                    ?, ?, CURRENT_DATE, ?, 1, ?, 1, 10, 10, 10
                )
                """,
                returnItemId,
                billNo,
                returnId,
                goodsId);
        jdbc.update("""
                INSERT INTO sales_return_quality_items (
                    id, return_id, return_item_id, warehouse_id, goods_id,
                    unit_rate, received_base_qty
                ) VALUES (
                    ?, ?, ?, ?, ?, 1, 10
                )
                """,
                qualityItemId,
                returnId,
                returnItemId,
                warehouseId,
                goodsId);
        jdbc.update("""
                INSERT INTO sales_return_quality_events (
                    id, quality_item_id, action, base_qty, reason
                ) VALUES (
                    ?, ?, 'RECEIVED', 10, NULL
                )
                """,
                UUID.randomUUID(),
                qualityItemId);

        SalesReturn salesReturn = new SalesReturn();
        salesReturn.setId(returnId);
        salesReturn.setStatus((short) 1);
        when(returnRepository.findById(returnId))
                .thenReturn(Optional.of(salesReturn));

        return new Fixture(returnId, returnItemId, qualityItemId, warehouseId, goodsId);
    }

    private static ReturnQualityDispositionRequest request(
            String action,
            String quantity,
            String reason,
            String key) {
        return new ReturnQualityDispositionRequest(
                action,
                new BigDecimal(quantity),
                reason,
                key);
    }

    private static BigDecimal releasedQuantity(UUID qualityItemId) {
        BigDecimal quantity = jdbc.queryForObject(
                """
                        SELECT released_base_qty
                        FROM sales_return_quality_items
                        WHERE id = ?
                        """,
                BigDecimal.class,
                qualityItemId);
        return quantity == null ? BigDecimal.ZERO : quantity;
    }

    private static long dispositionEventCount(UUID qualityItemId) {
        Long count = jdbc.queryForObject(
                """
                        SELECT COUNT(*)
                        FROM sales_return_quality_events
                        WHERE quality_item_id = ?
                          AND action IN ('GOOD_RELEASE', 'SCRAP', 'REWORK')
                        """,
                Long.class,
                qualityItemId);
        return count == null ? 0 : count;
    }

    private static long stockEffectCount(UUID returnId) {
        Long count = jdbc.queryForObject(
                """
                        SELECT COUNT(*)
                        FROM stock_movements
                        WHERE source_doc_id = ?
                          AND source_doc_type = 'SALES_RETURN'
                        """,
                Long.class,
                returnId);
        return count == null ? 0 : count;
    }

    private static BigDecimal balanceQuantity(Fixture fixture) {
        BigDecimal quantity = jdbc.queryForObject(
                """
                        SELECT COALESCE(SUM(qty), 0)
                        FROM stock_balances
                        WHERE warehouse_id = ?
                          AND goods_id = ?
                          AND color_id IS NULL
                        """,
                BigDecimal.class,
                fixture.warehouseId(),
                fixture.goodsId());
        return quantity == null ? BigDecimal.ZERO : quantity;
    }

    private static BigDecimal balanceAmount(Fixture fixture) {
        BigDecimal amount = jdbc.queryForObject(
                """
                        SELECT COALESCE(SUM(amount_local), 0)
                        FROM stock_balances
                        WHERE warehouse_id = ?
                          AND goods_id = ?
                          AND color_id IS NULL
                        """,
                BigDecimal.class,
                fixture.warehouseId(),
                fixture.goodsId());
        return amount == null ? BigDecimal.ZERO : amount;
    }

    private record Fixture(
            UUID returnId,
            UUID returnItemId,
            UUID qualityItemId,
            UUID warehouseId,
            UUID goodsId) {
    }
}
