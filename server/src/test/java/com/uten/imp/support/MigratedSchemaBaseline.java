package com.uten.imp.support;

import org.flywaydb.core.Flyway;
import org.testcontainers.containers.PostgreSQLContainer;

import java.io.IOException;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;

/**
 * <b>真实迁移基线（2026-09-18 起）：新 fixture 不再手写 DDL 的根治路径。</b>
 *
 * <p>历史问题：约 80 个 {@code *PostgresTest} 各自手写最小建表语句，迁移每给
 * 既有表加一列（V584/V595/V599 一轮 7 类失败），fixture 不跟 CI 就红一轮
 * 1.5 小时的 DB 全链。本类提供从 <b>真实 Flyway 迁移目录</b>生成的共享基线：
 * 迁移到头一次，之后按 Postgres 模板库机制低成本克隆给每个测试类——
 * schema 永远等于正式目录头，迁移加列零维护，也不存在「fixture 列漂移」。
 *
 * <p>用法（对照 {@code AuditClassificationMigrationPostgresTest} 的既有模式）：
 * <pre>
 * static final PostgreSQLContainer&lt;?&gt; TEMPLATE = MigratedSchemaBaseline.startMigratedContainer("my_test_template");
 *
 * // 每个用例（或每个测试类）克隆一份，互不污染：
 * try (Connection db = MigratedSchemaBaseline.cloneConnection(TEMPLATE, "my_test_case")) {
 *     // 只插入行级 fixture；真实表/视图/函数/触发器全部就位
 * }
 * </pre>
 *
 * <p>克隆用容器自带的 {@code createdb -T}（模板库机制，秒级、含全部
 * 表/视图/函数/触发器），数据库名走命令行参数、不进 SQL 文本。
 * 注意：模板库克隆要求模板上没有并发会话（Postgres 限制），克隆前先关掉
 * 指向模板库的连接（本类迁完后即刻释放，Flyway 连接池随容器生命周期关闭）。
 */
public final class MigratedSchemaBaseline {

    private MigratedSchemaBaseline() {
    }

    /**
     * 启动一个 postgres:16-alpine 容器并把正式迁移目录跑到头。
     * 返回的容器自身数据库就是模板库（schema = 当前迁移头）。
     */
    public static PostgreSQLContainer<?> startMigratedContainer(String databaseName) {
        PostgreSQLContainer<?> postgres = new PostgreSQLContainer<>("postgres:16-alpine")
                .withDatabaseName(databaseName);
        postgres.start();
        Flyway.configure()
                .dataSource(postgres.getJdbcUrl(), postgres.getUsername(), postgres.getPassword())
                .locations("classpath:db/migration")
                .load()
                .migrate();
        return postgres;
    }

    /**
     * 在同一实例上从模板库克隆一个新数据库（Postgres TEMPLATE 机制），返回指向
     * 克隆库的连接。克隆库与模板库、与其它克隆库完全隔离。
     */
    public static Connection cloneConnection(
            PostgreSQLContainer<?> template, String cloneDatabaseName) throws SQLException {
        try {
            template.execInContainer(
                    "createdb", "-U", template.getUsername(),
                    "-T", template.getDatabaseName(), cloneDatabaseName);
        } catch (InterruptedException failure) {
            Thread.currentThread().interrupt();
            throw new SQLException("模板库克隆被中断", failure);
        } catch (IOException failure) {
            throw new SQLException("模板库克隆失败", failure);
        }
        return DriverManager.getConnection(
                jdbcUrlFor(template, cloneDatabaseName),
                template.getUsername(), template.getPassword());
    }

    /** 同实例、指定数据库的 JDBC URL（沿用容器的主机/端口/参数）。 */
    public static String jdbcUrlFor(PostgreSQLContainer<?> container, String databaseName) {
        String url = container.getJdbcUrl();
        int queryStart = url.indexOf('?');
        String baseUrl = queryStart < 0 ? url : url.substring(0, queryStart);
        int lastSlash = baseUrl.lastIndexOf('/');
        String rebuiltUrl = baseUrl.substring(0, lastSlash + 1) + databaseName;
        return queryStart < 0 ? rebuiltUrl : rebuiltUrl + url.substring(queryStart);
    }
}
