package com.uten.imp.features.production.analysis;

import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import com.uten.imp.support.MigratedProjectionSchema;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.SingleConnectionDataSource;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.sql.Connection;
import java.sql.DriverManager;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

/** Executes the admission query on PostgreSQL; migrated trigger coverage lives in the migration suite. */
@Testcontainers(disabledWithoutDocker = true)
@EnabledIfEnvironmentVariable(named = "UTEN_RUN_DB_TESTS", matches = "(?i)true")
class MaterialAnalysisGoodsLifecycleReaderPostgresTest {
    @Container static final PostgreSQLContainer PG = new PostgreSQLContainer("postgres:16-alpine");
    private Connection connection;
    private JdbcTemplate jdbc;
    private NamedParameterJdbcTemplate named;
    private MaterialAnalysisGoodsLifecycleReader reader;
    private UUID analysis, source, root, component, edge, material;

    @BeforeEach void prepare() throws Exception {
        connection = DriverManager.getConnection(PG.getJdbcUrl(), PG.getUsername(), PG.getPassword());
        connection.setAutoCommit(false);
        var dataSource = new SingleConnectionDataSource(connection, true);
        jdbc = new JdbcTemplate(dataSource);
        named = new NamedParameterJdbcTemplate(dataSource);
        jdbc.execute("CREATE SCHEMA lifecycle_test");
        jdbc.execute("SET search_path=lifecycle_test");
        // Query fixtures may model inconsistent lifecycle states, but their complete
        // column shapes and defaults still come from actual Flyway migrations.
        MigratedProjectionSchema.createCurrentTables(jdbc, "goods", "goods_bom_items",
                "production_material_analysis_items", "production_material_analysis_materials");
        analysis=UUID.randomUUID(); source=UUID.randomUUID(); root=UUID.randomUUID();
        component=UUID.randomUUID(); edge=UUID.randomUUID(); material=UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name,status,source_type) VALUES(?,'FG','产品',NULL,'自制'),(?,'RM','原材料','使用','外购')", root, component);
        jdbc.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id) VALUES(?,?,?)", edge, UUID.randomUUID(), component);
        jdbc.update("INSERT INTO production_material_analysis_items(id,analysis_id,goods_id) VALUES(?,?,?)", source, analysis, root);
        jdbc.update("""
                INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,goods_id,bom_item_id,depth,source_suggestion)
                VALUES(?,?,?,?,?,4,'BUY')
                """, material, analysis, source, component, edge);
        reader = new MaterialAnalysisGoodsLifecycleReader(entityManager());
        connection.commit();
    }

    @AfterEach void finish() throws Exception {
        if(connection!=null) {
            connection.rollback();
            jdbc.execute("DROP SCHEMA lifecycle_test CASCADE");
            connection.commit();
            connection.close();
        }
    }

    @Test void deepDisabledComponentAndReenabledGoodsRemainBlockedUntilTheOldEdgeIsSafelyReconciled() {
        assertThat(reader.blockedReasons(analysis)).isEmpty();
        jdbc.update("UPDATE goods SET status='禁用' WHERE id=?", component);
        jdbc.update("UPDATE goods_bom_items SET is_deleted=true WHERE id=?", edge);
        assertThat(reader.blockedReasons(analysis)).containsOnlyKeys(source);
        assertThat(reader.blockedReasons(analysis).get(source)).contains("RM 原材料", "请先刷新", "原单据");

        jdbc.update("UPDATE goods SET status='使用' WHERE id=?", component);
        assertThat(reader.blockedReasons(analysis)).containsOnlyKeys(source);
        // A successful ordinary refresh retires membership, without deleting the historical row.
        jdbc.update("UPDATE production_material_analysis_materials SET active=false WHERE id=?", material);
        assertThat(reader.blockedReasons(analysis)).isEmpty();
        assertThat(jdbc.queryForObject("SELECT count(*) FROM production_material_analysis_materials WHERE id=?", Integer.class, material)).isEqualTo(1);
    }

    @Test void disabledRootBlocksNewArrangementsAndForeignAnalysisOrDeletedSourcesCannotLeak() {
        jdbc.update("UPDATE goods SET status='禁用' WHERE id=?", root);
        assertThat(reader.blockedReasons(analysis).get(source)).contains("FG 产品", "不能新增安排", "已有任务与单据仍保留");
        assertThat(reader.blockedReasons(UUID.randomUUID())).isEmpty();
        jdbc.update("UPDATE production_material_analysis_items SET is_deleted=true WHERE id=?", source);
        assertThat(reader.blockedReasons(analysis)).isEmpty();
    }

    @Test void aChangedPeriodicIssueMethodRequiresRefreshButAnUnchangedSnapshotIsNotBlocked() {
        assertThat(reader.blockedReasons(analysis)).isEmpty();
        jdbc.update("UPDATE goods SET issue_method='PERIODIC' WHERE id=?", component);
        assertThat(reader.blockedReasons(analysis).get(source)).contains("已改为整批领料", "请先刷新");
    }

    @Test void lastProductionComponentRetiredByDisableCannotBecomeZeroMaterialManufacturingAfterRefresh() {
        jdbc.update("UPDATE goods_bom_items SET goods_id=?,is_deleted=true,retirement_reason='COMPONENT_DISABLED' WHERE id=?", root, edge);
        jdbc.update("UPDATE production_material_analysis_materials SET active=false WHERE id=?", material);
        assertThat(reader.blockedReasons(analysis).get(source)).contains("FG 产品", "最后一项生产物料", "不能直接按零物料生产");

        UUID replacement=UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name,auto_created) VALUES(?,'NEW-RM','新配方原料',true)",replacement);
        jdbc.update("INSERT INTO goods_bom_items(id,goods_id,component_goods_id) VALUES(?,?,?)",UUID.randomUUID(),root,replacement);
        assertThat(reader.blockedReasons(analysis).get(source)).contains("最后一项生产物料");
        jdbc.update("UPDATE goods SET auto_created=false WHERE id=?",replacement);
        assertThat(reader.blockedReasons(analysis)).isEmpty();
        // The migration's recipe-repair trigger resolves the old incident permanently.
        jdbc.update("UPDATE goods_bom_items SET retirement_resolved_at=now() WHERE id=?",edge);
        jdbc.update("UPDATE goods_bom_items SET is_deleted=true WHERE goods_id=? AND NOT is_deleted",root);
        assertThat(reader.blockedReasons(analysis)).isEmpty();
    }

    @Test void nestedMakeAndSubcontractNodesRequireAReplacementRecipeButOrdinaryManualDeletionDoesNot() {
        UUID oldChild=UUID.randomUUID(),oldEdge=UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name,status) VALUES(?,'OLD','旧原料','禁用')",oldChild);
        jdbc.update("""
                INSERT INTO goods_bom_items(id,goods_id,component_goods_id,is_deleted,retirement_reason)
                VALUES(?,?,?,true,'COMPONENT_DISABLED')
                """,oldEdge,component,oldChild);
        for(String route:java.util.List.of("MAKE","SUBCONTRACT")) {
            jdbc.update("UPDATE production_material_analysis_materials SET confirmed_route=? WHERE id=?",route,material);
            assertThat(reader.blockedReasons(analysis).get(source)).contains("RM 原材料", "最后一项生产物料");
        }
        jdbc.update("UPDATE goods_bom_items SET retirement_reason=NULL WHERE id=?",oldEdge);
        assertThat(reader.blockedReasons(analysis)).isEmpty();
        jdbc.update("UPDATE goods_bom_items SET retirement_reason='COMPONENT_DISABLED',control_stage='SHIP' WHERE id=?",oldEdge);
        assertThat(reader.blockedReasons(analysis)).isEmpty();
        jdbc.update("UPDATE goods_bom_items SET control_stage='START',hard_gate=false WHERE id=?",oldEdge);
        assertThat(reader.blockedReasons(analysis)).isEmpty();
    }

    @Test void mutationLocksSerializeRootAndDeepComponentStatusButLeaveUnrelatedGoodsFree() throws Exception {
        UUID unrelated=UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,code,name) VALUES(?,'OTHER','无关货品')",unrelated);
        connection.commit();
        reader.lockSources(analysis);
        try(var peer=DriverManager.getConnection(PG.getJdbcUrl(),PG.getUsername(),PG.getPassword())) {
            peer.setAutoCommit(false);
            try(var statement=peer.createStatement()) { statement.execute("SET search_path=lifecycle_test"); }
            peer.commit();
            for(UUID locked:java.util.List.of(root,component)) {
                try(var setting=peer.createStatement()) { setting.execute("SET LOCAL lock_timeout='150ms'"); }
                try(var update=peer.prepareStatement("UPDATE goods SET status='禁用' WHERE id=?")) {
                    update.setObject(1,locked);
                    var busy=assertThrows(java.sql.SQLException.class,update::executeUpdate);
                    assertThat(busy.getSQLState()).isEqualTo("55P03");
                }
                peer.rollback();
            }
            try(var update=peer.prepareStatement("UPDATE goods SET status='禁用' WHERE id=?")) {
                update.setObject(1,unrelated); assertThat(update.executeUpdate()).isEqualTo(1);
            }
            peer.rollback();
            connection.commit();
            try(var update=peer.prepareStatement("UPDATE goods SET status='禁用' WHERE id=?")) {
                update.setObject(1,component); assertThat(update.executeUpdate()).isEqualTo(1);
            }
            peer.rollback();
        }
    }

    @Test void anOrphanedChildAnchorDoesNotRecoverSchedulingWhenItsGoodsAreEnabledAgain() {
        UUID child=UUID.randomUUID(),missingParentChild=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO production_material_analysis_items(id,analysis_id,goods_id,parent_analysis_material_id)
                VALUES(?,?,?,?),(?,?,?,?)
                """,child,analysis,component,material,missingParentChild,analysis,component,UUID.randomUUID());
        jdbc.update("UPDATE production_material_analysis_materials SET active=false WHERE id=?",material);
        jdbc.update("UPDATE goods SET status='禁用' WHERE id=?",component);
        jdbc.update("UPDATE goods SET status='使用' WHERE id=?",component);
        var reasons=reader.blockedReasons(analysis);
        assertThat(reasons).containsOnlyKeys(child,missingParentChild);
        assertThat(reasons.get(child)).contains("原组装物料已移除", "不能新增安排", "不会恢复旧引用");
        assertThat(reasons.get(missingParentChild)).contains("原组装物料已移除");
    }

    private EntityManager entityManager() {
        EntityManager em=mock(EntityManager.class);
        when(em.createNativeQuery(anyString())).thenAnswer(call -> {
            String sql=call.getArgument(0);
            Query query=mock(Query.class);
            Map<String,Object> parameters=new LinkedHashMap<>();
            when(query.setParameter(anyString(),any())).thenAnswer(binding -> {
                parameters.put(binding.getArgument(0),binding.getArgument(1)); return query;
            });
            when(query.getResultList()).thenAnswer(ignored -> named.query(sql,parameters,(rs,index) ->
                    rs.getMetaData().getColumnCount()==1 ? rs.getObject(1)
                            : new Object[]{rs.getObject(1),rs.getObject(2),rs.getObject(3),rs.getObject(4)}));
            return query;
        });
        return em;
    }
}
