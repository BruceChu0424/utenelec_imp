package com.uten.imp.features.master.lifecycle;

import com.uten.imp.support.MigratedSchemaBaseline;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.UUID;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * 主档引用目录与真库逐列对账(ADR-111 评审 major 回归)。
 *
 * <p>2026-09-22 的事故是「删主档不查引用」；第一轮修复又漏了应收应付、草稿退货、委外发料等
 * 在办业务。根因是「查哪些表」靠人记。这里把迁移后的真实库结构当事实：所有指向七种主档的外键列，
 * 加上按命名约定(…goods_id / …color_id / …warehouse_ids 等)却没有外键的 uuid 列，每一列都必须
 * 在 {@link MasterReferenceCatalog} 里要么登记为引用(带在办口径)、要么登记为豁免(带理由)。
 * 以后谁新加一张引用主档的表而没归类，这个测试直接失败并点名该列。
 *
 * <p>同时把七种主档的整条检查语句在真库上各跑一遍，保证目录里每一段 SQL 都能执行，并记录
 * 空库上的耗时(语句只有一条，与批量条数无关)。
 */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MasterReferenceCatalogCoverageTest {

    private static MigratedSchemaBaseline.ScopedDatabase POSTGRES;

    private static final Map<String, MasterEntityKind> MASTER_TABLES = Map.of(
            "goods", MasterEntityKind.GOODS,
            "colors", MasterEntityKind.COLOR,
            "units", MasterEntityKind.UNIT,
            "warehouses", MasterEntityKind.WAREHOUSE,
            "clients", MasterEntityKind.CLIENT,
            "suppliers", MasterEntityKind.SUPPLIER,
            "moulds", MasterEntityKind.MOULD);

    private static final Map<String, MasterEntityKind> NAMING = Map.of(
            "goods", MasterEntityKind.GOODS,
            "color", MasterEntityKind.COLOR,
            "unit", MasterEntityKind.UNIT,
            "warehouse", MasterEntityKind.WAREHOUSE,
            "client", MasterEntityKind.CLIENT,
            "supplier", MasterEntityKind.SUPPLIER,
            "mould", MasterEntityKind.MOULD);

    private static final Pattern NAMED = Pattern.compile("(?:^|_)(goods|color|unit|warehouse|client|supplier|mould)_ids?$");

    @BeforeAll
    static void migrateRealSchema() throws SQLException {
        POSTGRES = MigratedSchemaBaseline.openDatabase("master_reference_catalog");
    }

    @AfterAll
    static void stopPostgres() throws SQLException {
        if (POSTGRES != null) POSTGRES.close();
    }

    @Test
    void marketReferenceAssociationIsGoodsOwnConfigurationRatherThanAnOpenBusinessReference() {
        assertThat(MasterReferenceCatalog.exemptions().stream()
                .filter(exemption -> exemption.table().equals("goods_market_reference_bindings")).toList())
                .singleElement().satisfies(exemption -> {
                    assertThat(exemption.column()).isEqualTo("goods_id");
                    assertThat(exemption.reason()).isEqualTo(MasterReferenceCatalog.ExemptReason.OWN_CONFIG);
                    assertThat(exemption.note()).contains("CAS墓碑", "不是在办业务引用");
                });
        assertThat(MasterReferenceCatalog.references().stream()
                .filter(reference -> reference.table().equals("goods_market_reference_bindings")).toList())
                .isEmpty();
    }

    @Test
    void everyColumnPointingAtAMasterIsEitherCheckedOrExemptedWithAReason() throws SQLException {
        Map<String, MasterEntityKind> inventory = inventory();
        Map<String, MasterEntityKind> covered = new TreeMap<>();
        for (MasterReferenceCatalog.Reference reference : MasterReferenceCatalog.references()) {
            covered.put(reference.table() + "." + reference.column(), reference.target());
        }
        Set<String> exempt = new TreeSet<>();
        for (MasterReferenceCatalog.Exemption exemption : MasterReferenceCatalog.exemptions()) {
            assertThat(exempt.add(exemption.table() + "." + exemption.column()))
                    .as("豁免重复登记 %s.%s", exemption.table(), exemption.column()).isTrue();
            assertThat(exemption.note()).as("豁免必须写理由").isNotBlank();
        }

        Set<String> unclassified = new TreeSet<>(inventory.keySet());
        unclassified.removeAll(covered.keySet());
        unclassified.removeAll(exempt);
        assertThat(unclassified)
                .as("这些列指向主档，但 MasterReferenceCatalog 既没登记引用口径也没登记豁免理由")
                .isEmpty();

        Set<String> both = new TreeSet<>(covered.keySet());
        both.retainAll(exempt);
        assertThat(both).as("同一列不能既检查又豁免").isEmpty();

        Set<String> stale = new TreeSet<>(covered.keySet());
        stale.addAll(exempt);
        stale.removeAll(inventory.keySet());
        assertThat(stale).as("目录里登记了库里并不存在(或不指向主档)的列").isEmpty();

        List<String> wrongTarget = new ArrayList<>();
        covered.forEach((column, target) -> {
            if (inventory.get(column) != target) {
                wrongTarget.add(column + " 实际指向 " + inventory.get(column) + "，目录写成 " + target);
            }
        });
        assertThat(wrongTarget).as("引用目录的主档种类与外键不一致").isEmpty();
        record("inventory", inventory.size(), "covered", covered.size(), "exempt", exempt.size());
    }

    @Test
    void everyKindsWholeReferenceQueryRunsOnTheMigratedSchema() throws SQLException {
        try (Connection connection = connection()) {
            for (MasterEntityKind kind : MasterEntityKind.values()) {
                String sql = MasterReferenceGuard.sql(kind)
                        .replace(":ids", "?")
                        .replace(":excluded", "?");
                String ids = UUID.randomUUID() + "," + UUID.randomUUID();
                long started = System.nanoTime();
                try (PreparedStatement statement = connection.prepareStatement(sql)) {
                    statement.setString(1, ids);
                    statement.setString(2, "");
                    try (ResultSet rows = statement.executeQuery()) {
                        assertThat(rows.next()).as(kind + " 随机 id 不应命中任何引用").isFalse();
                    }
                }
                double millis = (System.nanoTime() - started) / 1_000_000.0;
                record("kind", kind.name(),
                        "branches", MasterReferenceCatalog.references(kind).size(),
                        "emptySchemaMillis", Math.round(millis * 10) / 10.0);
            }
        }
    }

    /** Root, current BOM and frozen historical component references remain bounded to the supplied targets. */
    @Test
    void costReferencesKeepRootCurrentAndFrozenComponentsWithinTheRequestedBatch() throws SQLException {
        String query = MasterReferenceCatalog.references(MasterEntityKind.GOODS).stream()
                .filter(reference -> reference.kind() == MasterReferenceGuard.RefKind.COST_SHEET)
                .findFirst().orElseThrow().sql();
        UUID root = UUID.randomUUID(), component = UUID.randomUUID(), frozen = UUID.randomUUID();
        UUID unrelated = UUID.randomUUID(), absent = UUID.randomUUID(), sheet = UUID.randomUUID();
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                // This is a query oracle using migrated column shapes, not a cost-document lifecycle fixture.
                try (var statement = connection.createStatement()) {
                    statement.execute("CREATE TEMP TABLE goods_cost_sheets ON COMMIT DROP AS SELECT * FROM public.goods_cost_sheets WITH NO DATA");
                    statement.execute("CREATE TEMP TABLE goods_cost_snapshots ON COMMIT DROP AS SELECT * FROM public.goods_cost_snapshots WITH NO DATA");
                }
                try (var insert = connection.prepareStatement("""
                        INSERT INTO goods_cost_sheets(id,goods_id,calculation)
                        VALUES (?,?,jsonb_build_object('lines',jsonb_build_array(jsonb_build_object('goodsId',CAST(? AS text))))),
                               (?,?,'{}'::jsonb)
                        """)) {
                    insert.setObject(1, sheet); insert.setObject(2, root); insert.setObject(3, component);
                    insert.setObject(4, UUID.randomUUID()); insert.setObject(5, unrelated); insert.executeUpdate();
                }
                try (var insert = connection.prepareStatement("""
                        INSERT INTO goods_cost_snapshots(id,sheet_id,payload)
                        VALUES (?, ?, jsonb_build_object('calculation',jsonb_build_object('lines',
                               jsonb_build_array(jsonb_build_object('goodsId',CAST(? AS text))))))
                        """)) {
                    insert.setObject(1, UUID.randomUUID()); insert.setObject(2, sheet);
                    insert.setObject(3, frozen); insert.executeUpdate();
                }
                try (var statement = connection.prepareStatement(
                        "WITH targets AS (SELECT unnest(CAST(? AS uuid[])) AS id) " + query)) {
                    statement.setArray(1, connection.createArrayOf("uuid", new UUID[]{root, component, frozen, absent}));
                    Set<UUID> found = new TreeSet<>();
                    try (var rows = statement.executeQuery()) {
                        assertThat(rows.getMetaData().getColumnCount()).isEqualTo(6);
                        while (rows.next()) {
                            assertThat(found.add(rows.getObject(1, UUID.class))).isTrue();
                            assertThat(rows.getString(2)).isEqualTo("COST_SHEET");
                            assertThat(rows.getString(3)).isEqualTo(sheet.toString());
                            assertThat(rows.getString(4)).isEqualTo("内部成本记录");
                            assertThat(rows.getObject(5)).isNull();
                            assertThat(rows.getString(6)).isEqualTo("public");
                        }
                    }
                    assertThat(found).containsExactlyInAnyOrder(root, component, frozen);
                }
            } finally {
                connection.rollback();
            }
        }
    }

    @Test
    void pendingCountReferencesBlockOnlyTheirTargetsAndHideRequestDetails() throws SQLException {
        List<MasterReferenceCatalog.Reference> references = MasterReferenceCatalog.references().stream()
                .filter(r -> r.kind() == MasterReferenceGuard.RefKind.STOCK_COUNT_REQUEST).toList();
        assertThat(references).hasSize(4);
        assertThat(MasterReferenceCatalog.exemptions().stream()
                .filter(e -> e.table().equals("workshop_material_count_adjustment_postings")).toList())
                .hasSize(4).allSatisfy(e -> assertThat(e.reason()).isEqualTo(MasterReferenceCatalog.ExemptReason.HISTORY));
        UUID target = UUID.randomUUID(), unrelated = UUID.randomUUID(), absent = UUID.randomUUID();
        UUID pending = UUID.randomUUID();
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                // Query oracle over real migrated column shapes, not a bypass of live lifecycle guards.
                try (var sql = connection.createStatement()) {
                    sql.execute("CREATE TEMP TABLE stock_count_requests ON COMMIT DROP AS SELECT * FROM public.stock_count_requests WITH NO DATA");
                    sql.execute("CREATE TEMP TABLE stock_count_request_lines ON COMMIT DROP AS SELECT * FROM public.stock_count_request_lines WITH NO DATA");
                }
                for (String status : List.of("PENDING", "APPROVED", "REJECTED", "CANCELLED")) {
                    UUID request = status.equals("PENDING") ? pending : UUID.randomUUID();
                    try (var insert = connection.prepareStatement("INSERT INTO stock_count_requests(id,warehouse_id,status,request_no) VALUES(?,?,?,'PRIVATE-REQUEST-NUMBER')")) {
                        insert.setObject(1,request);insert.setObject(2,target);insert.setString(3,status);insert.executeUpdate();
                    }
                    try (var insert = connection.prepareStatement("INSERT INTO stock_count_request_lines(id,request_id,goods_id,color_id,unit_id) VALUES(gen_random_uuid(),?,?,?,?)")) {
                        insert.setObject(1,request);for(int n=2;n<=4;n++){ insert.setObject(n,target); }insert.executeUpdate();
                    }
                }
                try (var insert = connection.prepareStatement("INSERT INTO stock_count_requests(id,warehouse_id,status) VALUES(?,?,'PENDING')")) {
                    insert.setObject(1,unrelated);insert.setObject(2,unrelated);insert.executeUpdate();
                }
                try (var insert = connection.prepareStatement("INSERT INTO stock_count_request_lines(id,request_id,goods_id,color_id,unit_id) VALUES(gen_random_uuid(),?,?,?,?)")) {
                    for(int n=1;n<=4;n++){ insert.setObject(n,unrelated); }insert.executeUpdate();
                }
                for (var reference : references) {
                    try (var query=connection.prepareStatement("WITH targets AS (SELECT unnest(CAST(? AS uuid[])) AS id) "+reference.sql())) {
                        query.setArray(1,connection.createArrayOf("uuid",new UUID[]{target,absent}));
                        try(var rows=query.executeQuery()) {
                            assertThat(rows.next()).as(reference.table()+"."+reference.column()).isTrue();
                            assertThat(rows.getObject(1,UUID.class)).isEqualTo(target);
                            assertThat(rows.getString(2)).isEqualTo("STOCK_COUNT_REQUEST");
                            assertThat(rows.getString(3)).isEqualTo(pending.toString());
                            assertThat(rows.getString(4)).isEqualTo("待审核库存盘点申请").doesNotContain("PRIVATE-REQUEST-NUMBER");
                            assertThat(rows.getObject(5)).isNull();assertThat(rows.getString(6)).isEqualTo("public");
                            assertThat(rows.next()).isFalse();
                        }
                    }
                }
            } finally {connection.rollback();}
        }
    }

    @Test
    void initialUnitReceiptKeepsHistoryWhileCurrentGoodsUnitStillBlocksRetirement() throws SQLException {
        assertThat(MasterReferenceCatalog.exemptions().stream()
                .filter(exemption -> exemption.table().equals("rd_tasks")
                        && exemption.column().equals("initial_unit_id")).toList())
                .singleElement().satisfies(exemption -> assertThat(exemption.reason())
                        .isEqualTo(MasterReferenceCatalog.ExemptReason.HISTORY));
        UUID currentUnit = UUID.randomUUID(), historicalUnit = UUID.randomUUID(), goods = UUID.randomUUID();
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                // Use migrated shapes to distinguish a historical receipt from a live master identity.
                try (var statement = connection.createStatement()) {
                    statement.execute("CREATE TEMP TABLE goods ON COMMIT DROP AS SELECT * FROM public.goods WITH NO DATA");
                    statement.execute("CREATE TEMP TABLE rd_tasks ON COMMIT DROP AS SELECT * FROM public.rd_tasks WITH NO DATA");
                }
                try (var insert = connection.prepareStatement(
                        "INSERT INTO goods(id,code,name,unit_id,is_deleted) VALUES (?,'CURRENT-UNIT','current goods',?,false)")) {
                    insert.setObject(1, goods); insert.setObject(2, currentUnit); insert.executeUpdate();
                }
                try (var insert = connection.prepareStatement(
                        "INSERT INTO rd_tasks(id,goods_id,initial_unit_id,status,is_deleted) VALUES (gen_random_uuid(),?,?,'DONE',false)")) {
                    insert.setObject(1, goods); insert.setObject(2, historicalUnit); insert.executeUpdate();
                }
                try (var query = connection.prepareStatement(MasterReferenceGuard.sql(MasterEntityKind.UNIT)
                        .replace(":ids", "?").replace(":excluded", "?"))) {
                    query.setString(1, currentUnit + "," + historicalUnit); query.setString(2, "");
                    try (var rows = query.executeQuery()) {
                        assertThat(rows.next()).isTrue();
                        assertThat(rows.getObject(1, UUID.class)).isEqualTo(currentUnit);
                        assertThat(rows.getString(2)).isEqualTo("GOODS");
                        assertThat(rows.getString(3)).isEqualTo(goods.toString());
                        assertThat(rows.next()).isFalse();
                    }
                }
            } finally {
                connection.rollback();
            }
        }
    }

    /** 库里所有指向七种主档的列：外键列(分区子表并到父表) + 按命名约定却没外键的 uuid 列。 */
    private static Map<String, MasterEntityKind> inventory() throws SQLException {
        Map<String, MasterEntityKind> out = new TreeMap<>();
        try (Connection connection = connection();
             PreparedStatement statement = connection.prepareStatement("""
                     SELECT DISTINCT t.relname, a.attname, rt.relname
                     FROM pg_constraint c
                     JOIN pg_class t ON t.oid = c.conrelid
                     JOIN pg_namespace n ON n.oid = t.relnamespace AND n.nspname = 'public'
                     JOIN pg_class rt ON rt.oid = c.confrelid
                     JOIN LATERAL unnest(c.conkey) k(attnum) ON TRUE
                     JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
                     WHERE c.contype = 'f' AND NOT t.relispartition
                       AND rt.relname IN ('goods', 'colors', 'units', 'warehouses', 'clients', 'suppliers', 'moulds')
                     """);
             ResultSet rows = statement.executeQuery()) {
            while (rows.next()) {
                out.put(rows.getString(1) + "." + rows.getString(2), MASTER_TABLES.get(rows.getString(3)));
            }
        }
        try (Connection connection = connection();
             PreparedStatement statement = connection.prepareStatement("""
                     SELECT c.relname, a.attname
                     FROM pg_class c
                     JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
                     JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
                     WHERE c.relkind IN ('r', 'p') AND NOT c.relispartition
                       AND format_type(a.atttypid, a.atttypmod) IN ('uuid', 'uuid[]')
                       AND NOT EXISTS (
                           SELECT 1 FROM pg_constraint k
                           WHERE k.conrelid = c.oid AND k.contype IN ('f', 'p') AND a.attnum = ANY(k.conkey))
                     """);
             ResultSet rows = statement.executeQuery()) {
            while (rows.next()) {
                String column = rows.getString(2);
                Matcher matcher = NAMED.matcher(column);
                if (!matcher.find()) continue;
                out.putIfAbsent(rows.getString(1) + "." + column, NAMING.get(matcher.group(1)));
            }
        }
        return out;
    }

    @Test
    void marketAssociationsAreOwnConfigurationAndSoftDeletionRetainsTheirCasTombstones() throws SQLException {
        assertThat(MasterReferenceCatalog.exemptions().stream()
                .filter(exemption -> exemption.table().equals("goods_market_reference_bindings")).toList())
                .singleElement().satisfies(exemption -> {
                    assertThat(exemption.column()).isEqualTo("goods_id");
                    assertThat(exemption.reason()).isEqualTo(MasterReferenceCatalog.ExemptReason.OWN_CONFIG);
                });
        try (Connection connection = connection()) {
            connection.setAutoCommit(false);
            try {
                UUID employee = UUID.randomUUID(), actor = UUID.randomUUID();
                // Flyway seeds the administrator employee only; BootstrapRunner creates its user.
                // This SQL fixture must create its own real audited actor and employee FK.
                try (var insert = connection.prepareStatement("""
                        INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                        SELECT ?,?,'market lifecycle','其他',id,current_date,'active','regular'
                        FROM departments WHERE code='DEPT_FIN'
                        """)) {
                    insert.setObject(1, employee);
                    insert.setString(2, "MARKET-" + employee);
                    assertThat(insert.executeUpdate()).isEqualTo(1);
                }
                try (var insert = connection.prepareStatement("""
                        INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password)
                        VALUES(?,?,?,'test-only','active',false)
                        """)) {
                    insert.setObject(1, actor);
                    insert.setObject(2, employee);
                    insert.setString(3, "market-" + actor);
                    assertThat(insert.executeUpdate()).isEqualTo(1);
                }
                try (var bindActor = connection.prepareStatement("SELECT set_config('app.actor_id',?,true)")) {
                    bindActor.setString(1, actor.toString());
                    bindActor.execute();
                }
                for (String series : new String[]{"copper", null}) {
                    UUID goodsId = UUID.randomUUID();
                    try (var insert = connection.prepareStatement("""
                            INSERT INTO goods(id,code,name,code_sequence)
                            VALUES(?,?,'market configuration lifecycle',
                                   (SELECT coalesce(max(code_sequence),0)+1 FROM goods))
                            """)) {
                        insert.setObject(1, goodsId);
                        insert.setString(2, "MARKET-CONFIG-" + goodsId);
                        insert.executeUpdate();
                    }
                    try (var insert = connection.prepareStatement("""
                            INSERT INTO goods_market_reference_bindings(goods_id,series_id,identity_digest,version,updated_by)
                            VALUES(?,?,?,1,CAST(current_setting('app.actor_id') AS uuid))
                            """)) {
                        insert.setObject(1, goodsId);
                        insert.setString(2, series);
                        insert.setString(3, series == null ? null : "a".repeat(64));
                        insert.executeUpdate();
                    }
                    String before;
                    try (var snapshot = connection.prepareStatement(
                            "SELECT to_jsonb(b)::text FROM goods_market_reference_bindings b WHERE goods_id=?")) {
                        snapshot.setObject(1, goodsId);
                        try (var rows = snapshot.executeQuery()) {
                            assertThat(rows.next()).isTrue();
                            before = rows.getString(1);
                        }
                    }
                    try (var guard = connection.prepareStatement(MasterReferenceGuard.sql(MasterEntityKind.GOODS)
                            .replace(":ids", "?").replace(":excluded", "?"))) {
                        guard.setString(1, goodsId.toString());
                        guard.setString(2, "");
                        try (var rows = guard.executeQuery()) {
                            assertThat(rows.next()).as("master configuration must not become an open business reference").isFalse();
                        }
                    }
                    // The real lifecycle uses soft deletion, never deleting the preserved binding row.
                    try (var delete = connection.prepareStatement("""
                            UPDATE goods SET is_deleted=true,deleted_at=now(),updated_at=now(),version=version+1,
                              updated_by=CAST(current_setting('app.actor_id') AS uuid) WHERE id=?
                            """)) {
                        delete.setObject(1, goodsId);
                        assertThat(delete.executeUpdate()).isEqualTo(1);
                    }
                    try (var snapshot = connection.prepareStatement("""
                            SELECT to_jsonb(b)::text,g.is_deleted
                            FROM goods_market_reference_bindings b JOIN goods g ON g.id=b.goods_id
                            WHERE b.goods_id=?
                            """)) {
                        snapshot.setObject(1, goodsId);
                        try (var rows = snapshot.executeQuery()) {
                            assertThat(rows.next()).isTrue();
                            assertThat(rows.getString(1)).as("binding identity, revision and audit facts remain exact").isEqualTo(before);
                            assertThat(rows.getBoolean(2)).isTrue();
                        }
                    }
                }
            } finally {
                connection.rollback();
            }
        }
    }

    private static Connection connection() throws SQLException {
        return DriverManager.getConnection(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword());
    }

    private static void record(Object... pairs) {
        Map<String, Object> line = new LinkedHashMap<>();
        for (int i = 0; i + 1 < pairs.length; i += 2) line.put(String.valueOf(pairs[i]), pairs[i + 1]);
        try {
            java.nio.file.Path output = java.nio.file.Path.of(
                    System.getProperty("uten.build.directory", "target"), "master-reference-catalog.jsonl");
            java.nio.file.Files.createDirectories(output.toAbsolutePath().getParent());
            java.nio.file.Files.writeString(output, new com.fasterxml.jackson.databind.ObjectMapper()
                            .writeValueAsString(line) + System.lineSeparator(),
                    java.nio.file.StandardOpenOption.CREATE, java.nio.file.StandardOpenOption.APPEND);
        } catch (java.io.IOException error) {
            throw new AssertionError(error);
        }
    }
}
