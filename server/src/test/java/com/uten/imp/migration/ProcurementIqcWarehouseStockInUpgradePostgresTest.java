package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.math.BigDecimal;
import java.sql.Connection;
import java.sql.DriverManager;
import java.time.OffsetDateTime;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

@Testcontainers(disabledWithoutDocker = true)
class ProcurementIqcWarehouseStockInUpgradePostgresTest {

    @Container
    static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16.15-alpine")
                    .withDatabaseName("iqc_v446_upgrade")
                    .withUsername("uten")
                    .withPassword("uten");

    @Test
    void provenHistoricalPassIsBackfilledWithoutCreatingANewWarehouseTask()
            throws Exception {
        String url = database("iqc_v446_proven");
        migrate(url, "445");
        Fixture fixture = seedHistoricalPass(url, true);

        migrate(url, null);

        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword())) {
            try (var statement = connection.prepareStatement("""
                    SELECT warehouse_stocked_base_qty,
                           warehouse_stocked_amount_local,
                           legacy_stocked_base_qty,
                           legacy_stocked_amount_local
                    FROM procurement_inspection_items
                    WHERE id = ?
                    """)) {
                statement.setObject(1, fixture.inspectionItemId());
                try (var rows = statement.executeQuery()) {
                    assertThat(rows.next()).isTrue();
                    assertThat(rows.getBigDecimal(1)).isEqualByComparingTo("10");
                    assertThat(rows.getBigDecimal(2)).isEqualByComparingTo("100");
                    assertThat(rows.getBigDecimal(3)).isEqualByComparingTo("10");
                    assertThat(rows.getBigDecimal(4)).isEqualByComparingTo("100");
                }
            }
            try (var statement = connection.prepareStatement("""
                    SELECT requires_warehouse_stock_in,
                           released_amount_local,
                           released_weight
                    FROM procurement_inspection_events
                    WHERE id = ?
                    """)) {
                statement.setObject(1, fixture.passEventId());
                try (var rows = statement.executeQuery()) {
                    assertThat(rows.next()).isTrue();
                    assertThat(rows.getBoolean(1)).isFalse();
                    assertThat(rows.getObject(2)).isNull();
                    assertThat(rows.getObject(3)).isNull();
                }
            }
            try (var statement = connection.prepareStatement("""
                    SELECT override.effect, override.active
                    FROM user_permission_overrides override
                    JOIN permissions permission ON permission.id = override.permission_id
                    WHERE override.user_id = ?
                      AND permission.code = 'warehouse_iqc_stock_in:confirm'
                    """)) {
                statement.setObject(1, fixture.overrideUserId());
                try (var rows = statement.executeQuery()) {
                    assertThat(rows.next()).isTrue();
                    assertThat(rows.getString(1)).isEqualTo("revoke");
                    assertThat(rows.getBoolean(2)).isTrue();
                }
            }
            try (var statement = connection.prepareStatement("""
                    SELECT count(*)
                    FROM manager_permission_delegations delegation
                    JOIN permissions permission
                      ON permission.id=delegation.permission_id
                    WHERE delegation.user_id=?
                      AND permission.code='warehouse_iqc_stock_in:view'
                      AND delegation.enabled=TRUE
                      AND delegation.surface_key='warehouse.iqc-stock-in'
                    """)) {
                statement.setObject(1, fixture.overrideUserId());
                try (var rows = statement.executeQuery()) {
                    assertThat(rows.next()).isTrue();
                    assertThat(rows.getInt(1)).isEqualTo(1);
                }
            }
            assertThatThrownBy(() -> {
                try (var statement = connection.prepareStatement("""
                        INSERT INTO stock_movements(
                            transaction_date,movement_type,source_doc_type,
                            source_doc_id,source_item_id,goods_id,warehouse_id,
                            direction,qty,unit_rate,amount_local,remark)
                        SELECT now(),1,inspection.receipt_type || '_RECEIPT',
                               inspection.receipt_id,inspection.id,
                               inspection.goods_id,inspection.warehouse_id,
                               1,1,inspection.unit_rate,0,'old application writer'
                        FROM procurement_inspection_items inspection
                        WHERE inspection.id=?
                        """)) {
                    statement.setObject(1, fixture.inspectionItemId());
                    statement.executeUpdate();
                }
            }).hasMessageContaining("pre-V446 IQC automatic stock-in writer");
            assertThatThrownBy(() -> {
                try (var statement = connection.prepareStatement("""
                        INSERT INTO procurement_inspection_events(
                            id,inspection_item_id,action,base_qty,reason,
                            actor_employee_id,occurred_at)
                        SELECT ?,?,'PASS',1,NULL,user_account.employee_id,now()
                        FROM users user_account WHERE user_account.id=?
                        """)) {
                    statement.setObject(1, UUID.randomUUID());
                    statement.setObject(2, fixture.inspectionItemId());
                    statement.setObject(3, fixture.overrideUserId());
                    statement.executeUpdate();
                }
            }).hasMessageContaining("must explicitly require warehouse stock-in");
        }
    }

    @Test
    void unprovenHistoricalPassFailsClosedInsteadOfFabricatingStock()
            throws Exception {
        String url = database("iqc_v446_drift");
        migrate(url, "445");
        seedHistoricalPass(url, false);

        assertThatThrownBy(() -> migrate(url, null))
                .hasMessageContaining("cannot prove legacy IQC PASS stock postings");
    }

    @Test
    void historicalWeightUnitMismatchFailsClosedInsteadOfFreezingMixedEvidence()
            throws Exception {
        String url = database("iqc_v446_weight_unit_drift");
        migrate(url, "445");
        Fixture fixture = seedHistoricalPass(url, true);
        UUID inspectionWeightUnitId = UUID.randomUUID();
        UUID movementWeightUnitId = UUID.randomUUID();
        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword())) {
            try (var statement = connection.prepareStatement("""
                    INSERT INTO units(id,code,name,status)
                    VALUES (?,?,'inspection weight','使用'),
                           (?,?,'movement weight','使用')
                    """)) {
                statement.setObject(1, inspectionWeightUnitId);
                statement.setString(2, "V446-IW-" + inspectionWeightUnitId);
                statement.setObject(3, movementWeightUnitId);
                statement.setString(4, "V446-MW-" + movementWeightUnitId);
                statement.executeUpdate();
            }
            try (var statement = connection.prepareStatement("""
                    UPDATE procurement_inspection_items
                    SET received_weight=5, received_weight_unit_id=?
                    WHERE id=?
                    """)) {
                statement.setObject(1, inspectionWeightUnitId);
                statement.setObject(2, fixture.inspectionItemId());
                statement.executeUpdate();
            }
            try (var statement = connection.prepareStatement("""
                    UPDATE stock_movements
                    SET weight=5, actual_weight_unit_id=?
                    WHERE source_item_id=?
                    """)) {
                statement.setObject(1, movementWeightUnitId);
                statement.setObject(2, fixture.inspectionItemId());
                statement.executeUpdate();
            }
        }

        assertThatThrownBy(() -> migrate(url, null))
                .hasMessageContaining("cannot prove legacy IQC PASS stock postings");
    }

    @Test
    void inactiveSourcePermissionFailsClosedBeforeCreatingNewAuthorities()
            throws Exception {
        String url = database("iqc_v446_inactive_source_permission");
        migrate(url, "445");
        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword());
             var statement = connection.createStatement()) {
            statement.executeUpdate("""
                    UPDATE permissions SET active=FALSE
                    WHERE code='warehouse_inbound:stock_in'
                    """);
        }

        assertThatThrownBy(() -> migrate(url, null))
                .hasMessageContaining("source warehouse inbound permissions are missing, inactive or semantically incompatible");
    }

    @Test
    void staleManagerDelegationIsNotRevivedWithFreshV446Generations()
            throws Exception {
        String url = database("iqc_v446_stale_manager_delegation");
        migrate(url, "445");
        Fixture fixture = seedHistoricalPass(url, true);
        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword());
             var statement = connection.prepareStatement("""
                     UPDATE users
                     SET permission_delegation_generation=
                         permission_delegation_generation+1
                     WHERE id=?
                     """)) {
            statement.setObject(1, fixture.overrideUserId());
            assertThat(statement.executeUpdate()).isEqualTo(1);
        }

        migrate(url, null);

        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword());
             var statement = connection.prepareStatement("""
                     SELECT count(*)
                     FROM manager_permission_delegations delegation
                     JOIN permissions permission
                       ON permission.id=delegation.permission_id
                     WHERE delegation.user_id=?
                       AND permission.code='warehouse_iqc_stock_in:view'
                     """)) {
            statement.setObject(1, fixture.overrideUserId());
            try (var rows = statement.executeQuery()) {
                assertThat(rows.next()).isTrue();
                assertThat(rows.getInt(1)).isZero();
            }
        }
    }

    @Test
    void reversedHistoricalInspectionKeepsZeroProjectionAndUnknownWeight()
            throws Exception {
        String url = database("iqc_v446_reversed");
        migrate(url, "445");
        Fixture fixture = seedHistoricalPass(url, true);
        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword());
             var statement = connection.createStatement()) {
            statement.execute("SET session_replication_role = replica");
            statement.executeUpdate("""
                    UPDATE procurement_inspection_items
                    SET status='REVERSED', passed_base_qty=0, failed_base_qty=0,
                        received_weight=5
                    WHERE id='%s'
                    """.formatted(fixture.inspectionItemId()));
            statement.executeUpdate("""
                    UPDATE stock_movements SET weight=5
                    WHERE source_item_id='%s'
                    """.formatted(fixture.inspectionItemId()));
            statement.execute("SET session_replication_role = origin");
        }

        migrate(url, null);

        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword());
             var statement = connection.prepareStatement("""
                     SELECT warehouse_stocked_base_qty,
                            warehouse_stocked_amount_local,
                            warehouse_stocked_weight,
                            legacy_stocked_base_qty,
                            legacy_stocked_amount_local,
                            legacy_stocked_weight
                     FROM procurement_inspection_items WHERE id=?
                     """)) {
            statement.setObject(1, fixture.inspectionItemId());
            try (var rows = statement.executeQuery()) {
                assertThat(rows.next()).isTrue();
                assertThat(rows.getBigDecimal(1)).isEqualByComparingTo("0");
                assertThat(rows.getBigDecimal(2)).isEqualByComparingTo("0");
                assertThat(rows.getObject(3)).isNull();
                assertThat(rows.getBigDecimal(4)).isEqualByComparingTo("0");
                assertThat(rows.getBigDecimal(5)).isEqualByComparingTo("0");
                assertThat(rows.getObject(6)).isNull();
            }
        }
    }

    @Test
    void preexistingTargetPermissionFailsClosedInsteadOfOverwritingProvenance()
            throws Exception {
        String url = database("iqc_v446_permission_collision");
        migrate(url, "445");
        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword());
             var statement = connection.createStatement()) {
            statement.executeUpdate("""
                    INSERT INTO permissions(
                        code,name,module,category,sort_order,action_type,
                        description,active,assignable,bulk_assignable,sensitivity)
                    VALUES (
                        'warehouse_iqc_stock_in:view','foreign target',
                        '仓库管理','冲突测试',999,'VIEW','foreign provenance',
                        TRUE,TRUE,TRUE,'NORMAL')
                    """);
        }

        assertThatThrownBy(() -> migrate(url, null))
                .hasMessageContaining("target IQC stock-in permission codes or surface already exist");
    }

    private static Fixture seedHistoricalPass(String url, boolean withMovement)
            throws Exception {
        UUID warehouseId = UUID.randomUUID();
        UUID goodsId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        UUID receiptItemId = UUID.randomUUID();
        UUID inspectionItemId = UUID.randomUUID();
        UUID passEventId = UUID.randomUUID();
        UUID overrideEmployeeId = UUID.randomUUID();
        UUID overrideUserId = UUID.randomUUID();
        UUID grantorEmployeeId = UUID.randomUUID();
        UUID grantorUserId = UUID.randomUUID();
        try (Connection connection = DriverManager.getConnection(
                url, POSTGRES.getUsername(), POSTGRES.getPassword())) {
            try (var statement = connection.prepareStatement(
                    "INSERT INTO warehouses(id,code,name) VALUES (?,?,?)")) {
                statement.setObject(1, warehouseId);
                statement.setString(2, "W-" + warehouseId);
                statement.setString(3, "V446 upgrade warehouse");
                statement.executeUpdate();
            }
            try (var statement = connection.prepareStatement("""
                    INSERT INTO goods(id,code,name,min_qty,code_sequence)
                    VALUES (?,?,?,0,(SELECT COALESCE(MAX(code_sequence),0)+1 FROM goods))
                    """)) {
                statement.setObject(1, goodsId);
                statement.setString(2, "G-" + goodsId);
                statement.setString(3, "V446 upgrade goods");
                statement.executeUpdate();
            }
            try (var statement = connection.prepareStatement("""
                    INSERT INTO procurement_inspection_items(
                        id,receipt_type,receipt_id,receipt_item_id,
                        warehouse_id,goods_id,unit_rate,
                        received_base_qty,received_amount_local,
                        passed_base_qty,failed_base_qty,status,received_at)
                    VALUES (?,'PURCHASE',?,?,?,?,1,10,100,10,0,'RESOLVED',?)
                    """)) {
                statement.setObject(1, inspectionItemId);
                statement.setObject(2, receiptId);
                statement.setObject(3, receiptItemId);
                statement.setObject(4, warehouseId);
                statement.setObject(5, goodsId);
                statement.setObject(6, OffsetDateTime.parse("2026-08-30T12:00:00Z"));
                statement.executeUpdate();
            }
            try (var statement = connection.prepareStatement("""
                    INSERT INTO procurement_inspection_events(
                        id,inspection_item_id,action,base_qty,reason,occurred_at)
                    VALUES (?,?,'PASS',10,NULL,?)
                    """)) {
                statement.setObject(1, passEventId);
                statement.setObject(2, inspectionItemId);
                statement.setObject(3, OffsetDateTime.parse("2026-08-30T13:00:00Z"));
                statement.executeUpdate();
            }
            if (withMovement) {
                try (var statement = connection.prepareStatement("""
                        INSERT INTO stock_movements(
                            transaction_date,movement_type,source_doc_type,
                            source_doc_id,source_item_id,goods_id,warehouse_id,
                            direction,qty,unit_rate,amount_local,remark)
                        VALUES (?,1,'PURCHASE_RECEIPT',?,?,?,?,1,10,1,100,
                                'pre-V446 IQC PASS')
                        """)) {
                    statement.setObject(1, OffsetDateTime.parse("2026-08-30T13:00:00Z"));
                    statement.setObject(2, receiptId);
                    statement.setObject(3, inspectionItemId);
                    statement.setObject(4, goodsId);
                    statement.setObject(5, warehouseId);
                    statement.executeUpdate();
                }
            }
            UUID warehouseDepartmentId;
            try (var statement = connection.prepareStatement("""
                    SELECT id FROM departments
                    WHERE code='SUB_WH' AND is_deleted=FALSE
                    """)) {
                try (var rows = statement.executeQuery()) {
                    assertThat(rows.next()).isTrue();
                    warehouseDepartmentId = rows.getObject(1, UUID.class);
                }
            }
            try (var statement = connection.prepareStatement("""
                    INSERT INTO employees(
                        id,code,full_name,id_type,department_id,hire_date,
                        status,employment_type)
                    VALUES (?,?,?,'其他',?,DATE '2026-08-30','active','regular'),
                           (?,?,?,'其他',?,DATE '2026-08-30','active','regular')
                    """)) {
                statement.setObject(1, overrideEmployeeId);
                statement.setString(2, "E-V446-" + overrideEmployeeId);
                statement.setString(3, "V446 revoke actor");
                statement.setObject(4, warehouseDepartmentId);
                statement.setObject(5, grantorEmployeeId);
                statement.setString(6, "E-V446-G-" + grantorEmployeeId);
                statement.setString(7, "V446 delegation grantor");
                statement.setObject(8, warehouseDepartmentId);
                statement.executeUpdate();
            }
            try (var statement = connection.prepareStatement("""
                    INSERT INTO users(
                        id,employee_id,login_account,password_hash,
                        must_change_password,is_super_admin,status)
                    VALUES (?,?,?,'x',FALSE,FALSE,'active'),
                           (?,?,?,'x',FALSE,TRUE,'active')
                    """)) {
                statement.setObject(1, overrideUserId);
                statement.setObject(2, overrideEmployeeId);
                statement.setString(3, "v446-revoke-" + overrideUserId);
                statement.setObject(4, grantorUserId);
                statement.setObject(5, grantorEmployeeId);
                statement.setString(6, "v446-grantor-" + grantorUserId);
                statement.executeUpdate();
            }
            try (var statement = connection.prepareStatement("""
                    INSERT INTO user_permission_overrides(
                        user_id,permission_id,effect,authority_source,row_version,active)
                    SELECT ?,permission.id,'revoke','LEGACY_UNKNOWN',1,TRUE
                    FROM permissions permission
                    WHERE permission.code='warehouse_inbound:stock_in'
                    """)) {
                statement.setObject(1, overrideUserId);
                assertThat(statement.executeUpdate()).isEqualTo(1);
            }
            try (var statement = connection.createStatement()) {
                statement.execute("SET session_replication_role=replica");
            }
            try (var statement = connection.prepareStatement("""
                    INSERT INTO manager_permission_delegations(
                        user_id,permission_id,department_id,enabled,surface_key,
                        granted_by_user_id,row_version,created_by,updated_by,
                        target_user_generation,target_employee_generation,
                        target_department_generation,grantor_user_generation,
                        grantor_employee_generation,grantor_auth_version,
                        grantor_authorization_epoch,scope_source,
                        scope_department_id,scope_generation,
                        scope_assignment_id,scope_assignment_version)
                    SELECT target_user.id,permission.id,target_department.id,TRUE,
                           'warehouse.inbound',grantor_user.id,1,
                           grantor_user.id,grantor_user.id,
                           target_user.permission_delegation_generation,
                           target_employee.permission_delegation_generation,
                           target_department.permission_delegation_generation,
                           grantor_user.permission_delegation_generation,
                           NULL,grantor_user.auth_version,auth_state.epoch,
                           'SUPER_ADMIN',NULL,NULL,NULL,NULL
                    FROM users target_user
                    JOIN employees target_employee
                      ON target_employee.id=target_user.employee_id
                    JOIN departments target_department
                      ON target_department.id=target_employee.department_id
                    CROSS JOIN permissions permission
                    JOIN users grantor_user ON grantor_user.id=?
                    CROSS JOIN authorization_state auth_state
                    WHERE target_user.id=?
                      AND permission.code='warehouse_inbound:view'
                      AND auth_state.singleton_id=1
                    """)) {
                statement.setObject(1, grantorUserId);
                statement.setObject(2, overrideUserId);
                assertThat(statement.executeUpdate()).isEqualTo(1);
            } finally {
                try (var statement = connection.createStatement()) {
                    statement.execute("SET session_replication_role=origin");
                }
            }
        }
        return new Fixture(inspectionItemId, passEventId, overrideUserId);
    }

    private static String database(String name) throws Exception {
        try (Connection connection = DriverManager.getConnection(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword())) {
            connection.setAutoCommit(true);
            try (var statement = connection.createStatement()) {
                statement.execute("CREATE DATABASE " + name);
            }
        }
        return "jdbc:postgresql://" + POSTGRES.getHost() + ':'
                + POSTGRES.getMappedPort(5432) + '/' + name + "?loggerLevel=OFF";
    }

    private static void migrate(String url, String target) {
        var configuration = Flyway.configure()
                .dataSource(url, POSTGRES.getUsername(), POSTGRES.getPassword())
                .locations("classpath:db/migration");
        if (target != null) configuration.target(target);
        configuration.load().migrate();
    }

    private record Fixture(
            UUID inspectionItemId, UUID passEventId, UUID overrideUserId) {
    }
}
