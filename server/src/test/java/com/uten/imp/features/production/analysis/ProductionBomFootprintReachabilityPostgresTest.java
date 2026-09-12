package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.concurrency.FulfillmentMutationLocks;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.test.util.ReflectionTestUtils;
import org.testcontainers.containers.PostgreSQLContainer;

import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicReference;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

/** Real PostgreSQL set equivalence for lock reachability, never a BOM quantity allocator. */
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class ProductionBomFootprintReachabilityPostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16-alpine");
    private static Connection connection;
    private static final ObjectMapper JSON = new ObjectMapper();

    // Keep the pre-optimization traversal as an independent regression reference.
    private static final String EDGE_FRONTIER = """
            WITH RECURSIVE roots AS (
                SELECT id AS goods_id FROM goods WHERE id IN (:rootIds)
            ), expansion AS (
                SELECT bom.id,bom.component_goods_id,COALESCE(bom.color_id,goods.color_id) AS color_id,
                       1 AS depth,md5(bom::text) AS snapshot
                FROM roots JOIN LATERAL (
                    SELECT edge.* FROM goods_bom_items edge
                    WHERE edge.goods_id=roots.goods_id AND edge.is_deleted=FALSE OFFSET 0
                ) bom ON TRUE
                JOIN goods ON goods.id=bom.component_goods_id AND goods.is_deleted=FALSE
                UNION
                SELECT bom.id,bom.component_goods_id,COALESCE(bom.color_id,goods.color_id),
                       parent.depth+1,md5(bom::text)
                FROM expansion parent JOIN LATERAL (
                    SELECT edge.* FROM goods_bom_items edge
                    WHERE edge.goods_id=parent.component_goods_id AND edge.is_deleted=FALSE OFFSET 0
                ) bom ON TRUE
                JOIN goods ON goods.id=bom.component_goods_id AND goods.is_deleted=FALSE
                WHERE parent.depth<10
            )
            SELECT DISTINCT id,component_goods_id,color_id,snapshot
            FROM expansion ORDER BY id,component_goods_id,color_id
            """;

    static final String GOODS_FRONTIER = """
            WITH RECURSIVE roots AS (
                SELECT id AS goods_id FROM goods WHERE id IN (:rootIds)
            ), reachable(goods_id,depth) AS (
                SELECT goods_id,0 FROM roots
                UNION
                SELECT bom.component_goods_id,parent.depth+1
                FROM reachable parent JOIN LATERAL (
                    SELECT edge.component_goods_id FROM goods_bom_items edge
                    WHERE edge.goods_id=parent.goods_id AND edge.is_deleted=FALSE OFFSET 0
                ) bom ON TRUE
                JOIN goods ON goods.id=bom.component_goods_id AND goods.is_deleted=FALSE
                WHERE parent.depth<10
            ), parents AS (
                SELECT DISTINCT goods_id FROM reachable WHERE depth<10
            )
            SELECT DISTINCT bom.id,bom.component_goods_id,
                   COALESCE(bom.color_id,goods.color_id) AS color_id,md5(bom::text) AS snapshot
            FROM parents JOIN LATERAL (
                SELECT edge.* FROM goods_bom_items edge
                WHERE edge.goods_id=parents.goods_id AND edge.is_deleted=FALSE OFFSET 0
            ) bom ON TRUE
            JOIN goods ON goods.id=bom.component_goods_id AND goods.is_deleted=FALSE
            ORDER BY id,component_goods_id,color_id
            """;

    @BeforeAll static void openDatabase() throws Exception {
        POSTGRES.start();
        connection = DriverManager.getConnection(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());
        try (var sql = connection.createStatement()) {
            sql.execute("""
                    CREATE TABLE goods(id uuid PRIMARY KEY,color_id uuid,is_deleted boolean NOT NULL DEFAULT FALSE);
                    CREATE TABLE goods_bom_items(
                        id uuid PRIMARY KEY,goods_id uuid NOT NULL REFERENCES goods(id),
                        component_goods_id uuid NOT NULL REFERENCES goods(id),color_id uuid,
                        qty numeric(18,4) NOT NULL DEFAULT 1,summary text,
                        updated_at timestamptz NOT NULL DEFAULT now(),is_deleted boolean NOT NULL DEFAULT FALSE);
                    CREATE UNIQUE INDEX uq_goods_bom_component ON goods_bom_items(goods_id,component_goods_id)
                        WHERE NOT is_deleted;
                    CREATE INDEX idx_goods_bom_goods ON goods_bom_items(goods_id);
                    """);
        }
        connection.setAutoCommit(false);
    }
    @BeforeEach void clearFixture() throws Exception {
        try (var sql = connection.createStatement()) { sql.execute("TRUNCATE goods_bom_items,goods"); }
    }
    @AfterEach void rollbackFixture() throws Exception { connection.rollback(); }
    @AfterAll static void closeDatabase() throws Exception {
        if (connection != null) connection.close();
        POSTGRES.stop();
    }

    @Test void completeRowsMatchAcrossFanInCyclesDeletionAndColorFallback() throws Exception {
        UUID red=UUID.randomUUID(),blue=UUID.randomUUID();
        UUID root=goods(null,false),left=goods(red,false),right=goods(blue,false);
        UUID shared=goods(red,false),leaf=goods(blue,false),deleted=goods(blue,true);
        UUID hidden=goods(null,false),deletedRoot=goods(null,true);
        UUID first=edge(root,left,null,false),second=edge(root,right,red,false);
        edge(left,shared,null,false); edge(right,shared,blue,false);
        UUID tail=edge(shared,leaf,null,false);
        edge(leaf,left,null,false); // A bounded historical cycle, with all UUID/FK/unique constraints intact.
        UUID deletedChild=edge(root,deleted,null,false);
        UUID hiddenEdge=edge(root,hidden,null,true);
        UUID fromDeletedRoot=edge(deletedRoot,hidden,blue,false);
        var rows=assertEquivalent(List.of(root));
        assertEquals(red,rows.stream().filter(row->row.id().equals(first)).findFirst().orElseThrow().color());
        assertEquals(red,rows.stream().filter(row->row.id().equals(second)).findFirst().orElseThrow().color());
        assertEquals(1,rows.stream().filter(row->row.id().equals(tail)).count());
        assertFalse(rows.stream().anyMatch(row->row.id().equals(deletedChild)||row.id().equals(hiddenEdge)));
        assertTrue(assertEquivalent(List.of(deletedRoot)).stream().anyMatch(row->row.id().equals(fromDeletedRoot)),
                "The original root lookup tests existence, not the root deletion flag");
        assertEquivalent(List.of(root,shared)); // One root is another root's reachable intermediate.
        assertTrue(assertEquivalent(List.of(UUID.randomUUID())).isEmpty());
    }

    @Test void exactlyTenEdgesAndShorterAlternatePathsKeepTheSameBoundary() throws Exception {
        List<UUID> nodes=new ArrayList<>(),edges=new ArrayList<>();
        for(int index=0;index<12;index++) nodes.add(goods(null,false));
        for(int index=0;index<11;index++) edges.add(edge(nodes.get(index),nodes.get(index+1),null,false));
        var first=assertEquivalent(List.of(nodes.getFirst()));
        assertEquals(10,first.size());
        assertTrue(first.stream().anyMatch(row->row.id().equals(edges.get(9))));
        assertFalse(first.stream().anyMatch(row->row.id().equals(edges.get(10))));
        edge(nodes.getFirst(),nodes.get(8),null,false);
        var shorter=assertEquivalent(List.of(nodes.getFirst()));
        assertTrue(shorter.stream().anyMatch(row->row.id().equals(edges.get(10))),
                "The same parent reached through a shorter path may still expand");
        assertEquivalent(List.of(nodes.getFirst(),nodes.get(9)));
    }

    @Test void denseSharedDagReducesActualFrontierScansWithoutDroppingAnyEdge() throws Exception {
        List<UUID> roots=new ArrayList<>();
        for(int index=0;index<80;index++) roots.add(goods(null,false));
        List<UUID> parents=roots;
        for(int depth=0;depth<5;depth++) {
            List<UUID> children=new ArrayList<>();
            for(int index=0;index<6;index++) children.add(goods(index%2==0?UUID.randomUUID():null,false));
            for(UUID parent:parents) for(UUID child:children) edge(parent,child,null,false);
            parents=children;
        }
        // Unrelated history remains present; the query must still start from the selected roots.
        for(int index=0;index<500;index++) edge(goods(null,false),goods(null,false),null,false);
        try(var sql=connection.createStatement()) { sql.execute("ANALYZE goods; ANALYZE goods_bom_items"); }
        List<Row> expected=assertEquivalent(roots);
        JsonNode original=explain(EDGE_FRONTIER,roots),candidate=explain(GOODS_FRONTIER,roots);
        long oldLoops=bomScanLoops(original.path("Plan")),newLoops=bomScanLoops(candidate.path("Plan"));
        assertTrue(newLoops<oldLoops,()->"Shared frontier must reduce measured BOM scans: "+oldLoops+" -> "+newLoops);
        Path directory=Path.of(System.getProperty("uten.build.directory","target"));
        Files.createDirectories(directory);
        JSON.writerWithDefaultPrettyPrinter().writeValue(directory.resolve("bom-footprint-frontier-evidence.json").toFile(),
                Map.of("scope","synthetic SQL reachability equivalence; not business-path or quantity allocation throughput",
                        "rootCount",roots.size(),"resultEdges",expected.size(),"sameFourColumnRows",true,
                        "originalBomScanLoops",oldLoops,"candidateBomScanLoops",newLoops,
                        "originalPlan",original,"candidatePlan",candidate));
    }

    private List<Row> assertEquivalent(List<UUID> roots) throws Exception {
        List<Row> expected=rows(EDGE_FRONTIER,roots);
        assertEquals(expected,rows(GOODS_FRONTIER,roots),"Candidate must retain every ordered edge, color and full-row hash");
        assertEquals(expected,rows(productionSql(),roots),"The current production query must retain reference semantics");
        String difference="""
                WITH original_rows AS (%s), candidate_rows AS (%s)
                SELECT count(*) FROM (
                    (SELECT * FROM original_rows EXCEPT SELECT * FROM candidate_rows)
                    UNION ALL
                    (SELECT * FROM candidate_rows EXCEPT SELECT * FROM original_rows)
                ) differences
                """.formatted(EDGE_FRONTIER,GOODS_FRONTIER);
        try(var query=prepare(difference,roots);var result=query.executeQuery()) {
            assertTrue(result.next()); assertEquals(0,result.getLong(1),"PostgreSQL double EXCEPT must be empty");
        }
        return expected;
    }

    private static String productionSql() {
        EntityManager em=mock(EntityManager.class); Query query=mock(Query.class);
        AtomicReference<String> captured=new AtomicReference<>();
        when(em.createNativeQuery(anyString())).thenAnswer(call->{captured.set(call.getArgument(0));return query;});
        when(query.setParameter(anyString(),any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        var service=new ProductionMutationFootprintService(em,mock(FulfillmentMutationLocks.class));
        ReflectionTestUtils.invokeMethod(service,"readCurrentBom",List.of(UUID.randomUUID()));
        assertNotNull(captured.get()); return captured.get();
    }
    private List<Row> rows(String sql,List<UUID> roots) throws Exception {
        List<Row> result=new ArrayList<>();
        try(var query=prepare(sql,roots);var rows=query.executeQuery()) {
            while(rows.next()) result.add(new Row(rows.getObject(1,UUID.class),rows.getObject(2,UUID.class),
                    rows.getObject(3,UUID.class),rows.getString(4)));
        }
        return result;
    }
    private JsonNode explain(String sql,List<UUID> roots) throws Exception {
        try(var query=prepare("EXPLAIN (ANALYZE,BUFFERS,TIMING OFF,FORMAT JSON) "+sql,roots);var result=query.executeQuery()) {
            assertTrue(result.next()); return JSON.readTree(result.getString(1)).get(0);
        }
    }
    private static long bomScanLoops(JsonNode plan) {
        long total="goods_bom_items".equals(plan.path("Relation Name").asText())?plan.path("Actual Loops").asLong():0;
        for(JsonNode child:plan.path("Plans")) total+=bomScanLoops(child);
        return total;
    }
    private PreparedStatement prepare(String sql,List<UUID> roots) throws Exception {
        int occurrences=(sql.length()-sql.replace(":rootIds","").length())/":rootIds".length();
        String placeholders=String.join(",",java.util.Collections.nCopies(roots.size(),"?"));
        PreparedStatement query=connection.prepareStatement(sql.replace(":rootIds",placeholders));
        int parameter=1;
        for(int occurrence=0;occurrence<occurrences;occurrence++) for(UUID root:roots) query.setObject(parameter++,root);
        return query;
    }
    private UUID goods(UUID color,boolean deleted) throws Exception {
        UUID id=UUID.randomUUID();
        try(var query=connection.prepareStatement("INSERT INTO goods(id,color_id,is_deleted) VALUES(?,?,?)")) {
            query.setObject(1,id);query.setObject(2,color);query.setBoolean(3,deleted);assertEquals(1,query.executeUpdate());
        }
        return id;
    }
    private UUID edge(UUID parent,UUID child,UUID color,boolean deleted) throws Exception {
        UUID id=UUID.randomUUID();
        try(var query=connection.prepareStatement("""
                INSERT INTO goods_bom_items(id,goods_id,component_goods_id,color_id,qty,summary,is_deleted)
                VALUES(?,?,?,?,1.2300,?,?)
                """)) {
            query.setObject(1,id);query.setObject(2,parent);query.setObject(3,child);query.setObject(4,color);
            query.setString(5,"Full row 中文, \"quotes\", null-like NULL\nsecond line");query.setBoolean(6,deleted);
            assertEquals(1,query.executeUpdate());
        }
        return id;
    }
    private record Row(UUID id,UUID component,UUID color,String hash) {}
}
