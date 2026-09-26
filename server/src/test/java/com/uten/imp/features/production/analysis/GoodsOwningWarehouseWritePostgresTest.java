package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/**
 * V587 所属仓库回写的真库行为 (GoodsOwningWarehouseWriteService)。
 *
 * <p>专门跑真 PostgreSQL 而不是 mock：这条路径上有两件事只有真库能证伪——
 * ① 清空时 {@code owning_warehouse_id = CAST(? AS uuid)} 绑 null 参数能不能过
 * (裸 ? 绑 null 在 PG 驱动上有推不出参数类型的历史坑)；
 * ② {@code version = version + 1} 与「无变化不落盘」的组合是否真的只在该动时才动。
 */
@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsOwningWarehouseWritePostgresTest {

    @Test
    void sharedUuidComparatorMatchesRealPostgresForBothUnsignedHalves() {
        List<UUID> ids = new ArrayList<>(List.of(
                UUID.fromString("7fffffff-ffff-ffff-ffff-ffffffffffff"),
                UUID.fromString("80000000-0000-0000-0000-000000000000"),
                UUID.fromString("00000000-0000-0000-7fff-ffffffffffff"),
                UUID.fromString("00000000-0000-0000-8000-000000000000")));
        for (int index = 0; index < 128; index++) ids.add(UUID.randomUUID());
        String literal = "{" + ids.stream().map(UUID::toString).collect(java.util.stream.Collectors.joining(",")) + "}";
        List<UUID> databaseOrder = jdbc.queryForList(
                "SELECT id FROM unnest(CAST(? AS uuid[])) AS id ORDER BY id", UUID.class, literal);
        assertEquals(databaseOrder, ids.stream().sorted(com.uten.imp.common.util.PostgresUuidOrder.INSTANCE).toList());
    }

    @Container
    private static final PostgreSQLContainer<?> POSTGRES =
            new PostgreSQLContainer<>("postgres:16-alpine");

    private static final UUID ACTOR = UUID.fromString("90000000-0000-4000-8000-000000000001");
    private static final UUID WAREHOUSE_A = UUID.fromString("20000000-0000-4000-8000-00000000000a");
    private static final UUID WAREHOUSE_B = UUID.fromString("20000000-0000-4000-8000-00000000000b");
    private static final UUID WAREHOUSE_DELETED = UUID.fromString("20000000-0000-4000-8000-00000000000d");
    private static final UUID GOODS_PLAIN = UUID.fromString("10000000-0000-4000-8000-000000000001");
    private static final UUID GOODS_ALREADY_A = UUID.fromString("10000000-0000-4000-8000-000000000002");
    private static final UUID GOODS_SOFT_DELETED = UUID.fromString("10000000-0000-4000-8000-000000000003");
    private static final UUID GOODS_ABSENT = UUID.fromString("10000000-0000-4000-8000-0000000000ff");

    private static JdbcTemplate jdbc;
    private GoodsOwningWarehouseWriteService service;

    @BeforeAll
    static void schema() {
        jdbc = new JdbcTemplate(new DriverManagerDataSource(
                POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        jdbc.execute("""
                CREATE TABLE warehouses(
                    id uuid PRIMARY KEY,
                    name text,
                    is_line_side boolean NOT NULL DEFAULT false,
                    is_deleted boolean NOT NULL DEFAULT false)
                """);
        jdbc.execute("""
                CREATE TABLE goods(
                    id uuid PRIMARY KEY,
                    name text,
                    owning_warehouse_id uuid REFERENCES warehouses(id) ON DELETE RESTRICT,
                    version bigint NOT NULL DEFAULT 0,
                    updated_at timestamptz NOT NULL DEFAULT now(),
                    updated_by uuid,
                    is_deleted boolean NOT NULL DEFAULT false, default_purchase_price_color_id uuid, default_purchase_price_currency_id uuid, default_purchase_price_supplier_id uuid, default_purchase_price_tax_rate numeric(18,4), default_purchase_price_unit_id uuid, default_subcontract_price_color_id uuid, default_subcontract_price_currency_id uuid, default_subcontract_price_supplier_id uuid, default_subcontract_price_tax_rate numeric(18,4), default_subcontract_price_unit_id uuid, production_overproduction_rate numeric(9,6))
                """);
    }

    @BeforeEach
    void fixture() {
        jdbc.update("DELETE FROM goods");
        jdbc.update("DELETE FROM warehouses");
        jdbc.update("INSERT INTO warehouses(id, name, is_deleted) VALUES (?,?,false),(?,?,false),(?,?,true)",
                WAREHOUSE_A, "五金仓库", WAREHOUSE_B, "塑胶仓库", WAREHOUSE_DELETED, "已删仓");
        jdbc.update("INSERT INTO goods(id, name, owning_warehouse_id, is_deleted) VALUES (?,?,NULL,false)",
                GOODS_PLAIN, "未登记归属的货品");
        jdbc.update("INSERT INTO goods(id, name, owning_warehouse_id, is_deleted) VALUES (?,?,?,false)",
                GOODS_ALREADY_A, "已归五金仓库的货品", WAREHOUSE_A);
        jdbc.update("INSERT INTO goods(id, name, owning_warehouse_id, is_deleted) VALUES (?,?,NULL,true)",
                GOODS_SOFT_DELETED, "已软删的货品");

        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireId()).thenReturn(ACTOR);
        service = new GoodsOwningWarehouseWriteService(
                jdbc, currentUser, mock(TxSessionVars.class));
    }

    @Test
    void assignsWarehouseAndBumpsVersionWithActor() {
        Map<String, Integer> result = service.applyOwningWarehouses(List.of(
                new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(GOODS_PLAIN, WAREHOUSE_B)));

        assertEquals(1, result.get("updated"));
        assertEquals(0, result.get("skipped"));
        assertEquals(WAREHOUSE_B, owningWarehouseOf(GOODS_PLAIN));
        assertEquals(1L, versionOf(GOODS_PLAIN), "落盘必须把乐观锁版本推进一格");
        assertEquals(ACTOR, jdbc.queryForObject(
                "SELECT updated_by FROM goods WHERE id = ?", UUID.class, GOODS_PLAIN));
    }

    /** 清空走的是 CAST(? AS uuid) 绑 null——这一条就是为了证明它在真库上不炸。 */
    @Test
    void clearsWarehouseWhenTargetIsNull() {
        Map<String, Integer> result = service.applyOwningWarehouses(List.of(
                new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(GOODS_ALREADY_A, null)));

        assertEquals(1, result.get("updated"), "清空是一次正经写入，不是跳过");
        assertNull(owningWarehouseOf(GOODS_ALREADY_A));
        assertEquals(1L, versionOf(GOODS_ALREADY_A));
    }

    @Test
    void skipsUnchangedRowsWithoutTouchingVersion() {
        Map<String, Integer> result = service.applyOwningWarehouses(List.of(
                new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(GOODS_ALREADY_A, WAREHOUSE_A)));

        assertEquals(0, result.get("updated"));
        assertEquals(1, result.get("skipped"));
        assertEquals(0L, versionOf(GOODS_ALREADY_A), "没真的改，就不该推进版本");
    }

    @Test
    void skipsSoftDeletedAndUnknownGoodsInsteadOfFailingTheBatch() {
        Map<String, Integer> result = service.applyOwningWarehouses(List.of(
                new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(GOODS_SOFT_DELETED, WAREHOUSE_A),
                new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(GOODS_ABSENT, WAREHOUSE_A),
                new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(GOODS_PLAIN, WAREHOUSE_A)));

        assertEquals(1, result.get("updated"));
        assertEquals(2, result.get("skipped"));
        assertNull(owningWarehouseOf(GOODS_SOFT_DELETED), "软删货品一个字节都不该动");
    }

    @Test
    void rejectsWholeBatchWhenTargetWarehouseIsDeletedOrUnknown() {
        for (UUID bad : List.of(WAREHOUSE_DELETED, UUID.randomUUID())) {
            assertThrows(ApiException.class, () -> service.applyOwningWarehouses(List.of(
                    new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(GOODS_PLAIN, bad))));
            assertNull(owningWarehouseOf(GOODS_PLAIN), "fail-closed：整批拒绝时不许落一半");
        }
    }

    @Test
    void rejectsLineSideWarehouseBeforeAnyGoodsAreChanged() {
        jdbc.update("UPDATE warehouses SET is_line_side = true WHERE id = ?", WAREHOUSE_B);
        assertThrows(ApiException.class, () -> service.applyOwningWarehouses(List.of(
                new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(GOODS_PLAIN, WAREHOUSE_A),
                new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(GOODS_ALREADY_A, WAREHOUSE_B))));
        assertNull(owningWarehouseOf(GOODS_PLAIN));
        assertEquals(WAREHOUSE_A, owningWarehouseOf(GOODS_ALREADY_A));
    }

    @Test
    void rejectsOversizedBatch() {
        List<GoodsOwningWarehouseWriteService.OwningWarehouseRequest> many = new ArrayList<>();
        for (int i = 0; i < 201; i++) {
            many.add(new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(
                    UUID.randomUUID(), WAREHOUSE_A));
        }
        assertThrows(ApiException.class, () -> service.applyOwningWarehouses(many));
    }

    /** 同一货品在一屏里出现多次时以最后一行为准，不是写两遍。 */
    @Test
    void lastEntryWinsForRepeatedGoods() {
        Map<String, Integer> result = service.applyOwningWarehouses(List.of(
                new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(GOODS_PLAIN, WAREHOUSE_A),
                new GoodsOwningWarehouseWriteService.OwningWarehouseRequest(GOODS_PLAIN, WAREHOUSE_B)));

        assertEquals(1, result.get("updated"));
        assertEquals(WAREHOUSE_B, owningWarehouseOf(GOODS_PLAIN));
        assertEquals(1L, versionOf(GOODS_PLAIN), "去重后只写一次，版本只推进一格");
    }

    private UUID owningWarehouseOf(UUID goodsId) {
        return jdbc.queryForObject(
                "SELECT owning_warehouse_id FROM goods WHERE id = ?", UUID.class, goodsId);
    }

    private long versionOf(UUID goodsId) {
        Long version = jdbc.queryForObject(
                "SELECT version FROM goods WHERE id = ?", Long.class, goodsId);
        return version == null ? -1L : version;
    }
}
