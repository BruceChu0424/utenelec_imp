package com.uten.imp.features.master.goods;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.goods.importing.GoodsBomImportService;
import com.uten.imp.support.MigratedProjectionSchema;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.sql.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.regex.Pattern;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Production fingerprint SQL and parent-lock race against real migrated PostgreSQL column shapes. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class GoodsBomImportStatePostgresTest {
    static final PostgreSQLContainer<?> DATABASE = new PostgreSQLContainer<>("postgres:16-alpine");
    Connection db;
    String schema;
    UUID root, child, material, unit, red;

    @BeforeAll static void migrate() {
        DATABASE.start();
        Flyway.configure().dataSource(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword())
                .locations("classpath:db/migration").load().migrate();
    }
    @AfterAll static void stop() { DATABASE.stop(); }
    @AfterEach void close() throws Exception { db.close(); }
    @BeforeEach void fixture() throws Exception {
        db = connect();
        schema = "bom_import_" + UUID.randomUUID().toString().replace("-", "");
        sql(db, "CREATE SCHEMA " + schema);
        sql(db, "SET search_path TO " + schema + ",public");
        MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(db, "goods", "goods_bom_items", "units",
                "colors", "suppliers", "goods_bom_actual_usages");
        unit = UUID.randomUUID(); red = UUID.randomUUID();
        sql(db, "INSERT INTO units(id,name) VALUES(?,'千克')", unit);
        sql(db, "INSERT INTO colors(id,name,is_deleted) VALUES(?,'红色',false)", red);
        root = goods("P1"); child = goods("C1"); material = goods("M1");
        edge(root, child); edge(child, material);
    }

    @Test void includesNestedRulesVersionsColorUnitAndActualLearningFacts() throws Exception {
        GoodsBomPasteService service = snapshotService(db);
        String previous = snapshot(service, Set.of());
        for (String change : List.of(
                "UPDATE goods_bom_items SET qty=2 WHERE goods_id='" + child + "'",
                "UPDATE goods SET version=version+1 WHERE id='" + root + "'",
                "UPDATE colors SET name='深红色' WHERE id='" + red + "'",
                "UPDATE units SET name='克' WHERE id='" + unit + "'",
                "INSERT INTO goods_bom_actual_usages(goods_id,component_goods_id,unit_id,net_qty) VALUES('"
                        + child + "','" + material + "','" + unit + "',12)")) {
            sql(db, change);
            String current = snapshot(service, Set.of());
            assertNotEquals(previous, current, change);
            previous = current;
        }
    }

    @Test void newlyRequestedColorIdentityIsBoundEvenBeforeItIsUsedByAnyEdge() throws Exception {
        UUID oldBlue = UUID.randomUUID();
        sql(db, "INSERT INTO colors(id,name,is_deleted) VALUES(?,'蓝色',false)", oldBlue);
        GoodsBomPasteService service = snapshotService(db);
        String previous = snapshot(service, Set.of("蓝色"));

        sql(db, "UPDATE colors SET name='旧蓝色',status='禁用' WHERE id=?", oldBlue);
        sql(db, "INSERT INTO colors(id,name,is_deleted) VALUES(?,'蓝色',false)", UUID.randomUUID());

        assertNotEquals(previous, snapshot(service, Set.of("蓝色")));
    }

    @Test void fingerprintProjectionDoesNotMaterializeLegacyProductImages() throws Exception {
        GoodsBomPasteService service = snapshotService(db);
        String before = snapshot(service, Set.of());
        sql(db, "UPDATE goods SET product_graph1=? WHERE id=?", new byte[2 * 1024 * 1024], child);
        assertEquals(before, snapshot(service, Set.of()));
        assertTrue(before.length() < 50_000);
        sql(db, "UPDATE goods SET version=version+1 WHERE id=?", child);
        assertNotEquals(before, snapshot(service, Set.of()));
    }

    @Test void waitingImportSeesCommittedNestedParentChangeAndRejectsWithoutWriting() throws Exception {
        byte[] file = new XlsxExportService().build(List.of(
                new ExportColumn("seq", "序号", ExportColumn.TEXT),
                new ExportColumn("code", "物料编号", ExportColumn.TEXT),
                new ExportColumn("qty", "数量", ExportColumn.QTY)),
                List.of(Map.of("seq", "1", "code", "C1", "qty", 1),
                        Map.of("seq", "1.1", "code", "M1", "qty", 1)));
        CountDownLatch waiting = new CountDownLatch(1);
        try (ExecutorService worker = Executors.newSingleThreadExecutor();
             Connection writer = scoped(); Connection importing = scoped()) {
            GoodsBomPasteService paste = mock(GoodsBomPasteService.class);
            GoodsBomPasteService snapshots = snapshotService(importing);
            when(paste.importStateSnapshot(anySet(), anySet(), anySet())).thenAnswer(call -> snapshots.importStateSnapshot(
                    call.getArgument(0), call.getArgument(1), call.getArgument(2)));
            GoodsRepository repo = mock(GoodsRepository.class);
            Goods rootGoods = model(root, "P1"), childGoods = model(child, "C1"), materialGoods = model(material, "M1");
            when(repo.findById(root)).thenReturn(Optional.of(rootGoods));
            when(repo.findByCodeAndDeletedFalse("C1")).thenReturn(Optional.of(childGoods));
            when(repo.findByCodeAndDeletedFalse("M1")).thenReturn(Optional.of(materialGoods));
            doAnswer(call -> {
                waiting.countDown();
                try (var statement = importing.prepareStatement("SELECT id FROM goods WHERE id IN (?,?) ORDER BY id FOR NO KEY UPDATE")) {
                    statement.setObject(1, root); statement.setObject(2, child); statement.executeQuery().close();
                }
                return null;
            }).when(repo).lockBomParents(anyCollection());
            GoodsBomImportService importer = new GoodsBomImportService(repo, paste);
            String token = importer.detect(root, file).stateFingerprint();
            writer.setAutoCommit(false);
            sql(writer, "SELECT id FROM goods WHERE id=? FOR NO KEY UPDATE", child);
            importing.setAutoCommit(false);
            Future<ApiException> result = worker.submit(() -> {
                try { return assertThrows(ApiException.class,
                        () -> importer.commit(root, file, BomPasteRequest.Mode.APPEND, token)); }
                finally { importing.rollback(); }
            });
            assertTrue(waiting.await(5, TimeUnit.SECONDS));
            assertThrows(TimeoutException.class, () -> result.get(150, TimeUnit.MILLISECONDS));
            sql(writer, "UPDATE goods_bom_items SET qty=7 WHERE goods_id=?", child);
            writer.commit();

            assertEquals(ErrorCode.CONFLICT, result.get(10, TimeUnit.SECONDS).getCode());
            verify(paste, never()).pasteImported(any(), anySet(), anyMap());
            verify(paste, never()).markImportApplied(anySet());
        }
    }

    private String snapshot(GoodsBomPasteService service, Set<String> colors) {
        return service.importStateSnapshot(Set.of(root, child), Set.of(root, child, material), colors);
    }

    private GoodsBomPasteService snapshotService(Connection connection) {
        EntityManager em = mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> query(connection, call.getArgument(0)));
        return new GoodsBomPasteService(null, null, null, null, null, null, em);
    }

    /** Bind named scalar/collection parameters without changing the production query. */
    private Query query(Connection connection, String sql) {
        Query query = mock(Query.class);
        Map<String, Object> parameters = new HashMap<>();
        when(query.setParameter(anyString(), any())).thenAnswer(call -> {
            parameters.put(call.getArgument(0), call.getArgument(1)); return query;
        });
        when(query.getSingleResult()).thenAnswer(call -> {
            var named = Pattern.compile("(?<!:):([A-Za-z]\\w*)").matcher(sql);
            StringBuilder jdbc = new StringBuilder(); List<Object> args = new ArrayList<>();
            while (named.find()) {
                Object parameter = parameters.get(named.group(1));
                List<?> values = parameter instanceof Collection<?> collection ? List.copyOf(collection) : List.of(parameter);
                args.addAll(values);
                named.appendReplacement(jdbc, String.join(",", Collections.nCopies(values.size(), "?")));
            }
            named.appendTail(jdbc);
            try (var statement = connection.prepareStatement(jdbc.toString())) {
                for (int i = 0; i < args.size(); i++) statement.setObject(i + 1, args.get(i));
                try (var rows = statement.executeQuery()) { assertTrue(rows.next()); return rows.getString(1); }
            }
        });
        return query;
    }
    private UUID goods(String code) throws Exception {
        UUID id = UUID.randomUUID();
        sql(db, "INSERT INTO goods(id,code,name,unit_id,color_id,version,is_deleted,auto_created) VALUES(?,?,?,?,?,0,false,false)",
                id, code, code, unit, red); return id;
    }
    private void edge(UUID parent, UUID component) throws Exception {
        sql(db, "INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty,is_deleted) VALUES(?,?,?,1,false)",
                UUID.randomUUID(), parent, component);
    }
    private static Goods model(UUID id, String code) { Goods goods = new Goods(); goods.setId(id); goods.setCode(code); return goods; }
    private Connection scoped() throws Exception { Connection connection = connect(); sql(connection, "SET search_path TO " + schema + ",public"); return connection; }
    private static Connection connect() throws SQLException { return DriverManager.getConnection(DATABASE.getJdbcUrl(), DATABASE.getUsername(), DATABASE.getPassword()); }
    private static void sql(Connection connection, String sql, Object... args) throws SQLException {
        try (var statement = connection.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) statement.setObject(i + 1, args[i]); statement.execute();
        }
    }
}
