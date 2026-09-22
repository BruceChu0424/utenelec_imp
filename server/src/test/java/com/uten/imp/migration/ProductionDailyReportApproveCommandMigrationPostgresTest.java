package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.time.LocalDate;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * V640 -> V644 非空前向彩排：把 V409 的「创建命令账本」升级为「日报命令账本」。
 *
 * <p>钉住四件事：存量行回填成 CREATE；命令种类只认三个值；一张日报每种命令各一条、
 * 不能有第二条同种命令；(操作者, 幂等键) 仍然全局唯一，一把键不能跨命令种类复用。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionDailyReportApproveCommandMigrationPostgresTest {

    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine")
                    .withDatabaseName("uten_imp")
                    .withUsername("uten")
                    .withPassword("uten");

    private static final String HASH_A = "a".repeat(64);
    private static final String HASH_B = "b".repeat(64);

    private static final java.util.concurrent.atomic.AtomicInteger BILL_SEQUENCE =
            new java.util.concurrent.atomic.AtomicInteger();

    private static UUID actorUserId;
    private static UUID legacyReportId;

    @BeforeAll
    static void rehearseUpgradeOverExistingCreateCommands() throws Exception {
        POSTGRES.start();
        flyway("640").migrate();

        try (Connection connection = connection()) {
            UUID departmentId = UUID.randomUUID();
            update(connection, """
                    INSERT INTO departments(id,code,name,level)
                    VALUES(?,?,?,'一级部门')
                    """, departmentId, "V644-D", "V644 车间");
            UUID employeeId = UUID.randomUUID();
            update(connection, """
                    INSERT INTO employees(
                        id,code,full_name,id_type,department_id,hire_date,
                        status,employment_type)
                    VALUES(?,?,?,'其他',?,?,'active','regular')
                    """, employeeId, "V644-E", "V644 操作者", departmentId,
                    LocalDate.of(2026, 9, 22));
            actorUserId = UUID.randomUUID();
            update(connection, """
                    INSERT INTO users(
                        id,employee_id,login_account,password_hash,status)
                    VALUES(?,?,?,?,'active')
                    """, actorUserId, employeeId, "v644-" + actorUserId,
                    "test-only-hash");

            legacyReportId = UUID.randomUUID();
            insertReport(connection, legacyReportId);
            // 升级前只有创建命令，且这一行是在没有 command_kind 的表上写的。
            update(connection, """
                    INSERT INTO production_daily_report_commands(
                        id,actor_user_id,idempotency_key,request_hash,
                        report_id,created_by)
                    VALUES(?,?,?,?,?,?)
                    """, UUID.randomUUID(), actorUserId, "legacy-create-key",
                    HASH_A, legacyReportId, actorUserId);
        }

        flyway(null).migrate();
    }

    @AfterAll
    static void stopPostgres() {
        POSTGRES.stop();
    }

    @Test
    void existingRowsBackfillToCreateSoHistoryKeepsItsMeaning() throws Exception {
        try (Connection connection = connection();
             PreparedStatement statement = connection.prepareStatement("""
                     SELECT command_kind FROM production_daily_report_commands
                     WHERE idempotency_key='legacy-create-key'
                     """);
             ResultSet rows = statement.executeQuery()) {
            assertTrue(rows.next(), "升级不能丢掉存量命令行");
            assertEquals("CREATE", rows.getString(1),
                    "升级前的命令只可能是创建，必须回填成 CREATE");
        }
    }

    @Test
    void oneReportTakesOneCreateAndOneApproveButNeverTwoApprovals() throws Exception {
        try (Connection connection = connection()) {
            // 同一张日报可以再多一条审核命令。
            update(connection, """
                    INSERT INTO production_daily_report_commands(
                        id,actor_user_id,idempotency_key,request_hash,
                        report_id,created_by,command_kind)
                    VALUES(?,?,?,?,?,?, 'APPROVE')
                    """, UUID.randomUUID(), actorUserId, "approve-key-1",
                    HASH_B, legacyReportId, actorUserId);

            // 但第二条审核命令必须被唯一键挡住——重复审核不能靠换一把键绕过去。
            PSQLException duplicate = assertThrows(PSQLException.class, () ->
                    update(connection, """
                            INSERT INTO production_daily_report_commands(
                                id,actor_user_id,idempotency_key,request_hash,
                                report_id,created_by,command_kind)
                            VALUES(?,?,?,?,?,?, 'APPROVE')
                            """, UUID.randomUUID(), actorUserId, "approve-key-2",
                            HASH_B, legacyReportId, actorUserId));
            assertTrue(String.valueOf(duplicate.getMessage())
                            .contains("uq_production_daily_report_command_report_kind"),
                    "一张日报只能有一条审核命令: " + duplicate.getMessage());
        }
    }

    @Test
    void oneKeyStillBindsToOneCommandAcrossKinds() throws Exception {
        try (Connection connection = connection()) {
            UUID otherReportId = UUID.randomUUID();
            insertReport(connection, otherReportId);
            PSQLException reused = assertThrows(PSQLException.class, () ->
                    update(connection, """
                            INSERT INTO production_daily_report_commands(
                                id,actor_user_id,idempotency_key,request_hash,
                                report_id,created_by,command_kind)
                            VALUES(?,?,?,?,?,?, 'APPROVE')
                            """, UUID.randomUUID(), actorUserId,
                            "legacy-create-key", HASH_B, otherReportId, actorUserId));
            assertTrue(String.valueOf(reused.getMessage())
                            .contains("uq_production_daily_report_command_actor_key"),
                    "同一操作者的一把键仍然只能绑一条命令: " + reused.getMessage());
        }
    }

    @Test
    void unknownCommandKindsAreRejectedAtTheDatabase() throws Exception {
        try (Connection connection = connection()) {
            UUID reportId = UUID.randomUUID();
            insertReport(connection, reportId);
            PSQLException invalid = assertThrows(PSQLException.class, () ->
                    update(connection, """
                            INSERT INTO production_daily_report_commands(
                                id,actor_user_id,idempotency_key,request_hash,
                                report_id,created_by,command_kind)
                            VALUES(?,?,?,?,?,?, 'CANCEL')
                            """, UUID.randomUUID(), actorUserId, "cancel-key-1",
                            HASH_B, reportId, actorUserId));
            assertTrue(String.valueOf(invalid.getMessage())
                            .contains("production_daily_report_command_kind_chk"),
                    "命令种类只认 CREATE/APPROVE/REVERSE: " + invalid.getMessage());
        }
    }

    private static void insertReport(Connection connection, UUID reportId)
            throws Exception {
        update(connection, """
                INSERT INTO production_daily_reports(
                    id,bill_no,bill_date,status,remark)
                VALUES(?,?,?,0,?)
                """, reportId,
                "SR20260922%06d".formatted(BILL_SEQUENCE.incrementAndGet()),
                LocalDate.of(2026, 9, 22), "V644 rehearsal");
    }

    private static Flyway flyway(String target) {
        var configuration = Flyway.configure()
                .dataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(),
                        POSTGRES.getPassword())
                .locations("classpath:db/migration");
        return target == null
                ? configuration.load()
                : configuration.target(target).load();
    }

    private static Connection connection() throws Exception {
        return DriverManager.getConnection(POSTGRES.getJdbcUrl(),
                POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    /** 直接抛 SQLException，用例才能断言撞的是哪一条约束。 */
    private static void update(Connection connection, String sql, Object... args)
            throws java.sql.SQLException {
        try (PreparedStatement statement = connection.prepareStatement(sql)) {
            for (int index = 0; index < args.length; index++) {
                statement.setObject(index + 1, args[index]);
            }
            statement.executeUpdate();
        }
    }
}
