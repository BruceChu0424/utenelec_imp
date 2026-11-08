package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.readsnapshot.BoundedMasterReadSource;
import com.uten.imp.support.LoadingGrowthEvidence;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.RowCallbackHandler;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * W7 P4 增长守卫(2026-11-08)：货品完整流每批仍要执行的两条辅助查询，在目录与 BOM 历史增长下
 * 必须按本批 id 走索引、耗时曲线平稳。
 *
 * <p>完整流由 {@link BoundedMasterReadSource} 一条游标读货品(计数只一次)，范围/子树/关键词与
 * 名称映射已按流记忆(W4 P4.2)；逐批重复的只剩 BOM 存在性与库存量两条，33k 行根分类流要跑
 * 331 批。本守卫用一次性容器按迁移里的真实列与索引铺 goods / goods_bom_items / warehouses /
 * stock_balances，固定一批货品，注入 10× 递增的其他货品(各带在用+软删 BOM 行与库存行)，
 * 断言两条查询结果不变、大体量下计划里大表不出现顺序扫描。</p>
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsStreamBatchGrowthPostgresTest {
    /**
     * GoodsService.list 的 BOM 存在性 JPQL 在 Hibernate 下的 SQL 形态：两个外键都是 NOT NULL，
     * 路径上的隐式内连接与原查询逐行等价。只是镜像，生产 JPQL 一变就由
     * {@link #requireBomPresenceJpqlUnchanged()} 拦下，必须同步改写。
     */
    private static final String BOM_PRESENCE_SQL = """
            SELECT DISTINCT b.goods_id FROM goods_bom_items b
            JOIN goods g ON g.id = b.goods_id
            JOIN goods c ON c.id = b.component_goods_id
            WHERE b.goods_id IN (:ids) AND b.is_deleted = false
              AND g.auto_created = false AND c.auto_created = false
            """;
    private static final Set<String> GROWING_TABLES = Set.of("goods", "goods_bom_items", "stock_balances");
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine")
            .withDatabaseName("goods_stream_growth").withReuse(false);
    private Connection connection;
    private NamedParameterJdbcTemplate db;

    @BeforeAll static void start() { POSTGRES.start(); }
    @AfterAll static void stop() { POSTGRES.stop(); }
    @AfterEach void close() throws Exception { if (connection != null) connection.close(); }

    @BeforeEach void fixture() throws Exception {
        connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
        db = new NamedParameterJdbcTemplate(new SingleConnectionDataSource(connection, true));
        var jdbc = db.getJdbcTemplate();
        // 只铺两条查询读到的列；索引逐条照抄迁移(外键约束不影响这两条读计划，省掉以加快注入)。
        jdbc.execute("CREATE TABLE goods (id UUID PRIMARY KEY, auto_created BOOLEAN NOT NULL DEFAULT FALSE)");
        jdbc.execute("""
                CREATE TABLE goods_bom_items (
                  id UUID PRIMARY KEY,
                  goods_id UUID NOT NULL,
                  component_goods_id UUID NOT NULL,
                  qty NUMERIC(18,4) NOT NULL DEFAULT 1,
                  is_deleted BOOLEAN NOT NULL DEFAULT FALSE
                )""");
        jdbc.execute("CREATE INDEX idx_goods_bom_goods ON goods_bom_items(goods_id)");               // V79
        jdbc.execute("CREATE INDEX idx_goods_bom_component ON goods_bom_items(component_goods_id)");  // V79
        jdbc.execute("CREATE INDEX idx_gbi_where_used_active ON goods_bom_items(component_goods_id, goods_id)"
                + " INCLUDE (qty) WHERE is_deleted = FALSE");                                          // V186
        jdbc.execute("""
                CREATE TABLE warehouses (
                  id UUID PRIMARY KEY,
                  is_accountable BOOLEAN NOT NULL,
                  is_defective BOOLEAN NOT NULL,
                  is_line_side BOOLEAN NOT NULL
                )""");
        jdbc.execute("""
                CREATE TABLE stock_balances (
                  id UUID PRIMARY KEY,
                  warehouse_id UUID NOT NULL,
                  goods_id UUID NOT NULL,
                  color_id UUID,
                  qty NUMERIC(18,4) NOT NULL DEFAULT 0,
                  weight NUMERIC(18,4),
                  weight_estimated BOOLEAN NOT NULL DEFAULT FALSE,
                  last_movement_date TIMESTAMPTZ,
                  UNIQUE NULLS NOT DISTINCT (warehouse_id, goods_id, color_id)
                )""");                                                                                 // V45
        jdbc.execute("CREATE INDEX idx_stock_balances_goods_cover ON stock_balances (goods_id)"
                + " INCLUDE (warehouse_id, color_id, qty, weight, weight_estimated, last_movement_date)"); // V743
    }

    @Test void perBatchBomAndStockReadsStayIndexDrivenWhileTheCatalogGrows() throws Exception {
        requireBomPresenceJpqlUnchanged();
        var jdbc = db.getJdbcTemplate();
        int batchRows = BoundedMasterReadSource.BATCH_ROWS;
        assertTrue(batchRows > 70, "固定批的 BOM 分档占用前 70 个货品");
        // 一个完整流批次：最后一个是自动补录的占位货品；组件 20 个正常 + 2 个占位。
        jdbc.execute("CREATE TEMP TABLE batch AS SELECT n, md5('batch'||n)::uuid AS id"
                + " FROM generate_series(1," + batchRows + ")n");
        jdbc.update("INSERT INTO goods(id,auto_created) SELECT id, n=(SELECT max(n) FROM batch) FROM batch");
        jdbc.update("INSERT INTO goods(id,auto_created) SELECT md5('component'||n)::uuid, false FROM generate_series(1,20)n");
        jdbc.update("INSERT INTO goods(id,auto_created) SELECT md5('stub'||n)::uuid, true FROM generate_series(1,2)n");
        // 1-40 两条在用；41-50 只挂占位组件；51-60 只剩软删历史；61-70 软删+在用各一；占位父件挂一条在用。
        jdbc.update("""
                INSERT INTO goods_bom_items(id,goods_id,component_goods_id,is_deleted)
                SELECT md5('bom-live'||n||'-'||k)::uuid, id, md5('component'||(1+(n+k)%20))::uuid, false
                FROM batch, generate_series(1,2)k WHERE n BETWEEN 1 AND 40
                UNION ALL
                SELECT md5('bom-stub'||n)::uuid, id, md5('stub'||(1+n%2))::uuid, false
                FROM batch WHERE n BETWEEN 41 AND 50
                UNION ALL
                SELECT md5('bom-gone'||n||'-'||k)::uuid, id, md5('component'||k)::uuid, true
                FROM batch, generate_series(1,3)k WHERE n BETWEEN 51 AND 60
                UNION ALL
                SELECT md5('bom-mixed'||n||'-'||k)::uuid, id, md5('component'||k)::uuid, k=1
                FROM batch, generate_series(1,2)k WHERE n BETWEEN 61 AND 70
                UNION ALL
                SELECT md5('bom-stub-parent')::uuid, id, md5('component1')::uuid, false
                FROM batch WHERE n=(SELECT max(n) FROM batch)
                """);
        // 只有核算良品仓计入库存量：不良仓、线边仓、不核算仓各放 1000 作干扰；良品仓 2 按两种颜色各一行。
        jdbc.update("""
                INSERT INTO warehouses(id,is_accountable,is_defective,is_line_side) VALUES
                  (md5('wh-good-1')::uuid,true,false,false),(md5('wh-good-2')::uuid,true,false,false),
                  (md5('wh-defective')::uuid,true,true,false),(md5('wh-line-side')::uuid,true,false,true),
                  (md5('wh-outside')::uuid,false,false,false)
                """);
        jdbc.update("""
                INSERT INTO stock_balances(id,warehouse_id,goods_id,color_id,qty)
                SELECT md5('sb-'||w||'-'||n)::uuid, md5(w)::uuid, id, NULL,
                       CASE w WHEN 'wh-good-1' THEN n ELSE 1000 END
                FROM batch, unnest(ARRAY['wh-good-1','wh-defective','wh-line-side','wh-outside'])w
                UNION ALL
                SELECT md5('sb-color'||c||'-'||n)::uuid, md5('wh-good-2')::uuid, id,
                       CASE c WHEN 1 THEN NULL ELSE md5('color-x')::uuid END, c+1
                FROM batch, generate_series(1,2)c
                """);

        List<UUID> batch = jdbc.queryForList("SELECT id FROM batch ORDER BY n", UUID.class);
        Set<UUID> expectedBom = new HashSet<>(batch.subList(0, 40));
        expectedBom.addAll(batch.subList(60, 70));
        Map<String, Object> ids = Map.of("ids", batch);
        int previous = 0;
        for (int history : List.of(10_000, 100_000, 1_000_000)) {
            // 其他货品：每个一条在用 + 一条软删 BOM(编辑历史)，一个良品仓库存行。
            String range = " FROM generate_series(" + (previous + 1) + "," + history + ")n";
            jdbc.update("INSERT INTO goods(id,auto_created) SELECT md5('history'||n)::uuid, false" + range);
            jdbc.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,is_deleted)"
                    + " SELECT md5('history-bom'||n||'-'||k)::uuid, md5('history'||n)::uuid,"
                    + " md5('component'||(1+n%20))::uuid, k=2" + range + ", generate_series(1,2)k");
            jdbc.update("INSERT INTO stock_balances(id,warehouse_id,goods_id,color_id,qty)"
                    + " SELECT md5('history-sb'||n)::uuid, md5('wh-good-1')::uuid, md5('history'||n)::uuid, NULL, 1" + range);
            previous = history;
            // 生产表由 autovacuum 维护统计与可见性图；这里显式做一次，计划才与线上同形。
            for (String table : List.of("goods", "goods_bom_items", "warehouses", "stock_balances"))
                jdbc.execute("VACUUM ANALYZE " + table);

            Set<UUID> withBom = new HashSet<>(db.queryForList(BOM_PRESENCE_SQL, ids, UUID.class));
            assertEquals(expectedBom, withBom, "BOM 存在性只认在用行且父件/组件都不是占位货品");
            Map<UUID, BigDecimal> stock = stockQuantities(ids);
            assertEquals(new HashSet<>(batch), stock.keySet(), "本批每个货品都有核算良品仓库存");
            for (int n = 1; n <= batchRows; n++) {
                BigDecimal quantity = stock.get(batch.get(n - 1));
                assertTrue(quantity.compareTo(BigDecimal.valueOf(n + 5L)) == 0,
                        "库存量只合计核算良品仓(含两种颜色)：货品 " + n + " 实得 " + quantity);
            }

            String bomPlan = db.queryForObject("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) " + BOM_PRESENCE_SQL, ids, String.class);
            String stockPlan = db.queryForObject("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) " + GoodsStockQuantities.SQL, ids, String.class);
            // 小体量下顺序扫描小目录做哈希连接是合法的代价选择；体量到 10 万起，逐批读必须按本批 id
            // 走索引，否则 331 批 × 全表扫描随目录线性变慢。
            if (history >= 100_000) {
                assertTrue(seqScanned(bomPlan).isEmpty(), "BOM 存在性计划不得顺序扫描大表: " + bomPlan);
                assertTrue(seqScanned(stockPlan).isEmpty(), "库存量计划不得顺序扫描大表: " + stockPlan);
            }
            Map<String, Object> scale = new LinkedHashMap<>();
            scale.put("batchRows", batchRows);
            scale.put("otherGoods", history);
            scale.put("bomRows", jdbc.queryForObject("SELECT count(*) FROM goods_bom_items", Long.class));
            scale.put("stockRows", jdbc.queryForObject("SELECT count(*) FROM stock_balances", Long.class));
            Map<String, Object> bomValues = new LinkedHashMap<>(scale);
            bomValues.put("seqScanned", seqScanned(bomPlan));
            bomValues.put("samples", LoadingGrowthEvidence.samples(() -> db.queryForList(BOM_PRESENCE_SQL, ids, UUID.class)));
            LoadingGrowthEvidence.write("goods-stream-batch-bom", history, bomValues, bomPlan);
            Map<String, Object> stockValues = new LinkedHashMap<>(scale);
            stockValues.put("seqScanned", seqScanned(stockPlan));
            stockValues.put("samples", LoadingGrowthEvidence.samples(() -> stockQuantities(ids)));
            LoadingGrowthEvidence.write("goods-stream-batch-stock", history, stockValues, stockPlan);
        }
    }

    private Map<UUID, BigDecimal> stockQuantities(Map<String, Object> ids) {
        Map<UUID, BigDecimal> stock = new HashMap<>();
        db.query(GoodsStockQuantities.SQL, ids,
                (RowCallbackHandler) row -> stock.put(row.getObject(1, UUID.class), row.getBigDecimal(2)));
        return stock;
    }

    /** Growing tables that one EXPLAIN plan reads by sequential scan. */
    private static List<String> seqScanned(String plan) throws Exception {
        List<String> relations = new ArrayList<>();
        for (JsonNode node : new ObjectMapper().readTree(plan).findParents("Node Type")) {
            String relation = node.path("Relation Name").asText();
            if ("Seq Scan".equals(node.path("Node Type").asText()) && GROWING_TABLES.contains(relation))
                relations.add(relation);
        }
        return relations;
    }

    /** BOM_PRESENCE_SQL 只是 JPQL 的镜像：生产 JPQL 一变，本守卫必须同步改写。 */
    private static void requireBomPresenceJpqlUnchanged() throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/master/goods/GoodsService.java")).replaceAll("\\s+", " ");
        assertTrue(source.contains("select distinct b.goods.id from GoodsBomItem b"
                        + " where b.goods.id in :ids and b.deleted = false"
                        + " and b.goods.autoCreated = false and b.component.autoCreated = false"),
                "GoodsService.list 的 BOM 存在性 JPQL 已变化，须同步改写 BOM_PRESENCE_SQL");
    }
}
