package com.uten.imp.features.stock;

import org.junit.jupiter.api.BeforeAll;
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
    private static final UUID GOODS_PLAIN = UUID.fromString("10000000-0000-4000-8000-000000000001");
    private static final UUID GOODS_AT_A = UUID.fromString("10000000-0000-4000-8000-000000000002");
    private static final UUID GOODS_ABSENT = UUID.fromString("10000000-0000-4000-8000-0000000000ff");

    private static JdbcTemplate jdbc;
    private GoodsOwningWarehouseSyncService service;

    @BeforeAll
    static void schema() {
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        jdbc.execute("""
                CREATE TABLE warehouses(
                    id uuid PRIMARY KEY,
                    name text)
                """);
        jdbc.execute("""
                CREATE TABLE goods(
                    id uuid PRIMARY KEY,
                    name text,
                    owning_warehouse_id uuid REFERENCES warehouses(id) ON DELETE RESTRICT,
                    version bigint NOT NULL DEFAULT 0)
                """);
        // 模拟 goods 的版本触发器：任何真实回写让 version+1（无变化的 UPDATE
        // 也算回写——所以服务层必须用 IS DISTINCT FROM 挡住无谓落盘）。
        jdbc.execute("""
                CREATE FUNCTION bump_goods_version() RETURNS trigger AS $fn$
                BEGIN
                    NEW.version := OLD.version + 1;
                    RETURN NEW;
                END $fn$ LANGUAGE plpgsql
                """);
        jdbc.execute(
                "CREATE TRIGGER goods_version BEFORE UPDATE ON goods FOR EACH ROW EXECUTE FUNCTION bump_goods_version()");
    }

    @BeforeEach
    void fixture() {
        jdbc.update("DELETE FROM goods");
        jdbc.update("DELETE FROM warehouses");
        jdbc.update("INSERT INTO warehouses(id, name) VALUES (?, 'A'), (?, 'B')",
                WAREHOUSE_A, WAREHOUSE_B);
        jdbc.update("INSERT INTO goods(id, name) VALUES (?, 'plain')", GOODS_PLAIN);
        jdbc.update(
                "INSERT INTO goods(id, name, owning_warehouse_id) VALUES (?, 'at-a', ?)",
                GOODS_AT_A, WAREHOUSE_A);
        service = new GoodsOwningWarehouseSyncService(jdbc);
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

    private UUID owningWarehouse(UUID goodsId) {
        return jdbc.queryForObject(
                "SELECT owning_warehouse_id FROM goods WHERE id = ?", UUID.class, goodsId);
    }

    private long version(UUID goodsId) {
        return jdbc.queryForObject(
                "SELECT version FROM goods WHERE id = ?", Long.class, goodsId);
    }
}
