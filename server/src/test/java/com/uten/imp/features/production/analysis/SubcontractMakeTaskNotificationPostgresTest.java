package com.uten.imp.features.production.analysis;

import com.uten.imp.application.port.ProductionSubcontractRequestPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.persistence.EntityManager;
import org.flywaydb.core.Flyway;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.springframework.transaction.support.TransactionTemplate;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.function.Function;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real migrated task/action/batch transactions; the application port writes its minimal document fixture. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SubcontractMakeTaskNotificationPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static final UUID UNIT = UUID.randomUUID();
    private static final UUID GOODS = UUID.randomUUID();
    private static final UUID WAREHOUSE = UUID.randomUUID();
    private static final UUID ACTOR = UUID.randomUUID();
    private static UUID owner;
    private static JdbcTemplate jdbc;
    private static TransactionTemplate setupTransaction;
    private static SessionFactory sessions;
    private static Fixture historical;
    private static Map<String, Object> historicalBefore;

    @BeforeAll
    static void migrateHistoryAndStart() {
        POSTGRES.start();
        Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").target("491").load().migrate();
        DriverManagerDataSource dataSource = new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        jdbc = new JdbcTemplate(dataSource);
        setupTransaction = new TransactionTemplate(new DataSourceTransactionManager(dataSource));
        owner = jdbc.queryForObject("SELECT id FROM employees ORDER BY id LIMIT 1", UUID.class);
        jdbc.update("INSERT INTO users(id,employee_id,login_account,password_hash,status) VALUES(?,?,?,'test','active')",
                ACTOR, owner, "sc-batch-" + ACTOR);
        jdbc.update("INSERT INTO units(id,code,name) VALUES(?,?,'piece')", UNIT, "SC-BATCH-U-" + UNIT);
        jdbc.update("INSERT INTO warehouses(id,code,name,status,is_accountable) VALUES(?,?,'SC batch warehouse','使用',TRUE)",
                WAREHOUSE, "SC-BATCH-W-" + WAREHOUSE);
        jdbc.update("""
                INSERT INTO goods(id,code,name,unit_id,code_sequence,source_type)
                VALUES(?,?,'SC batch material',?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods),'委外')
                """, GOODS, "SC-BATCH-G-" + GOODS, UNIT);
        historical = fixture();
        historicalBefore = jdbc.queryForMap("SELECT * FROM preplan_subcontract_make_tasks WHERE id=?", historical.task());
        Flyway.configure().dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration").load().migrate();
        sessions = new Configuration().setProperty("hibernate.connection.driver_class", "org.postgresql.Driver")
                .setProperty("hibernate.connection.url", POSTGRES.getJdbcUrl())
                .setProperty("hibernate.connection.username", POSTGRES.getUsername())
                .setProperty("hibernate.connection.password", POSTGRES.getPassword())
                .setProperty("hibernate.hbm2ddl.auto", "none").buildSessionFactory();
    }

    @AfterAll
    static void stop() {
        if (sessions != null) sessions.close();
        POSTGRES.stop();
    }

    @Test
    void migrationPreservesHistoricalTaskAndFullAudit() {
        assertThat(jdbc.queryForMap("SELECT * FROM preplan_subcontract_make_tasks WHERE id=?", historical.task()))
                .isEqualTo(historicalBefore);
        jdbc.execute("SELECT fn_assert_subcontract_make_task_batches()");
    }

    @Test
    void sequentialBatchesAdvanceGenerationAndReplayBeforeAvailableCheck() {
        Fixture f = fixture();
        var first = notify(f, "batch-first-0001", "4");
        var second = notify(f, "batch-second-0002", "6");
        var replay = notify(f, "batch-first-0001", "4.0000");

        assertThat(replay.applicationId()).isEqualTo(first.applicationId());
        assertThat(second.availableQty()).isZero();
        assertThat(jdbc.queryForList("SELECT generation FROM preplan_supply_actions WHERE analysis_id=? ORDER BY generation",
                Integer.class, f.analysis())).containsExactly(1, 2, 3);
        assertThat(jdbc.queryForObject("SELECT notified_qty FROM preplan_subcontract_make_tasks WHERE id=?",
                BigDecimal.class, f.task())).isEqualByComparingTo("10");
        assertThatThrownBy(() -> notify(f, "batch-first-0001", "3"))
                .isInstanceOf(ApiException.class).hasMessageContaining("幂等键");
        assertThat(batchCount(f)).isEqualTo(2);
    }

    @Test
    void replayStillRequiresObjectWritePermission() {
        Fixture f = fixture();
        notify(f, "batch-private-0001", "2");
        assertThatThrownBy(() -> inTransaction(em -> service(em, true)
                .notifyBatch(f.task(), new SubcontractMakeTaskService.NotifyRequest(new BigDecimal("2"), "batch-private-0001"))))
                .isInstanceOf(ApiException.class).hasMessageContaining("not the analysis owner");
        assertThat(batchCount(f)).isEqualTo(1);
    }

    @Test
    void concurrentSameKeyReturnsOneApplication() throws Exception {
        Fixture f = fixture();
        CountDownLatch start = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(2)) {
            var a = pool.submit(() -> { start.await(); return notify(f, "concurrent-replay", "6"); });
            var b = pool.submit(() -> { start.await(); return notify(f, "concurrent-replay", "6"); });
            start.countDown();
            assertThat(a.get(20, TimeUnit.SECONDS).applicationId()).isEqualTo(b.get(20, TimeUnit.SECONDS).applicationId());
        }
        assertThat(batchCount(f)).isEqualTo(1);
    }

    @Test
    void differentTasksCommitIndependentlyAndCannotHideLocalImbalance() throws Exception {
        Fixture a = fixture();
        Fixture b = fixture();
        try (EntityManager held = sessions.createEntityManager()) {
            held.getTransaction().begin();
            held.createNativeQuery("SELECT id FROM preplan_subcontract_make_tasks WHERE id=:id FOR UPDATE")
                    .setParameter("id", a.task()).getSingleResult();
            try (var pool = Executors.newSingleThreadExecutor()) {
                assertThat(pool.submit(() -> notify(b, "independent-task", "3"))
                        .get(10, TimeUnit.SECONDS).notifiedQty()).isEqualByComparingTo("3");
            } finally {
                held.getTransaction().rollback();
            }
        }
        assertThatThrownBy(() -> jdbc.update("UPDATE preplan_subcontract_make_tasks SET notified_qty=1 WHERE id=?", a.task()))
                .hasStackTraceContaining("subcontract make task notified qty lacks exact batch coverage");
        assertThat(batchCount(a)).isZero();
        assertThat(batchCount(b)).isEqualTo(1);
    }

    @Test
    void historicalBatchCannotBeMovedBetweenTasks() {
        Fixture a = fixture();
        Fixture b = fixture();
        notify(a, "move-batch-origin", "2");
        assertThatThrownBy(() -> setupTransaction.executeWithoutResult(unused -> {
            jdbc.update("UPDATE preplan_subcontract_make_task_batches SET task_id=? WHERE task_id=?", b.task(), a.task());
            jdbc.update("UPDATE preplan_subcontract_make_tasks SET notified_qty=2 WHERE id=?", b.task());
        })).hasStackTraceContaining("subcontract make notification facts are append-only");
        assertThat(batchCount(a)).isEqualTo(1);
        assertThat(batchCount(b)).isZero();
    }

    @Test
    void reversalRequiresClosedApplicationAndPreservesOriginalFacts() {
        Fixture f = fixture();
        var batch = notify(f,"reversal-original","4");
        assertThat(futureCoverage(f)).isEqualByComparingTo("10");
        assertThatThrownBy(() -> inTransaction(em -> {
            service(em,false).reverseNotificationBatchesForApplication(batch.applicationId(),"Premature reversal");
            return null;
        })).hasStackTraceContaining("subcontract notification still has active commercial or physical execution");
        closeApplication(batch.applicationId());
        inTransaction(em -> {
            service(em,false).reverseNotificationBatchesForApplication(batch.applicationId(),"Cancelled supply request");
            service(em,false).reverseNotificationBatchesForApplication(batch.applicationId(),"Cancelled supply request");
            return null;
        });
        assertThat(jdbc.queryForObject("SELECT notified_qty FROM preplan_subcontract_make_tasks WHERE id=?",
                BigDecimal.class,f.task())).isZero();
        assertThat(jdbc.queryForObject("SELECT SUM(qty) FROM preplan_subcontract_make_batch_reversals WHERE task_id=?",
                BigDecimal.class,f.task())).isEqualByComparingTo("4");
        assertThat(jdbc.queryForObject("SELECT SUM(notify_qty) FROM preplan_subcontract_make_task_batches WHERE task_id=?",
                BigDecimal.class,f.task())).isEqualByComparingTo("4");
        assertThat(futureCoverage(f)).isEqualByComparingTo("10");
        assertThatThrownBy(() -> notify(f,"reversal-original","4"))
                .isInstanceOf(ApiException.class).hasMessageContaining("已撤回");
        notify(f,"reversal-new-request","4");
        assertThat(futureCoverage(f)).isEqualByComparingTo("10");
        assertThatThrownBy(() -> jdbc.update(
                "UPDATE preplan_subcontract_make_batch_reversals SET qty=1 WHERE task_id=?",f.task()))
                .hasStackTraceContaining("subcontract make notification facts are append-only");
    }

    @Test
    void concurrentReversalRecordsAndDebitsOneBatch() throws Exception {
        Fixture f = fixture();
        var batch = notify(f,"reverse-concurrent-original","4");
        closeApplication(batch.applicationId());
        CountDownLatch start = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(2)) {
            java.util.concurrent.Callable<Void> reversal = () -> {
                start.await();
                return inTransaction(em -> {
                    service(em,false).reverseNotificationBatchesForApplication(batch.applicationId(),"Concurrent cancellation");
                    return null;
                });
            };
            var a = pool.submit(reversal);
            var b = pool.submit(reversal);
            start.countDown();
            a.get(20,TimeUnit.SECONDS);
            b.get(20,TimeUnit.SECONDS);
        }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM preplan_subcontract_make_batch_reversals WHERE task_id=?",
                Long.class,f.task())).isEqualTo(1);
        assertThat(jdbc.queryForObject("SELECT notified_qty FROM preplan_subcontract_make_tasks WHERE id=?",
                BigDecimal.class,f.task())).isZero();
    }

    private static void closeApplication(UUID applicationId) {
        setupTransaction.executeWithoutResult(unused -> {
            jdbc.update("UPDATE subcontract_applications SET status=-1,is_closed=TRUE WHERE id=?",applicationId);
            jdbc.update("""
                    UPDATE preplan_supply_actions SET status='CANCELLED',cancelled_by=?,cancelled_at=now(),
                        cancellation_reason='Cancelled supply request' WHERE external_document_id=?
                    """,ACTOR,applicationId);
        });
    }

    private static BigDecimal futureCoverage(Fixture f) {
        UUID material = jdbc.queryForObject("SELECT analysis_material_id FROM preplan_subcontract_make_tasks WHERE id=?",
                UUID.class,f.task());
        return inTransaction(em -> {
            MaterialAnalysisService service = new MaterialAnalysisService(em,null,null,null,null,null,null,null,null,
                com.uten.imp.support.FulfillmentMutationLockTestSupport.locks(),
                org.mockito.Mockito.mock(com.uten.imp.application.port.ProductionMutationFootprintPort.class));
            try {
                var method = MaterialAnalysisService.class.getDeclaredMethod("activeFutureCoverageByMaterial",UUID.class);
                method.setAccessible(true);
                Map<?,?> coverage = (Map<?,?>)method.invoke(service,f.analysis());
                return (BigDecimal)coverage.get(material);
            } catch (ReflectiveOperationException ex) {
                throw new AssertionError(ex);
            }
        });
    }

    private static long batchCount(Fixture f) {
        return jdbc.queryForObject("SELECT COUNT(*) FROM preplan_subcontract_make_task_batches WHERE task_id=?", Long.class, f.task());
    }

    private static SubcontractMakeTaskService.NotifyResult notify(Fixture f, String key, String qty) {
        return inTransaction(em -> service(em, false).notifyBatch(f.task(),
                new SubcontractMakeTaskService.NotifyRequest(new BigDecimal(qty), key)));
    }

    private static <T> T inTransaction(Function<EntityManager, T> command) {
        try (EntityManager em = sessions.createEntityManager()) {
            em.getTransaction().begin();
            try {
                T result = command.apply(em);
                em.getTransaction().commit();
                return result;
            } catch (RuntimeException ex) {
                if (em.getTransaction().isActive()) em.getTransaction().rollback();
                throw ex;
            }
        }
    }

    private static SubcontractMakeTaskService service(EntityManager em, boolean forbidden) {
        MaterialAnalysisService analyses = mock(MaterialAnalysisService.class);
        when(analyses.lockHeader(any())).thenAnswer(call -> {
            UUID analysis = call.getArgument(0);
            em.createNativeQuery("SELECT id FROM production_material_analyses WHERE id=:id FOR UPDATE")
                    .setParameter("id", analysis).getSingleResult();
            return new MaterialAnalysisService.AnalysisHeader(analysis, WAREHOUSE, "ACTIVE", 0,
                    "a".repeat(64), OffsetDateTime.now(), owner);
        });
        ProductionDocumentAccessPolicy access = mock(ProductionDocumentAccessPolicy.class);
        when(access.scope()).thenReturn(new OwnerVisibility.OwnerScope(true, Set.of()));
        if (forbidden) doThrow(new ApiException(ErrorCode.FORBIDDEN, "not the analysis owner"))
                .when(access).requireWritable(any(), anyString(), any(OwnerVisibility.OwnerScope.class));
        SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
        when(current.requireId()).thenReturn(ACTOR);
        when(current.requireEmployeeId()).thenReturn(owner);
        ProductionSubcontractRequestPort requests = mock(ProductionSubcontractRequestPort.class);
        when(requests.createProductionDraft(anyString(), any(), any(), any(), anyList(), any(), any()))
                .thenAnswer(call -> createApplication(em, call.getArgument(4), call.getArgument(6)));
        return new SubcontractMakeTaskService(em, analyses, access, requests, mock(ChainNoticeService.class), current);
    }

    private static ProductionSubcontractRequestPort.DraftResult createApplication(EntityManager em,
            List<ProductionSubcontractRequestPort.DraftLine> lines, UUID maker) {
        UUID id = UUID.randomUUID();
        UUID item = UUID.randomUUID();
        String bill = new com.uten.imp.common.docnumber.DocNumberService(em)
                .nextNumber(com.uten.imp.common.docnumber.DocNumberPrefix.SUB_APPLICATION);
        em.createNativeQuery("""
                INSERT INTO subcontract_applications(id,bill_no,bill_date,maker_id,applicant_id,status,warehouse_id)
                VALUES(:id,:bill,CURRENT_DATE,:maker,:maker,1,:warehouse)
                """).setParameter("id", id).setParameter("bill", bill).setParameter("maker", maker)
                .setParameter("warehouse", WAREHOUSE).executeUpdate();
        var line = lines.getFirst();
        em.createNativeQuery("""
                INSERT INTO subcontract_application_items(id,application_id,bill_no,bill_date,line_no,
                    goods_id,unit_id,unit_rate,qty,ordered_qty,goods_code_snapshot,goods_name_snapshot,
                    goods_snapshot_source,goods_snapshot_locked_at)
                SELECT :id,:application,:bill,CURRENT_DATE,1,g.id,:unit,1,:qty,0,g.code,g.name,'MASTER_AT_APPROVAL',now()
                FROM goods g WHERE g.id=:goods
                """).setParameter("id", item).setParameter("application", id).setParameter("bill", bill)
                .setParameter("unit", UNIT).setParameter("qty", line.qty()).setParameter("goods", GOODS).executeUpdate();
        return new ProductionSubcontractRequestPort.DraftResult(id, bill,
                List.of(new ProductionSubcontractRequestPort.DraftLineResult(line.demandId(), item, LocalDate.now(), line.qty())));
    }

    private static Fixture fixture() {
        Fixture f = new Fixture(UUID.randomUUID(), UUID.randomUUID());
        UUID item = UUID.randomUUID();
        UUID material = UUID.randomUUID();
        UUID preparation = UUID.randomUUID();
        UUID source = UUID.randomUUID();
        setupTransaction.executeWithoutResult(unused -> {
            jdbc.update("""
                    INSERT INTO production_material_analyses(id,warehouse_id,status,fingerprint,
                        initial_idempotency_key,maker_id,created_by,updated_by)
                    VALUES(?,?,'ACTIVE',?,?,?, ?,?)
                    """, f.analysis(), WAREHOUSE, "a".repeat(64), "SC-BATCH-" + f.analysis(), owner, ACTOR, ACTOR);
            jdbc.update("""
                    INSERT INTO production_material_analysis_items(id,analysis_id,source_type,goods_id,unit_id,
                        source_ref,source_reason,requested_qty,line_priority,created_by,updated_by)
                    VALUES(?,?,'OTHER',?,?,?,'Subcontract batch regression',10,1,?,?)
                    """, item, f.analysis(), GOODS, UNIT, "SC-SOURCE-" + item, ACTOR, ACTOR);
            jdbc.update("""
                    INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,
                        goods_id,unit_id,depth,path,per_product_qty,required_qty,available_qty,allocated_available_qty,
                        shortage_qty,source_suggestion,confirmed_route,route_reason,route_confirmed_by,route_confirmed_at,
                        control_stage,consumption_basis,basis_output_qty,allow_partial_package,hard_gate,
                        bom_qty,parent_per_product_qty,calculation_mode,created_by,updated_by)
                    VALUES(?,?,?,'sc-target',?,?,1,'sc-target',1,10,0,0,10,'SUBCONTRACT','SUBCONTRACT',
                        'Batch test',?,now(),'START','PER_UNIT',1,TRUE,TRUE,1,1,'EDGE_RULE',?,?)
                    """, material, f.analysis(), item, GOODS, UNIT, ACTOR, ACTOR, ACTOR);
            jdbc.update("""
                    INSERT INTO production_material_analysis_items(id,analysis_id,source_type,goods_id,unit_id,
                        source_ref,source_reason,requested_qty,line_priority,parent_analysis_material_id,created_by,updated_by)
                    VALUES(?,?,'SUBCONTRACT_MAKE',?,?,?,'Prepared batch regression',10,2,?,?,?)
                    """, preparation, f.analysis(), GOODS, UNIT, "SC-PREP-" + preparation, material, ACTOR, ACTOR);
            jdbc.update("""
                    INSERT INTO preplan_supply_actions(id,analysis_id,warehouse_id,goods_id,unit_id,route,requested_qty,
                        status,idempotency_key,action_group_key,request_business_key,generation,request_hash,
                        external_document_type,external_document_id,created_by)
                    VALUES(?,?,?,?,?,'SUBCONTRACT',10,'CREATED',?,?,?,1,?,'SUBCONTRACT_MAKE_TASK',?,?)
                    """, source, f.analysis(), WAREHOUSE, GOODS, UNIT, "SC-SOURCE-" + source,
                    "b".repeat(64), "c".repeat(64), "d".repeat(64), preparation, ACTOR);
            jdbc.update("""
                    INSERT INTO preplan_supply_action_allocations(id,analysis_id,action_id,analysis_material_id,
                        allocated_qty,external_item_id,created_by) VALUES(?,?,?,?,10,?,?)
                    """, UUID.randomUUID(), f.analysis(), source, material, preparation, ACTOR);
            jdbc.update("""
                    INSERT INTO preplan_subcontract_make_tasks(id,analysis_id,analysis_material_id,supply_action_id,
                        preparation_item_id,goods_id,unit_id,warehouse_id,required_qty,produced_qty,created_by,updated_by)
                    VALUES(?,?,?,?,?,?,?,?,10,10,?,?)
                    """, f.task(), f.analysis(), material, source, preparation, GOODS, UNIT, WAREHOUSE, ACTOR, ACTOR);
        });
        return f;
    }

    private record Fixture(UUID analysis, UUID task) { }
}
