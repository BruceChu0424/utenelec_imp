package com.uten.imp.features.production.analysis;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

/** PostgreSQL evidence for V250 preplan external-source history guards. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class PreplanExternalSupplySourceGuardPostgresTest {

    private static final java.util.concurrent.atomic.AtomicInteger BUSINESS_IDENTIFIER_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");
    private static final LocalDate BILL_DATE = LocalDate.of(2026, 8, 10);

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
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void directSourcesAndProvenanceRemainProtectedAfterDedicatedCancel()
            throws Exception {
        try (Connection connection = connection()) {
            for (Route route : Route.values()) {
                Fixture fixture = createFixture(connection, route);
                ExternalSource source = createExternalSource(
                        connection, fixture, route);

                assertConstraint(
                        connection,
                        "preplan_external_supply_action_identity_guard",
                        """
                        UPDATE preplan_supply_actions
                        SET external_document_no=external_document_no || '-tampered'
                        WHERE id=?
                        """,
                        source.actionId());
                assertConstraint(
                        connection,
                        "preplan_external_supply_allocation_identity_guard",
                        """
                        UPDATE preplan_supply_action_allocations
                        SET allocated_qty=allocated_qty + 1 WHERE id=?
                        """,
                        source.allocationId());
                assertConstraint(
                        connection,
                        route.directItemConstraint,
                        "UPDATE " + route.sourceItemTable
                                + " SET qty=qty + 1 WHERE id=?",
                        source.sourceItemId());
                assertConstraint(
                        connection,
                        route.liveHeaderConstraint,
                        "UPDATE " + route.sourceHeaderTable
                                + " SET need_date=need_date + 1 WHERE id=?",
                        source.sourceHeaderId());

                cancelSourceAndAction(connection, fixture, source, route);
                assertEquals(
                        "CANCELLED",
                        scalarText(
                                connection,
                                "SELECT status FROM preplan_supply_actions WHERE id=?",
                                source.actionId()));
                assertConstraint(
                        connection,
                        route.directItemConstraint,
                        "UPDATE " + route.sourceItemTable
                                + " SET qty=qty + 1 WHERE id=?",
                        source.sourceItemId());
                assertConstraint(
                        connection,
                        route.lifecycleHeaderConstraint,
                        "UPDATE " + route.sourceHeaderTable
                                + " SET is_deleted=FALSE WHERE id=?",
                        source.sourceHeaderId());
                assertConstraint(
                        connection,
                        "preplan_external_supply_action_cancelled_guard",
                        """
                        UPDATE preplan_supply_actions
                        SET status='CREATED', cancelled_by=NULL,
                            cancelled_at=NULL, cancellation_reason=NULL
                        WHERE id=?
                        """,
                        source.actionId());
            }
        }
    }

    @Test
    void createdOrRejectedOrderDraftsStayEditableUntilFormalOrActionState()
            throws Exception {
        try (Connection connection = connection()) {
            for (Route route : Route.values()) {
                Fixture approvedFixture = createFixture(connection, route);
                ExternalSource approvedSource = createExternalSource(
                        connection, approvedFixture, route);
                OrderSource approvedOrder = createOrder(
                        connection, approvedFixture, approvedSource, route);

                execute(
                        connection,
                        "UPDATE " + route.orderItemTable
                                + " SET qty=9 WHERE id=?",
                        approvedOrder.orderItemId());
                execute(
                        connection,
                        "DELETE FROM " + route.orderItemTable + " WHERE id=?",
                        approvedOrder.orderItemId());
                insertOrderItem(
                        connection, approvedFixture, approvedSource,
                        approvedOrder, route, "9");
                execute(
                        connection,
                        "UPDATE " + route.sourceItemTable
                                + " SET ordered_qty=9 WHERE id=?",
                        approvedSource.sourceItemId());

                execute(
                        connection,
                        "UPDATE " + route.orderHeaderTable
                                + " SET status=1 WHERE id=?",
                        approvedOrder.orderId());
                assertConstraint(
                        connection,
                        route.orderItemConstraint,
                        "UPDATE " + route.orderItemTable
                                + " SET qty=8 WHERE id=?",
                        approvedOrder.orderItemId());
                execute(
                        connection,
                        "UPDATE " + route.orderItemTable
                                + " SET received_qty=1 WHERE id=?",
                        approvedOrder.orderItemId());
                if (route == Route.SUBCONTRACT) {
                    execute(
                            connection,
                            """
                            UPDATE subcontract_order_items
                            SET issued_qty=1, material_returned_qty=0
                            WHERE id=?
                            """,
                            approvedOrder.orderItemId());
                }
                execute(
                        connection,
                        "UPDATE " + route.sourceItemTable
                                + " SET ordered_qty=8 WHERE id=?",
                        approvedSource.sourceItemId());

                Fixture advancedFixture = createFixture(connection, route);
                ExternalSource advancedSource = createExternalSource(
                        connection, advancedFixture, route);
                OrderSource advancedOrder = createOrder(
                        connection, advancedFixture, advancedSource, route);
                execute(
                        connection,
                        """
                        UPDATE preplan_supply_actions
                        SET status='IN_PROGRESS', updated_at=now() WHERE id=?
                        """,
                        advancedSource.actionId());
                assertConstraint(
                        connection,
                        route.orderItemConstraint,
                        "UPDATE " + route.orderItemTable
                                + " SET qty=9 WHERE id=?",
                        advancedOrder.orderItemId());
                assertConstraint(
                        connection,
                        "preplan_external_supply_action_status_guard",
                        """
                        UPDATE preplan_supply_actions
                        SET status='CREATED', updated_at=now() WHERE id=?
                        """,
                        advancedSource.actionId());
            }
        }
    }

    @Test
    void unrelatedDraftRowsRemainOutsideProductionBackstop()
            throws Exception {
        try (Connection connection = connection()) {
            for (Route route : Route.values()) {
                Fixture fixture = createFixture(connection, route);
                ExternalSource source = createUnlinkedSource(
                        connection, fixture, route);
                OrderSource order = createOrder(
                        connection, fixture, source, route);

                execute(
                        connection,
                        "UPDATE " + route.sourceItemTable
                                + " SET qty=qty + 1 WHERE id=?",
                        source.sourceItemId());
                execute(
                        connection,
                        "UPDATE " + route.orderItemTable
                                + " SET qty=qty + 1 WHERE id=?",
                        order.orderItemId());
                execute(
                        connection,
                        "DELETE FROM " + route.orderItemTable + " WHERE id=?",
                        order.orderItemId());
                execute(
                        connection,
                        "DELETE FROM " + route.sourceItemTable + " WHERE id=?",
                        source.sourceItemId());
            }
        }
    }

    @Test
    void protectedDraftOrderAllowsOnlyItsFirstApprovalSnapshotLock()
            throws Exception {
        try (Connection connection = connection()) {
            for (Route route : Route.values()) {
                Fixture fixture = createFixture(connection, route);
                ExternalSource source = createExternalSource(
                        connection, fixture, route);
                OrderSource order = createOrder(
                        connection, fixture, source, route);

                // A real but unrelated upstream row cannot lend its display
                // identity to this order item.  Keep the action in CREATED so
                // the setup itself remains in V250's editable-draft lane.
                Fixture wrongFixture = createFixture(connection, route);
                ExternalSource wrongSource = createUnlinkedSource(
                        connection, wrongFixture, route);
                execute(
                        connection,
                        "UPDATE " + route.orderItemTable + " SET "
                                + route.upstreamColumn + "=? WHERE id=?",
                        wrongSource.sourceItemId(), order.orderItemId());
                String approvalSource = route == Route.BUY
                        ? "REQUEST_ITEM_AT_APPROVAL"
                        : "APPLICATION_ITEM_AT_APPROVAL";
                String wrongAuthoritativeCode = scalarText(
                        connection,
                        "SELECT goods_code_snapshot FROM "
                                + route.sourceItemTable + " WHERE id=?",
                        wrongSource.sourceItemId());
                String wrongAuthoritativeName = scalarText(
                        connection,
                        "SELECT goods_name_snapshot FROM "
                                + route.sourceItemTable + " WHERE id=?",
                        wrongSource.sourceItemId());
                assertConstraint(
                        connection,
                        route.orderItemConstraint,
                        "UPDATE " + route.orderItemTable + " SET "
                                + "goods_code_snapshot=?, "
                                + "goods_name_snapshot=?, "
                                + "goods_snapshot_source=?, "
                                + "goods_snapshot_locked_at=now() WHERE id=?",
                        wrongAuthoritativeCode, wrongAuthoritativeName,
                        approvalSource, order.orderItemId());
                execute(
                        connection,
                        "UPDATE " + route.orderItemTable + " SET "
                                + route.upstreamColumn + "=? WHERE id=?",
                        source.sourceItemId(), order.orderItemId());

                execute(
                        connection,
                        """
                        UPDATE preplan_supply_actions
                        SET status='IN_PROGRESS', updated_at=now()
                        WHERE id=?
                        """,
                        source.actionId());
                String authoritativeCode = scalarText(
                        connection,
                        "SELECT goods_code_snapshot FROM "
                                + route.sourceItemTable + " WHERE id=?",
                        source.sourceItemId());
                String authoritativeName = scalarText(
                        connection,
                        "SELECT goods_name_snapshot FROM "
                                + route.sourceItemTable + " WHERE id=?",
                        source.sourceItemId());

                // A valid-looking lock must not smuggle a quantity mutation
                // through the narrow snapshot allowance.
                assertConstraint(
                        connection,
                        route.orderItemConstraint,
                        "UPDATE " + route.orderItemTable + " SET "
                                + "qty=qty+1, goods_code_snapshot=?, "
                                + "goods_name_snapshot=?, "
                                + "goods_snapshot_source=?, "
                                + "goods_snapshot_locked_at=now() WHERE id=?",
                        authoritativeCode, authoritativeName,
                        approvalSource, order.orderItemId());

                // A correct provenance enum cannot bless forged labels.
                assertConstraint(
                        connection,
                        route.orderItemConstraint,
                        "UPDATE " + route.orderItemTable + " SET "
                                + "goods_code_snapshot='FORGED-CODE', "
                                + "goods_name_snapshot='forged name', "
                                + "goods_snapshot_source=?, "
                                + "goods_snapshot_locked_at=now() WHERE id=?",
                        approvalSource, order.orderItemId());

                // The one-way lock accepts only the provenance produced by
                // the corresponding approval service.
                assertConstraint(
                        connection,
                        route.orderItemConstraint,
                        "UPDATE " + route.orderItemTable + " SET "
                                + "goods_code_snapshot=?, "
                                + "goods_name_snapshot=?, "
                                + "goods_snapshot_source='MASTER_AT_SAVE', "
                                + "goods_snapshot_locked_at=now() WHERE id=?",
                        authoritativeCode, authoritativeName,
                        order.orderItemId());

                // Mirror the real approval ordering: freeze the item while
                // DRAFT, then approve the header before deferred guards run.
                inTransaction(connection, () -> {
                    execute(
                            connection,
                            "UPDATE " + route.orderItemTable + " SET "
                                    + "goods_code_snapshot=?, "
                                    + "goods_name_snapshot=?, "
                                    + "goods_snapshot_source=?, "
                                    + "goods_snapshot_locked_at=now() WHERE id=?",
                            authoritativeCode, authoritativeName,
                            approvalSource, order.orderItemId());
                    execute(
                            connection,
                            "UPDATE " + route.orderHeaderTable
                                    + " SET status=1 WHERE id=?",
                            order.orderId());
                });
                assertEquals(
                        approvalSource,
                        scalarText(
                                connection,
                                "SELECT goods_snapshot_source FROM "
                                        + route.orderItemTable + " WHERE id=?",
                                order.orderItemId()));

                // Once locked, even another otherwise-valid approval source
                // cannot rewrite the historical display snapshot.
                assertConstraint(
                        connection,
                        route.orderItemConstraint,
                        "UPDATE " + route.orderItemTable + " SET "
                                + "goods_snapshot_source=?, "
                                + "goods_snapshot_locked_at=now() WHERE id=?",
                        approvalSource, order.orderItemId());
            }
        }
    }

    private static Fixture createFixture(Connection connection, Route route)
            throws Exception {
        UUID departmentId = scalarUuid(
                connection,
                """
                SELECT id FROM departments
                WHERE is_deleted=FALSE ORDER BY code LIMIT 1
                """);
        UUID employeeId = UUID.randomUUID();
        UUID userId = UUID.randomUUID();
        UUID warehouseId = UUID.randomUUID();
        UUID unitId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID analysisId = UUID.randomUUID();
        UUID analysisItemId = UUID.randomUUID();
        UUID materialId = UUID.randomUUID();

        execute(
                connection,
                """
                INSERT INTO employees(
                    id,code,full_name,id_type,department_id,hire_date,
                    status,employment_type)
                VALUES(?,?,?,(
                    SELECT id_type FROM employees ORDER BY id LIMIT 1
                ),?,?,'active','regular')
                """,
                employeeId, "V250-E-" + employeeId, "V250 owner",
                departmentId, LocalDate.of(2026, 1, 1));
        execute(
                connection,
                """
                INSERT INTO users(
                    id,employee_id,login_account,password_hash,status)
                VALUES(?,?,?,?,'active')
                """,
                userId, employeeId, "v250-" + userId, "test-only-hash");
        execute(
                connection,
                "INSERT INTO warehouses(id,code,name) VALUES(?,?,?)",
                warehouseId, "V250-W-" + warehouseId, "V250 warehouse");
        execute(
                connection,
                "INSERT INTO units(id,code,name) VALUES(?,?,?)",
                unitId, "V250-U-" + unitId, "piece");
        execute(
                connection,
                "INSERT INTO goods(id,code,name,unit_id,code_sequence) "
                        + "VALUES(?,?,?,?,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))",
                goodsId, "V250-G-" + goodsId, "V250 goods", unitId);
        execute(
                connection,
                """
                INSERT INTO production_material_analyses(
                    id,warehouse_id,status,fingerprint,
                    initial_idempotency_key,maker_id,created_by,updated_by)
                VALUES(?,?,'ACTIVE',?,?,?,?,?)
                """,
                analysisId, warehouseId, "a".repeat(64),
                "initial-" + analysisId, employeeId, userId, userId);
        execute(
                connection,
                """
                INSERT INTO production_material_analysis_items(
                    id,analysis_id,source_type,goods_id,unit_id,
                    source_ref,source_reason,requested_qty,line_priority,
                    created_by,updated_by)
                VALUES(?,?,'OTHER',?,?,?,?,10,1,?,?)
                """,
                analysisItemId, analysisId, goodsId, unitId,
                "V250-" + route + "-" + analysisItemId,
                "V250 source guard test", userId, userId);
        execute(
                connection,
                """
                INSERT INTO production_material_analysis_materials(
                    id,analysis_id,analysis_item_id,node_key,goods_id,unit_id,
                    depth,path,per_product_qty,required_qty,source_suggestion)
                VALUES(?,?,?,?,?,?,1,?,1,10,?)
                """,
                materialId, analysisId, analysisItemId,
                "node-" + materialId, goodsId, unitId,
                "node-" + materialId, route.actionRoute);
        return new Fixture(
                userId, warehouseId, unitId, goodsId,
                analysisId, analysisItemId, materialId);
    }

    private static ExternalSource createExternalSource(
            Connection connection, Fixture fixture, Route route)
            throws Exception {
        UUID actionId = UUID.randomUUID();
        UUID allocationId = UUID.randomUUID();
        String actionKey = actionId.toString().replace("-", "").repeat(2);
        inTransaction(connection, () -> {
            execute(
                    connection,
                    """
                    INSERT INTO preplan_supply_actions(
                        id,analysis_id,warehouse_id,goods_id,unit_id,route,
                        requested_qty,status,idempotency_key,action_group_key,
                        request_business_key,generation,request_hash,created_by)
                    VALUES(?,?,?,?,?,?,10,'OPEN',?,?,?,1,?,?)
                    """,
                    actionId, fixture.analysisId(), fixture.warehouseId(),
                    fixture.goodsId(), fixture.unitId(), route.actionRoute,
                    "idem-" + actionId, actionKey, actionKey,
                    "d".repeat(64), fixture.userId());
            execute(
                    connection,
                    """
                    INSERT INTO preplan_supply_action_allocations(
                        id,analysis_id,action_id,analysis_material_id,
                        allocated_qty,created_by)
                    VALUES(?,?,?,?,10,?)
                    """,
                    allocationId, fixture.analysisId(), actionId,
                    fixture.materialId(), fixture.userId());
        });

        ExternalSource source = createSourceRows(
                connection, fixture, route, actionId, allocationId);
        assertConstraint(
                connection,
                "preplan_external_supply_action_handshake_guard",
                """
                UPDATE preplan_supply_actions
                SET status='CREATED', external_document_type=?,
                    external_document_id=?, external_document_no=?,
                    updated_at=now()
                WHERE id=?
                """,
                route == Route.BUY
                        ? "SUBCONTRACT_APPLICATION"
                        : "PURCHASE_REQUEST",
                source.sourceHeaderId(), source.documentNo(), actionId);
        assertConstraint(
                connection,
                "preplan_external_supply_action_identity_guard",
                """
                UPDATE preplan_supply_actions
                SET status='CREATED', external_document_type=?,
                    external_document_id=?, external_document_no=?,
                    requested_qty=requested_qty + 1, updated_at=now()
                WHERE id=?
                """,
                route.externalDocumentType, source.sourceHeaderId(),
                source.documentNo(), actionId);
        assertTransactionalConstraint(
                connection,
                "preplan_external_supply_allocation_handshake_guard",
                () -> {
                    execute(
                            connection,
                            """
                            UPDATE preplan_supply_actions
                            SET status='CREATED', external_document_type=?,
                                external_document_id=?, external_document_no=?,
                                updated_at=now()
                            WHERE id=?
                            """,
                            route.externalDocumentType,
                            source.sourceHeaderId(), source.documentNo(), actionId);
                    execute(
                            connection,
                            """
                            UPDATE preplan_supply_action_allocations
                            SET external_item_id=? WHERE id=?
                            """,
                            UUID.randomUUID(), allocationId);
                });
        inTransaction(connection, () -> {
            execute(
                    connection,
                    """
                    UPDATE preplan_supply_actions
                    SET status='CREATED', external_document_type=?,
                        external_document_id=?, external_document_no=?,
                        updated_at=now()
                    WHERE id=?
                    """,
                    route.externalDocumentType, source.sourceHeaderId(),
                    source.documentNo(), actionId);
            execute(
                    connection,
                    """
                    UPDATE preplan_supply_action_allocations
                    SET external_item_id=? WHERE id=?
                    """,
                    source.sourceItemId(), allocationId);
        });
        return source;
    }

    private static ExternalSource createUnlinkedSource(
            Connection connection, Fixture fixture, Route route)
            throws Exception {
        return createSourceRows(
                connection, fixture, route, UUID.randomUUID(), UUID.randomUUID());
    }

    private static ExternalSource createSourceRows(
            Connection connection, Fixture fixture, Route route,
            UUID actionId, UUID allocationId) throws Exception {
        UUID headerId = UUID.randomUUID();
        UUID itemId = UUID.randomUUID();
        String billNo = businessIdentifier(route.sourceBillPrefix, BILL_DATE);
        if (route == Route.BUY) {
            execute(
                    connection,
                    """
                    INSERT INTO purchase_requests(
                        id,bill_no,bill_date,warehouse_id,need_date,status,
                        created_by,updated_by)
                    VALUES(?,?,?,?,?,0,?,?)
                    """,
                    headerId, billNo, BILL_DATE, fixture.warehouseId(),
                    BILL_DATE.plusDays(5), fixture.userId(), fixture.userId());
            execute(
                    connection,
                    """
                    INSERT INTO purchase_request_items(
                        id,bill_no,bill_date,request_id,goods_id,unit_id,
                        goods_code_snapshot,goods_name_snapshot,
                        unit_rate,qty,created_by,updated_by,goods_snapshot_source)
                    VALUES(?,?,?,?,?,?,?,?,1,10,?,?,'MASTER_AT_SAVE')
                    """,
                    itemId, billNo, BILL_DATE, headerId,
                    fixture.goodsId(), fixture.unitId(),
                    "V250-G-" + fixture.goodsId(), "V250 goods",
                    fixture.userId(), fixture.userId());
        } else {
            execute(
                    connection,
                    """
                    INSERT INTO subcontract_applications(
                        id,bill_no,bill_date,warehouse_id,need_date,status,
                        created_by,updated_by)
                    VALUES(?,?,?,?,?,0,?,?)
                    """,
                    headerId, billNo, BILL_DATE, fixture.warehouseId(),
                    BILL_DATE.plusDays(5), fixture.userId(), fixture.userId());
            execute(
                    connection,
                    """
                    INSERT INTO subcontract_application_items(
                        id,bill_no,bill_date,application_id,goods_id,unit_id,
                        goods_code_snapshot,goods_name_snapshot,goods_snapshot_source,
                        unit_rate,qty,created_by,updated_by)
                    VALUES(?,?,?,?,?,?,?,?,'MASTER_AT_SAVE',1,10,?,?)
                    """,
                    itemId, billNo, BILL_DATE, headerId,
                    fixture.goodsId(), fixture.unitId(),
                    "V250-G-" + fixture.goodsId(), "V250 goods",
                    fixture.userId(), fixture.userId());
        }
        return new ExternalSource(
                actionId, allocationId, headerId, itemId, billNo);
    }

    private static OrderSource createOrder(
            Connection connection, Fixture fixture,
            ExternalSource source, Route route) throws Exception {
        UUID orderId = UUID.randomUUID();
        UUID orderItemId = UUID.randomUUID();
        String billNo = businessIdentifier(route.orderBillPrefix, BILL_DATE);
        execute(
                connection,
                "INSERT INTO " + route.orderHeaderTable
                        + "(id,bill_no,bill_date,warehouse_id,status,"
                        + "created_by,updated_by) VALUES(?,?,?,?,0,?,?)",
                orderId, billNo, BILL_DATE, fixture.warehouseId(),
                fixture.userId(), fixture.userId());
        OrderSource order = new OrderSource(orderId, orderItemId, billNo);
        insertOrderItem(connection, fixture, source, order, route, "10");
        return order;
    }

    private static void insertOrderItem(
            Connection connection, Fixture fixture, ExternalSource source,
            OrderSource order, Route route, String qty) throws Exception {
        execute(
                connection,
                "INSERT INTO " + route.orderItemTable
                        + "(id,bill_no,bill_date,order_id,goods_id,unit_id,"
                        + route.upstreamColumn
                        + ",goods_code_snapshot,goods_name_snapshot,"
                        + "goods_snapshot_source,unit_rate,qty,created_by,updated_by)"
                        + " VALUES(?,?,?,?,?,?,?,?,?,?,1,?,?,?)",
                order.orderItemId(), order.billNo(), BILL_DATE,
                order.orderId(), fixture.goodsId(), fixture.unitId(),
                source.sourceItemId(), "V250-G-" + fixture.goodsId(), "V250 goods",
                route == Route.BUY
                        ? "REQUEST_ITEM_AT_SAVE"
                        : "APPLICATION_ITEM_AT_SAVE",
                new BigDecimal(qty),
                fixture.userId(), fixture.userId());
    }

    private static void cancelSourceAndAction(
            Connection connection, Fixture fixture,
            ExternalSource source, Route route) throws Exception {
        inTransaction(connection, () -> {
            execute(
                    connection,
                    "UPDATE " + route.sourceHeaderTable
                            + " SET is_deleted=TRUE, deleted_at=now() WHERE id=?",
                    source.sourceHeaderId());
            execute(
                    connection,
                    """
                    UPDATE preplan_supply_actions
                    SET status='CANCELLED', cancelled_by=?, cancelled_at=now(),
                        cancellation_reason='dedicated V250 test cancellation',
                        updated_at=now()
                    WHERE id=?
                    """,
                    fixture.userId(), source.actionId());
        });
    }

    private static void assertConstraint(
            Connection connection, String constraint,
            String sql, Object... parameters) {
        PSQLException failure = assertThrows(
                PSQLException.class,
                () -> execute(connection, sql, parameters));
        assertEquals("23514", failure.getSQLState());
        assertEquals(
                constraint,
                failure.getServerErrorMessage().getConstraint());
    }

    private static void assertTransactionalConstraint(
            Connection connection, String constraint, SqlWork work)
            throws Exception {
        connection.setAutoCommit(false);
        try {
            PSQLException failure = assertThrows(
                    PSQLException.class,
                    () -> {
                        work.run();
                        connection.commit();
                    });
            assertEquals("23514", failure.getSQLState());
            assertEquals(
                    constraint,
                    failure.getServerErrorMessage().getConstraint());
            connection.rollback();
        } finally {
            if (!connection.getAutoCommit()) {
                connection.rollback();
                connection.setAutoCommit(true);
            }
        }
    }

    private static void inTransaction(Connection connection, SqlWork work)
            throws Exception {
        connection.setAutoCommit(false);
        try {
            work.run();
            connection.commit();
        } catch (Exception failure) {
            connection.rollback();
            throw failure;
        } finally {
            connection.setAutoCommit(true);
        }
    }

    private static int execute(
            Connection connection, String sql, Object... parameters)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < parameters.length; index++) {
                statement.setObject(index + 1, parameters[index]);
            }
            return statement.executeUpdate();
        }
    }

    private static UUID scalarUuid(Connection connection, String sql)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql);
             ResultSet rows = statement.executeQuery()) {
            rows.next();
            return rows.getObject(1, UUID.class);
        }
    }

    private static String scalarText(
            Connection connection, String sql, Object parameter)
            throws Exception {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            statement.setObject(1, parameter);
            try (ResultSet rows = statement.executeQuery()) {
                rows.next();
                return rows.getString(1);
            }
        }
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

    @FunctionalInterface
    private interface SqlWork {
        void run() throws Exception;
    }

    private enum Route {
        BUY(
                "BUY",
                "PURCHASE_REQUEST",
                "purchase_requests",
                "purchase_request_items",
                "purchase_orders",
                "purchase_order_items",
                "request_item_id",
                "CS",
                "CD",
                "production_purchase_request_item_supply_guard",
                "production_purchase_order_item_supply_guard",
                "production_purchase_request_supply_guard",
                "production_purchase_request_lifecycle_guard"),
        SUBCONTRACT(
                "SUBCONTRACT",
                "SUBCONTRACT_APPLICATION",
                "subcontract_applications",
                "subcontract_application_items",
                "subcontract_orders",
                "subcontract_order_items",
                "application_item_id",
                "EB",
                "EO",
                "production_subcontract_application_item_supply_guard",
                "production_subcontract_order_item_supply_guard",
                "production_subcontract_application_supply_guard",
                "production_subcontract_application_lifecycle_guard");

        private final String actionRoute;
        private final String externalDocumentType;
        private final String sourceHeaderTable;
        private final String sourceItemTable;
        private final String orderHeaderTable;
        private final String orderItemTable;
        private final String upstreamColumn;
        private final String sourceBillPrefix;
        private final String orderBillPrefix;
        private final String directItemConstraint;
        private final String orderItemConstraint;
        private final String liveHeaderConstraint;
        private final String lifecycleHeaderConstraint;

        Route(
                String actionRoute,
                String externalDocumentType,
                String sourceHeaderTable,
                String sourceItemTable,
                String orderHeaderTable,
                String orderItemTable,
                String upstreamColumn,
                String sourceBillPrefix,
                String orderBillPrefix,
                String directItemConstraint,
                String orderItemConstraint,
                String liveHeaderConstraint,
                String lifecycleHeaderConstraint) {
            this.actionRoute = actionRoute;
            this.externalDocumentType = externalDocumentType;
            this.sourceHeaderTable = sourceHeaderTable;
            this.sourceItemTable = sourceItemTable;
            this.orderHeaderTable = orderHeaderTable;
            this.orderItemTable = orderItemTable;
            this.upstreamColumn = upstreamColumn;
            this.sourceBillPrefix = sourceBillPrefix;
            this.orderBillPrefix = orderBillPrefix;
            this.directItemConstraint = directItemConstraint;
            this.orderItemConstraint = orderItemConstraint;
            this.liveHeaderConstraint = liveHeaderConstraint;
            this.lifecycleHeaderConstraint = lifecycleHeaderConstraint;
        }
    }

    private record Fixture(
            UUID userId,
            UUID warehouseId,
            UUID unitId,
            UUID goodsId,
            UUID analysisId,
            UUID analysisItemId,
            UUID materialId) {
    }

    private record ExternalSource(
            UUID actionId,
            UUID allocationId,
            UUID sourceHeaderId,
            UUID sourceItemId,
            String documentNo) {
    }

    private record OrderSource(
            UUID orderId,
            UUID orderItemId,
            String billNo) {
    }
}
