package com.uten.imp.features.production.execution;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.features.production.ProductionWorkshopMembership;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.Executors;

import static com.uten.imp.features.production.execution.ProductionDrawRequest.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Actual PostgreSQL command, request ledger, exact warehouse gates and retry behavior. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "true")
class ProductionDrawRequestPostgresTest {
    private static final PostgreSQLContainer<?> PG = new PostgreSQLContainer<>("postgres:16-alpine");
    private static SessionFactory factory;
    private static JdbcTemplate jdbc;
    private static final UUID ACTOR = new UUID(0, 10), PLAN = new UUID(0, 11), PACKAGE = new UUID(0, 12),
            SEGMENT = new UUID(0, 13), WORKSHOP = new UUID(0, 14), GOODS = new UUID(0, 15), UNIT = new UUID(0, 16),
            WH_A = new UUID(0, 17), WH_B = new UUID(0, 18), DRAW_A = new UUID(0, 19), DRAW_B = new UUID(0, 20),
            ITEM_A = new UUID(0, 21), ITEM_B = new UUID(0, 22);
    private EntityManager em;
    private ProductionDocumentAccessPolicy access;
    private ProductionWorkshopMembership membership;
    private ChainNoticeService notices;
    private ProductionDrawRequestService service;

    @BeforeAll static void schema() throws Exception {
        PG.start();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword()));
        jdbc.execute("""
                CREATE TABLE production_plans(id uuid PRIMARY KEY,bill_no text,status integer,
                  is_closed boolean DEFAULT false,is_canceled boolean DEFAULT false,is_stopped boolean DEFAULT false,
                  maker_id uuid,is_deleted boolean DEFAULT false);
                CREATE TABLE production_planning_packages(id uuid PRIMARY KEY,status text,is_deleted boolean DEFAULT false);
                CREATE TABLE production_execution_segments(id uuid PRIMARY KEY,plan_id uuid,package_id uuid,status text,
                  lock_version bigint DEFAULT 1,workshop_department_id uuid,responsible_employee_id uuid,
                  material_requirement_mode text DEFAULT 'DEMANDED',segment_code text,product_goods_id uuid,planned_qty numeric,
                  updated_at timestamptz,updated_by uuid,is_deleted boolean DEFAULT false,
                  start_route text DEFAULT 'FULL_KIT',continuous_supply boolean DEFAULT FALSE);
                CREATE TABLE production_execution_segment_events(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                  execution_segment_id uuid NOT NULL,action text CONSTRAINT production_execution_segment_events_action_check
                  CHECK(action IN ('START')),idempotency_key text,request_hash text,expected_version bigint,
                  resulting_version bigint,created_by uuid,created_at timestamptz DEFAULT now(),
                  UNIQUE(execution_segment_id,action,idempotency_key), counter_event_id uuid, receiving_confirmation_id uuid, receiving_direction smallint);
                CREATE TABLE stock_documents(id uuid PRIMARY KEY,doc_type text,bill_no text,warehouse_id uuid,
                  status integer DEFAULT 0,is_deleted boolean DEFAULT false);
                CREATE TABLE stock_document_items(id uuid PRIMARY KEY,doc_id uuid,goods_id uuid,goods_code_snapshot text,
                  goods_name_snapshot text,color_id uuid,unit_id uuid,qty numeric,issued_qty numeric DEFAULT 0,
                  unit_rate numeric DEFAULT 1,is_deleted boolean DEFAULT false);
                CREATE TABLE production_planning_package_documents(document_id uuid,document_type text,execution_segment_id uuid);
                CREATE TABLE production_planning_package_document_items(document_item_id uuid,document_type text,demand_id uuid);
                CREATE TABLE production_material_demands(id uuid,execution_segment_id uuid,is_deleted boolean DEFAULT false, consumption_snapshot jsonb);
                CREATE TABLE production_material_stock_postings(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                  stock_document_item_id uuid,posting_type text, recorded_tx_id xid8);
                CREATE TABLE departments(id uuid PRIMARY KEY,name text);
                CREATE TABLE goods(id uuid PRIMARY KEY,code text,name text, default_purchase_price_color_id uuid, default_purchase_price_currency_id uuid, default_purchase_price_supplier_id uuid, default_purchase_price_tax_rate numeric(18,4), default_purchase_price_unit_id uuid, default_subcontract_price_color_id uuid, default_subcontract_price_currency_id uuid, default_subcontract_price_supplier_id uuid, default_subcontract_price_tax_rate numeric(18,4), default_subcontract_price_unit_id uuid);
                CREATE TABLE warehouses(id uuid PRIMARY KEY,name text,
                    is_line_side boolean NOT NULL DEFAULT FALSE);
                CREATE TABLE units(id uuid PRIMARY KEY,name text);
                CREATE TABLE colors(id uuid PRIMARY KEY,name text);
                """);
        jdbc.execute(Files.readString(Path.of("src/main/resources/db/migration/V559__production_workshop_draw_request.sql")));
        jdbc.execute(Files.readString(Path.of("src/main/resources/db/migration/V564__production_draw_requested_quantities.sql")));
        String receiving=Files.readString(Path.of("src/main/resources/db/migration/V618__production_material_return_receiving_warehouse.sql"));
        int effective=receiving.indexOf("CREATE FUNCTION fn_production_draw_item_effective_qty(");
        jdbc.execute(receiving.substring(effective,receiving.indexOf("$$;",effective)+3));
        factory = new Configuration().setProperty("hibernate.connection.driver_class", "org.postgresql.Driver")
                .setProperty("hibernate.connection.url", PG.getJdbcUrl())
                .setProperty("hibernate.connection.username", PG.getUsername())
                .setProperty("hibernate.connection.password", PG.getPassword())
                .setProperty("hibernate.hbm2ddl.auto", "none").buildSessionFactory();
    }

    @BeforeEach void fixture() {
        jdbc.execute("TRUNCATE production_execution_segment_events,production_planning_package_documents,"
                + "production_planning_package_document_items,production_material_demands,"
                + "production_material_stock_postings,stock_document_items,stock_documents,production_execution_segments,"
                + "production_plans,production_planning_packages,departments,goods,warehouses,units,colors");
        jdbc.update("INSERT INTO production_plans(id,bill_no,status,maker_id) VALUES (?,'PLAN-1',1,?)", PLAN, ACTOR);
        jdbc.update("INSERT INTO production_planning_packages VALUES (?,'CONFIRMED',false)", PACKAGE);
        jdbc.update("INSERT INTO departments VALUES (?,'Assembly')", WORKSHOP);
        jdbc.update("INSERT INTO goods VALUES (?,'G-1','Component')", GOODS);
        jdbc.update("INSERT INTO units VALUES (?,'piece')", UNIT);
        jdbc.update("INSERT INTO warehouses VALUES (?,'Plastic'),(?,'Metal')", WH_A, WH_B);
        jdbc.update("""
                INSERT INTO production_execution_segments(id,plan_id,package_id,status,workshop_department_id,
                  responsible_employee_id,segment_code,product_goods_id,planned_qty)
                VALUES (?,?,?,'READY',?,?,'TASK-1',?,10)
                """, SEGMENT, PLAN, PACKAGE, WORKSHOP, ACTOR, GOODS);
        for (int i = 0; i < 2; i++) {
            UUID document = i == 0 ? DRAW_A : DRAW_B;
            jdbc.update("INSERT INTO stock_documents(id,doc_type,bill_no,warehouse_id) VALUES (?,'DRAW',?,?)",
                    document, "DRAW-" + i, i == 0 ? WH_A : WH_B);
            jdbc.update("INSERT INTO production_planning_package_documents VALUES (?,'DRAW',?)", document, SEGMENT);
            jdbc.update("""
                    INSERT INTO stock_document_items(id,doc_id,goods_id,goods_code_snapshot,goods_name_snapshot,unit_id,qty)
                    VALUES (?,?,?,'G-1','Component',?,?)
                    """, i == 0 ? ITEM_A : ITEM_B, document, GOODS, UNIT, i == 0 ? 4 : 6);
            UUID item = i == 0 ? ITEM_A : ITEM_B;
            jdbc.update("INSERT INTO production_material_demands(id,execution_segment_id) VALUES (?,?)", item, SEGMENT);
            jdbc.update("INSERT INTO production_planning_package_document_items VALUES (?,'DRAW',?)", item, item);
        }
        access = mock(ProductionDocumentAccessPolicy.class);
        when(access.hasAuthority(anyString())).thenReturn(true);
        membership = mock(ProductionWorkshopMembership.class);
        when(membership.isWorkshopMember(any(), any(), any())).thenReturn(true);
        notices = mock(ChainNoticeService.class);
        em = factory.createEntityManager();
        service = service(em);
    }

    private ProductionDrawRequestService service(EntityManager manager) {
        SecurityContextCurrentUser user = mock(SecurityContextCurrentUser.class);
        when(user.requireId()).thenReturn(ACTOR);
        when(user.employeeId()).thenReturn(Optional.of(ACTOR));
        // V595：提交领料申请前就地出库线边仓草稿——本用例没有线边仓，就绪服务只需空转。
        var readiness = mock(com.uten.imp.features.production.fulfillment.ProductionExecutionReadinessService.class);
        return new ProductionDrawRequestService(manager, user, mock(TxSessionVars.class), access, membership, notices, readiness,
                mock(com.uten.imp.features.production.plan.ProductionPlanMutationFootprintService.class));
    }
    private Preview preview() { return service.preview(new PreviewRequest(List.of(new Item(SEGMENT, 1L)))); }
    private SubmitRequest submitRequest(Preview preview) {
        return new SubmitRequest(List.of(new Item(SEGMENT, 1L)), "draw-test-0001", preview.fingerprint());
    }
    private Result commit(SubmitRequest request) {
        em.getTransaction().begin();
        try { Result result = service.submit(request); em.getTransaction().commit(); return result; }
        catch (RuntimeException error) { em.getTransaction().rollback(); throw error; }
    }
    private boolean requested(UUID document) {
        return Boolean.TRUE.equals(jdbc.queryForObject("SELECT fn_production_draw_requested(?)", Boolean.class, document));
    }

    @Test void readinessIsReadOnlyAndSubmitOpensExactActualWarehouses() {
        Preview preview = preview();
        assertThat(preview.documentCount()).isEqualTo(2);
        assertThat(preview.summaries()).hasSize(2);
        assertThat(preview.lines()).extracting(Line::warehouseId).containsExactly(WH_A, WH_B);
        assertThat(requested(DRAW_A)).isFalse();
        assertThat(requested(DRAW_B)).isFalse();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM production_execution_segment_events", Integer.class)).isZero();
        Result result = commit(submitRequest(preview));
        assertThat(result.documentIds()).containsExactly(DRAW_A, DRAW_B);
        assertThat(requested(DRAW_A)).isTrue();
        assertThat(requested(DRAW_B)).isTrue();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM production_material_stock_postings", Integer.class)).isZero();
        verify(notices).notifyProductionDrawPending(DRAW_A);
        verify(notices).notifyProductionDrawPending(DRAW_B);
    }

    @Test void sameIntentReplaysButChangedMembershipOrFingerprintDoesNot() {
        SubmitRequest request = submitRequest(preview());
        commit(request);
        assertThat(commit(request).replayed()).isTrue();
        assertThatThrownBy(() -> commit(new SubmitRequest(request.items(), request.idempotencyKey(), "0".repeat(64))))
                .isInstanceOf(ApiException.class).hasMessageContaining("幂等键");
        assertThat(jdbc.queryForObject("SELECT count(*) FROM production_execution_segment_events", Integer.class)).isEqualTo(1);
    }

    @Test void selectedQuantityKeepsDemandAndUnselectedWarehouseForTheNextRequest() {
        Preview original = preview();
        SubmitRequest first = new SubmitRequest(List.of(new Item(SEGMENT, 1L)), "partial-draw-01",
                original.fingerprint(), List.of(new Selection(ITEM_A, new BigDecimal("2"))));
        assertThat(commit(first).documentIds()).containsExactly(DRAW_A);
        assertThat(commit(first).replayed()).isTrue();
        assertThat(requested(DRAW_B)).isFalse();
        assertThat(jdbc.queryForObject("SELECT qty FROM stock_document_items WHERE id=?", BigDecimal.class, ITEM_A))
                .isEqualByComparingTo("4");
        assertThat(jdbc.queryForObject("SELECT fn_production_draw_item_requested_qty(?)", BigDecimal.class, ITEM_A))
                .isEqualByComparingTo("2");
        assertThat(jdbc.queryForObject("SELECT fn_production_draw_fully_requested(?)", Boolean.class, DRAW_A)).isFalse();
        assertThat(jdbc.queryForObject("SELECT fn_production_draw_pending(?)", Boolean.class, DRAW_A)).isTrue();
        assertThatThrownBy(() -> jdbc.update("UPDATE stock_document_items SET issued_qty=3 WHERE id=?", ITEM_A))
                .hasMessageContaining("exceeds workshop requested quantity");
        jdbc.update("UPDATE stock_document_items SET issued_qty=2 WHERE id=?", ITEM_A);
        assertThat(jdbc.queryForObject("SELECT fn_production_draw_pending(?)", Boolean.class, DRAW_A)).isFalse();
        Preview next = service.preview(new PreviewRequest(List.of(new Item(SEGMENT, 2L))));
        assertThat(next.lines()).extracting(Line::qty).usingComparatorForType(BigDecimal::compareTo, BigDecimal.class)
                .containsExactly(new BigDecimal("2"), new BigDecimal("6"));
        commit(new SubmitRequest(List.of(new Item(SEGMENT, 2L)), "partial-draw-02", next.fingerprint(),
                List.of(new Selection(ITEM_A, new BigDecimal("2")), new Selection(ITEM_B, new BigDecimal("6")))));
        assertThat(jdbc.queryForObject("SELECT fn_production_draw_fully_requested(?)", Boolean.class, DRAW_A)).isTrue();
        assertThat(jdbc.queryForObject("SELECT fn_production_draw_pending(?)", Boolean.class, DRAW_A)).isTrue();
        assertThat(requested(DRAW_B)).isTrue();
    }

    @Test void selectionOverdrawDuplicateUnknownAndChangedRetryAreRejected() {
        Preview preview = preview();
        for (List<Selection> lines : List.of(List.of(new Selection(ITEM_A, new BigDecimal("5"))),
                List.of(new Selection(ITEM_A, BigDecimal.ONE), new Selection(ITEM_A, BigDecimal.ONE)),
                List.of(new Selection(UUID.randomUUID(), BigDecimal.ONE)),
                List.of(new Selection(ITEM_A, new BigDecimal("0.00001"))))) {
            assertThatThrownBy(() -> commit(new SubmitRequest(List.of(new Item(SEGMENT, 1L)),
                    "invalid-draw-01", preview.fingerprint(), lines))).isInstanceOf(ApiException.class);
        }
        assertThat(requested(DRAW_A)).isFalse();
        commit(new SubmitRequest(List.of(new Item(SEGMENT, 1L)), "valid-draw-01", preview.fingerprint(),
                List.of(new Selection(ITEM_A, BigDecimal.ONE))));
        assertThatThrownBy(() -> commit(new SubmitRequest(List.of(new Item(SEGMENT, 1L)),
                "valid-draw-01", preview.fingerprint(), List.of(new Selection(ITEM_A, new BigDecimal("2"))))))
                .isInstanceOf(ApiException.class).hasMessageContaining("幂等键");
    }

    @Test void unselectedTaskRemainsUnrequestedAndReplayReturnsOnlySelectedTasks() {
        UUID other=UUID.randomUUID();
        jdbc.update("""
            INSERT INTO production_execution_segments(id,plan_id,package_id,status,workshop_department_id,
                responsible_employee_id,segment_code,product_goods_id,planned_qty)
            SELECT ?,plan_id,package_id,status,workshop_department_id,responsible_employee_id,
                'TASK-2',product_goods_id,planned_qty FROM production_execution_segments WHERE id=?
            """,other,SEGMENT);
        jdbc.update("UPDATE production_planning_package_documents SET execution_segment_id=? WHERE document_id=?",other,DRAW_B);
        jdbc.update("UPDATE production_material_demands SET execution_segment_id=? WHERE id=?",other,ITEM_B);
        List<Item> items=List.of(new Item(SEGMENT,1L),new Item(other,1L));
        Preview reviewed=service.preview(new PreviewRequest(items));
        SubmitRequest request=new SubmitRequest(items,"select-task-only",reviewed.fingerprint(),
                List.of(new Selection(ITEM_A,BigDecimal.ONE)));
        assertThat(commit(request).segmentIds()).containsExactly(SEGMENT);
        assertThat(commit(request).replayed()).isTrue();
        assertThat(requested(DRAW_B)).isFalse();
        assertThat(jdbc.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,other)).isEqualTo(1L);
    }

    @Test void staleSummaryAndTaskVersionFailWithoutRequestOrNotification() {
        SubmitRequest request = submitRequest(preview());
        jdbc.update("UPDATE stock_document_items SET qty=8 WHERE id=?", ITEM_B);
        assertThatThrownBy(() -> commit(request)).isInstanceOf(ApiException.class).hasMessageContaining("汇总已变化");
        jdbc.update("UPDATE production_execution_segments SET lock_version=2 WHERE id=?", SEGMENT);
        assertThatThrownBy(this::preview).isInstanceOf(ApiException.class).hasMessageContaining("任务已变化");
        assertThat(requested(DRAW_A)).isFalse();
        verifyNoInteractions(notices);
    }

    @Test void approvedButNeverIssuedLegacyDrawCanBeRequestedWithoutRewritingApproval() {
        jdbc.update("UPDATE stock_documents SET status=1 WHERE id=?", DRAW_A);
        assertThat(requested(DRAW_A)).isFalse();
        commit(submitRequest(preview()));
        assertThat(requested(DRAW_A)).isTrue();
        assertThat(jdbc.queryForObject("SELECT status FROM stock_documents WHERE id=?", Integer.class, DRAW_A)).isEqualTo(1);
    }

    @Test void issuedSiblingWarehouseDoesNotBlockRequestingRemainingWarehouse() {
        jdbc.update("UPDATE stock_documents SET status=1 WHERE id=?", DRAW_A);
        jdbc.update("INSERT INTO production_material_stock_postings(stock_document_item_id,posting_type) VALUES (?,'ISSUE')", ITEM_A);
        assertThat(requested(DRAW_A)).isTrue();
        assertThat(requested(DRAW_B)).isFalse();
        Preview preview = preview();
        assertThat(preview.lines()).extracting(Line::drawId).containsExactly(DRAW_B);
        assertThat(commit(submitRequest(preview)).documentIds()).containsExactly(DRAW_B);
        assertThat(requested(DRAW_B)).isTrue();
        verify(notices, never()).notifyProductionDrawPending(DRAW_A);
    }

    @Test void rebuiltDocumentDoesNotInheritPriorRequestAndEventsRemainImmutable() {
        commit(submitRequest(preview()));
        UUID newDraw = UUID.randomUUID();
        jdbc.update("INSERT INTO stock_documents(id,doc_type) VALUES (?,'DRAW')", newDraw);
        jdbc.update("INSERT INTO production_planning_package_documents VALUES (?,'DRAW',?)", newDraw, SEGMENT);
        assertThat(requested(newDraw)).isFalse();
        assertThatThrownBy(() -> jdbc.update("DELETE FROM production_execution_segment_events"))
                .hasMessageContaining("append-only");
        assertThat(requested(null)).isFalse();
        assertThat(requested(UUID.randomUUID())).isFalse();
    }

    @Test void missingPermissionAndForeignWorkshopFailClosed() {
        when(access.hasAuthority("production_execution:start")).thenReturn(false);
        assertThatThrownBy(this::preview).isInstanceOf(ApiException.class).hasMessageContaining("权限");
        when(access.hasAuthority("production_execution:start")).thenReturn(true);
        when(membership.isWorkshopMember(any(), any(), any())).thenReturn(false);
        doThrow(new ApiException(com.uten.imp.common.web.ErrorCode.FORBIDDEN, "无权操作"))
                .when(access).requireScopedOperationWritable(any(), anyString(), anyString());
        assertThatThrownBy(this::preview).isInstanceOf(ApiException.class).hasMessageContaining("无权");
        verifyNoInteractions(notices);
    }

    @Test void simultaneousRetriesProduceOneEventAndSameDocuments() throws Exception {
        SubmitRequest request = submitRequest(preview());
        try (var executor = Executors.newFixedThreadPool(2)) {
            var a = executor.submit(() -> submitInIndependentTransaction(request));
            var b = executor.submit(() -> submitInIndependentTransaction(request));
            assertThat(List.of(a.get().replayed(), b.get().replayed())).containsExactlyInAnyOrder(false, true);
        }
        assertThat(jdbc.queryForObject("SELECT count(*) FROM production_execution_segment_events", Integer.class)).isEqualTo(1);
    }
    private Result submitInIndependentTransaction(SubmitRequest request) {
        try (EntityManager manager = factory.createEntityManager()) {
            manager.getTransaction().begin();
            try { Result result = service(manager).submit(request); manager.getTransaction().commit(); return result; }
            catch (RuntimeException failure) { manager.getTransaction().rollback(); throw failure; }
        }
    }

    @AfterEach void closeSession() { if (em != null) em.close(); }
    @AfterAll static void close() { if (factory != null) factory.close(); PG.stop(); }
}
