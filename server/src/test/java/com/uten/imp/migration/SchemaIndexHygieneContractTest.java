package com.uten.imp.migration;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 索引卫生契约(ADR-106 / V676)：在真实 Flyway 迁移到头的库上验证三条规则。
 *
 * <ol>
 *   <li><b>没有冗余索引</b>：同表、同访问方法、同部分谓词、同表达式，键列(连同算子类、排序规则、排序选项)
 *       是另一索引的前缀、INCLUDE 列也已被对方携带的普通索引一律算冗余；支撑约束的索引不算，唯一索引只在
 *       对方是同列唯一索引、且对方的空值规则不比它宽(NULLS NOT DISTINCT 只能被 NULLS NOT DISTINCT 覆盖)时
 *       才算。与 V676 删索引用的是同一条 SQL。</li>
 *   <li><b>热点关联列有领头索引</b>：指向估值图(stock_value_*)、物料需求、库存预留、计划明细、总账凭证的
 *       外键，都要有以外键列开头的索引(部分索引也算：这些反查都带着同样的过滤条件)。</li>
 *   <li><b>货品数量来源列有可用的领头索引</b>：V675 改单位时按需 EXISTS，未使用的货品要查遍全部来源，
 *       不能退化成全表扫描。探针是「列 = 货品」，所以不带条件的索引和只带「该列 IS NOT NULL」条件的
 *       部分索引都算(等值探针必然满足这个条件)，其它条件的部分索引不算。</li>
 * </ol>
 *
 * <p>另外钉住 V675 按需检查单位引用的两条并发前提(来源列都有不可延迟外键、带行条件的来源只追加)，并在一笔回滚
 * 事务里用样本表自检规则 1、3 的判定本身。
 *
 * <p>白名单只收「有意保留」且写明原因的条目；新迁移再加出冗余索引或热点外键漏建索引会当场红。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class SchemaIndexHygieneContractTest {

    /** 与 V676 同一条前缀覆盖 SQL。 */
    static final String REDUNDANT_INDEXES = """
            WITH idx AS (
                SELECT i.indexrelid, i.indrelid, i.indisunique,
                       i.indnullsnotdistinct AS nnd,
                       i.indnkeyatts AS nkey,
                       i.indnatts AS natts,
                       i.indkey::int2[] AS keys,
                       i.indclass::oid[] AS classes,
                       i.indcollation::oid[] AS collations,
                       i.indoption::int2[] AS options,
                       pg_get_expr(i.indpred, i.indrelid) AS pred,
                       pg_get_expr(i.indexprs, i.indrelid) AS exprs,
                       c.relam AS am,
                       EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid) AS backs_constraint
                FROM pg_index i
                JOIN pg_class c ON c.oid = i.indexrelid
                JOIN pg_class t ON t.oid = i.indrelid
                JOIN pg_namespace n ON n.oid = t.relnamespace
                WHERE n.nspname = 'public' AND i.indisvalid AND i.indislive
            )
            SELECT DISTINCT ON (a.indexrelid)
                   a.indexrelid::regclass::text AS redundant_index,
                   b.indexrelid::regclass::text AS covered_by
            FROM idx a
            JOIN idx b ON b.indrelid = a.indrelid AND b.indexrelid <> a.indexrelid
            WHERE NOT a.backs_constraint
              AND a.am = b.am
              AND a.pred IS NOT DISTINCT FROM b.pred
              AND a.exprs IS NOT DISTINCT FROM b.exprs
              AND a.nkey <= b.nkey
              AND a.keys[0:a.nkey - 1] = b.keys[0:a.nkey - 1]
              AND a.classes[0:a.nkey - 1] = b.classes[0:a.nkey - 1]
              AND a.collations[0:a.nkey - 1] = b.collations[0:a.nkey - 1]
              AND a.options[0:a.nkey - 1] = b.options[0:a.nkey - 1]
              AND (NOT a.indisunique OR (b.indisunique AND a.nkey = b.nkey AND (b.nnd OR NOT a.nnd)))
              AND (a.keys[a.nkey:a.natts - 1]) <@ (b.keys[0:b.natts - 1])
              AND NOT (a.nkey = b.nkey AND a.natts = b.natts AND a.indisunique = b.indisunique
                       AND a.nnd = b.nnd AND NOT b.backs_constraint AND a.indexrelid < b.indexrelid)
            ORDER BY a.indexrelid, b.backs_constraint DESC, b.nkey, b.indexrelid
            """;

    /** 有意保留的冗余索引：索引名 → 原因。 */
    private static final Map<String, String> KEPT_REDUNDANT = Map.of(
            "audit_log_archive_created_at_idx",
            "审计归档表的索引由审计整改工作流统一处理(分区/精简)，本轮不动",
            "idx_procurement_iqc_stock_in_item_batch",
            "ops/reset_business_data.sql 的 V448 读路径索引自检要求五个索引都在；删它要同步改重置脚本");

    /** 热点父表：估值图、需求、预留、计划明细、总账凭证。 */
    private static final String HOT_FOREIGN_KEYS_WITHOUT_LEADING_INDEX = """
            SELECT c.conrelid::regclass::text || '.' || a.attname AS reference
            FROM pg_constraint c
            JOIN pg_namespace n ON n.oid = c.connamespace AND n.nspname = 'public'
            JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
            WHERE c.contype = 'f'
              AND (c.confrelid::regclass::text LIKE 'stock\\_value\\_%'
                   OR c.confrelid::regclass::text IN ('production_material_demands', 'stock_reservations',
                                                      'production_plan_items', 'gl_vouchers'))
              AND NOT EXISTS (
                  SELECT 1 FROM pg_index i
                  WHERE i.indrelid = c.conrelid
                    AND (i.indkey::int2[])[0] = c.conkey[1])
            ORDER BY 1
            """;

    /** 有意不建领头索引的热点外键：引用列 → 原因。 */
    private static final Map<String, String> UNINDEXED_HOT_REFERENCES = Map.ofEntries(
            Map.entry("stock_value_nodes.return_head_id",
                    "估值节点游标：每次移动都改写，建索引会让这些更新失去 HOT；回查走 root_issue_id/主键"),
            Map.entry("stock_value_nodes.consumption_return_head_id",
                    "估值节点退料游标：同上，随每次退料改写"),
            Map.entry("stock_value_nodes.root_issue_id",
                    "查询形如 root_issue_id = id(自指)，领头索引用不上"),
            Map.entry("stock_value_nodes.adjustment_head_id",
                    "调整游标随每次调价改写，只按主键反查"),
            Map.entry("stock_value_events.previous_adjustment_id",
                    "不可变事件链的前驱指针，没有任何查询按它回查"),
            Map.entry("stock_value_production_cost_tasks.input_return_cursor_id",
                    "没有任何查询按它回查"),
            Map.entry("stock_value_production_cost_tasks.previous_task_id",
                    "成本任务链前驱，只在同一产出下顺序读取"),
            Map.entry("stock_value_production_cost_tasks.exact_basis_task_id",
                    "精确基准任务指针，只按主键读取"),
            Map.entry("subcontract_loss_case_lines.excess_value_node_id",
                    "损耗案例行只按案例读取"),
            Map.entry("subcontract_loss_case_lines.normal_value_node_id",
                    "损耗案例行只按案例读取"),
            Map.entry("stock_value_legacy_balance_cases.resolution_event_id",
                    "旧库开账差异案例，只按案例读取"),
            Map.entry("preplan_make_entitlement_delegations.stock_reservation_id",
                    "MAKE 委托已退役(PreplanStockEntitlementService 不再写入)，整表待删除"));

    /**
     * 等值探针「列 = 货品」用得上的领头索引(别名 i 为 pg_index、a 为领头列)：不带表达式，且不带条件或条件
     * 恰好是「该列 IS NOT NULL」(等值探针必然满足它)。
     */
    static final String PROBE_INDEX_ON_LEADING_COLUMN = """
            i.indexprs IS NULL
            AND (i.indpred IS NULL
                 OR pg_get_expr(i.indpred, i.indrelid) = '(' || quote_ident(a.attname::text) || ' IS NOT NULL)')
            """;

    private static final String GOODS_QUANTITY_SOURCES_WITHOUT_PROBE_INDEX = """
            WITH src AS (
                SELECT relation_name, unnest(goods_columns) AS column_name
                FROM fn_goods_quantity_reference_sources())
            SELECT s.relation_name || '.' || s.column_name
            FROM src s
            WHERE NOT EXISTS (
                SELECT 1 FROM pg_index i
                JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
                WHERE i.indrelid = s.relation_name::regclass
                  AND a.attname = s.column_name
                  AND %s)
            ORDER BY 1
            """.formatted(PROBE_INDEX_ON_LEADING_COLUMN);

    private static PostgreSQLContainer<?> database;

    @BeforeAll
    static void migrate() {
        database = MigratedSchemaBaseline.startMigratedContainer("index_hygiene");
    }

    @AfterAll
    static void stop() {
        if (database != null) database.stop();
    }

    @Test
    void noIndexIsCoveredByAnotherIndexOrItsUniqueConstraint() throws SQLException {
        List<String> redundant = new ArrayList<>();
        try (Connection connection = connection(); Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(REDUNDANT_INDEXES)) {
            while (result.next()) {
                String index = result.getString(1);
                if (!KEPT_REDUNDANT.containsKey(index)) {
                    redundant.add(index + " (被 " + result.getString(2) + " 覆盖)");
                }
            }
        }
        assertThat(redundant)
                .as("冗余索引只增加写入开销：删掉它，或在白名单写明为什么必须保留")
                .isEmpty();
    }

    @Test
    void hotForeignKeysHaveALeadingIndex() throws SQLException {
        List<String> missing = new ArrayList<>(strings(HOT_FOREIGN_KEYS_WITHOUT_LEADING_INDEX));
        missing.removeAll(UNINDEXED_HOT_REFERENCES.keySet());
        assertThat(missing)
                .as("估值图/需求/预留/计划明细/总账凭证的引用列要有领头索引，守恒触发器与服务查询按它们回查子表")
                .isEmpty();
        List<String> stale = new ArrayList<>(UNINDEXED_HOT_REFERENCES.keySet());
        stale.removeAll(strings(HOT_FOREIGN_KEYS_WITHOUT_LEADING_INDEX));
        assertThat(stale).as("已经建了索引或外键已删除的条目要从白名单删掉").isEmpty();
    }

    @Test
    void everyGoodsQuantitySourceColumnHasAProbeableLeadingIndex() throws SQLException {
        assertThat(strings(GOODS_QUANTITY_SOURCES_WITHOUT_PROBE_INDEX))
                .as("改单位时按需检查数量引用(V675)：每个来源货品列都要有等值探针用得上的领头索引"
                        + "(不带条件，或只带「该列 IS NOT NULL」)")
                .isEmpty();
    }

    /**
     * 规则本身的自检(在一笔回滚事务里建临时样本表)：
     * 先建普通唯一索引、再建同列 NULLS NOT DISTINCT 唯一索引——只有普通的那条算冗余，更严格的那条不能因为
     * 「完全相同留旧删新」被误判；等值探针规则只认「该列 IS NOT NULL」的部分索引。
     */
    @Test
    void ruleDefinitionsRespectNullsNotDistinctAndNotNullPartialIndexes() throws SQLException {
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try (Statement statement = connection.createStatement()) {
                statement.execute("CREATE TABLE index_rule_probe(goods_id uuid, other_id uuid, code text, is_deleted boolean)");
                statement.execute("CREATE UNIQUE INDEX index_rule_probe_code_plain ON index_rule_probe (code)");
                statement.execute("CREATE UNIQUE INDEX index_rule_probe_code_nnd ON index_rule_probe (code) NULLS NOT DISTINCT");
                statement.execute("CREATE INDEX index_rule_probe_goods ON index_rule_probe (goods_id) WHERE goods_id IS NOT NULL");
                statement.execute("CREATE INDEX index_rule_probe_other ON index_rule_probe (other_id) WHERE NOT is_deleted");
                List<String> redundant = new ArrayList<>();
                try (ResultSet result = statement.executeQuery(REDUNDANT_INDEXES)) {
                    while (result.next()) {
                        if (result.getString(1).startsWith("index_rule_probe")) {
                            redundant.add(result.getString(1) + "<" + result.getString(2));
                        }
                    }
                }
                assertThat(redundant).containsExactly("index_rule_probe_code_plain<index_rule_probe_code_nnd");
                List<String> probeable = new ArrayList<>();
                try (ResultSet result = statement.executeQuery("""
                        SELECT a.attname
                        FROM pg_index i JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = i.indkey[0]
                        WHERE i.indrelid = 'index_rule_probe'::regclass AND NOT i.indisunique AND %s
                        """.formatted(PROBE_INDEX_ON_LEADING_COLUMN))) {
                    while (result.next()) probeable.add(result.getString(1));
                }
                assertThat(probeable).containsExactly("goods_id");
            } finally {
                connection.rollback();
            }
        }
    }

    /**
     * V675 的并发前提：改单位守卫对货品行取 FOR UPDATE，靠的是「一行变成数量引用」必经外键检查(对货品行取
     * FOR KEY SHARE)。所以每个来源货品列都要有指向货品的不可延迟外键；带行条件的来源只能是只追加表
     * (已有行不能被 UPDATE 成「已使用」)。新加来源不满足时先在这里红。
     */
    @Test
    void everyGoodsQuantitySourceBecomesAReferenceOnlyThroughAForeignKeyCheck() throws SQLException {
        assertThat(strings("""
                WITH src AS (
                    SELECT relation_name, unnest(goods_columns) AS column_name
                    FROM fn_goods_quantity_reference_sources())
                SELECT s.relation_name || '.' || s.column_name
                FROM src s
                WHERE NOT EXISTS (
                    SELECT 1 FROM pg_constraint k
                    JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1]
                    WHERE k.contype = 'f' AND k.conrelid = s.relation_name::regclass
                      AND k.confrelid = 'goods'::regclass AND cardinality(k.conkey) = 1
                      AND a.attname = s.column_name AND NOT k.condeferrable)
                ORDER BY 1
                """)).as("数量来源货品列要有指向货品的不可延迟外键").isEmpty();
        assertThat(strings("""
                SELECT relation_name FROM fn_goods_quantity_reference_sources()
                WHERE row_predicate <> 'true' ORDER BY 1
                """)).as("带行条件的来源只有旧库计量画像快照").containsExactly("legacy_measurement_profile_snapshots");
        assertThat(strings("""
                SELECT t.tgname FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                WHERE t.tgrelid = 'legacy_measurement_profile_snapshots'::regclass AND NOT t.tgisinternal
                  AND t.tgenabled = 'A' AND (t.tgtype & 2) <> 0 AND (t.tgtype & 16) <> 0 AND (t.tgtype & 8) <> 0
                  AND p.proname = 'fn_reject_measurement_append_only_mutation'
                """)).as("快照表只追加：UPDATE/DELETE 一律拒绝(复制角色下也拒)，已有行不能被改成「已使用」").hasSize(1);
    }

    @Test
    void theGoodsUnitLockLeftNoStatementTriggersBehind() throws SQLException {
        assertThat(strings("""
                SELECT t.tgrelid::regclass::text FROM pg_trigger t
                WHERE NOT t.tgisinternal AND t.tgname LIKE 'trg\\_lock\\_goods\\_quantity\\_unit%'
                """)).isEmpty();
        assertThat(strings("""
                SELECT column_name FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'goods' AND column_name = 'quantity_unit_locked'
                """)).isEmpty();
    }

    private static List<String> strings(String sql) throws SQLException {
        List<String> values = new ArrayList<>();
        try (Connection connection = connection(); Statement statement = connection.createStatement();
             ResultSet result = statement.executeQuery(sql)) {
            while (result.next()) values.add(result.getString(1));
        }
        return values;
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(database.getJdbcUrl(), database.getUsername(), database.getPassword());
    }
}
