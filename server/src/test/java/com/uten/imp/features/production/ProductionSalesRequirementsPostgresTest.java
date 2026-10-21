package com.uten.imp.features.production;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.persistence.EntityManager;
import org.hibernate.SessionFactory;
import org.hibernate.cfg.Configuration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;

import java.util.List;
import java.util.ArrayList;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

/** Execute the production provenance query, including recursive and exact-allocation boundaries. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class ProductionSalesRequirementsPostgresTest {
    private static final PostgreSQLContainer POSTGRES = new PostgreSQLContainer("postgres:16-alpine");
    private static SessionFactory factory;
    private static JdbcTemplate jdbc;

    @BeforeAll static void start() {
        POSTGRES.start();
        jdbc = new JdbcTemplate(new DriverManagerDataSource(POSTGRES.getJdbcUrl(), POSTGRES.getUsername(), POSTGRES.getPassword()));
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(jdbc,
                "goods", "sales_orders", "sales_order_items", "production_material_analysis_items",
                "production_material_analysis_materials", "preplan_supply_actions", "preplan_aggregate_batches",
                "preplan_supply_action_allocations", "production_plans", "production_plan_items",
                "plan_order_item_links", "production_execution_segments", "execution_segment_sales_allocations",
                "preplan_aggregate_batch_events", "preplan_aggregate_material_aliases");
        com.uten.imp.support.MigratedProjectionSchema.createCurrentFunctions(jdbc,
                "fn_aggregate_relative_bom_path", "fn_preplan_aggregate_recorded_private_sources_scoped_batches",
                "fn_preplan_aggregate_recorded_private_sources_scoped",
                "fn_preplan_aggregate_recorded_private_sources");
        factory = new Configuration().setProperty("hibernate.connection.url", POSTGRES.getJdbcUrl())
                .setProperty("hibernate.connection.username", POSTGRES.getUsername())
                .setProperty("hibernate.connection.password", POSTGRES.getPassword())
                .setProperty("hibernate.hbm2ddl.auto", "none").buildSessionFactory();
    }

    @AfterAll static void stop() { if (factory != null) factory.close(); POSTGRES.stop(); }

    @Test void proofWorkIsBoundedForOneContextAndForTheWholeAnalysis() throws Exception {
        UUID analysis=UUID.randomUUID(),root=UUID.randomUUID(),goods=UUID.randomUUID(),unit=UUID.randomUUID();
        UUID order=UUID.randomUUID(),line=UUID.randomUUID(),material=UUID.randomUUID();
        List<UUID> contexts=new ArrayList<>();contexts.add(root);
        var transaction=new org.springframework.transaction.support.TransactionTemplate(
                new org.springframework.jdbc.datasource.DataSourceTransactionManager(jdbc.getDataSource()));
        transaction.executeWithoutResult(status -> {
            jdbc.update("INSERT INTO goods(id,name) VALUES (?,'容量验证')",goods);
            jdbc.update("INSERT INTO sales_orders(id,bill_no,remark) VALUES (?,'CAPACITY-NOTES','准确来源要求')",order);
            jdbc.update("INSERT INTO sales_order_items(id,order_id,goods_id,qty) VALUES (?,?,?,1000)",line,order,goods);
            jdbc.update("INSERT INTO production_material_analysis_items(id,analysis_id,sales_order_item_id,source_type,goods_id,unit_id,requested_qty) VALUES (?,?,?,'SALES_ORDER_ITEM',?,?,1000)",root,analysis,line,goods,unit);
            jdbc.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,goods_id,unit_id) VALUES (?,?,?,?,?)",material,analysis,root,goods,unit);
            for(int index=0;index<1000;index++) {
                UUID child=UUID.randomUUID(),action=UUID.randomUUID(),batch=UUID.randomUUID();contexts.add(child);
                jdbc.update("INSERT INTO production_material_analysis_items(id,analysis_id,source_type,goods_id,unit_id,requested_qty) VALUES (?,?,'AGGREGATE_MAKE',?,?,1)",child,analysis,goods,unit);
                jdbc.update("INSERT INTO preplan_supply_actions(id,analysis_id,status,route,operation_type,goods_id,unit_id,requested_qty) VALUES (?,?,'IN_PROGRESS','MAKE','SUPPLY',?,?,1)",action,analysis,goods,unit);
                jdbc.update("INSERT INTO preplan_aggregate_batches(id,analysis_id,action_id,anchor_analysis_item_id,route) VALUES (?,?,?,?,'MAKE')",batch,analysis,action,child);
                jdbc.update("INSERT INTO preplan_supply_action_allocations(action_id,analysis_id,analysis_material_id,allocated_qty) VALUES (?,?,?,1)",action,analysis,material);
                String intent="{\"sourcePrivateQtyByTargetMaterialLineId\":{\""+material+"\":{\""+material+"\":1}}}";
                jdbc.update("INSERT INTO preplan_aggregate_batch_events(batch_id,event_type,intent_snapshot) VALUES (?,'CREATE',CAST(? AS jsonb))",batch,intent);
            }
        });
        for(String table:List.of("production_material_analysis_items","production_material_analysis_materials",
                "preplan_supply_actions","preplan_aggregate_batches","preplan_supply_action_allocations","preplan_aggregate_batch_events")) {
            jdbc.execute("ANALYZE "+table);
        }
        JsonNode single=explainRequirements(List.of(contexts.get(1)));
        assertThat(single.path("Plan").path("Actual Rows").asInt()).isEqualTo(1);
        assertThat(proofWork(single.path("Plan"))).isEqualTo(1);
        JsonNode all=explainRequirements(contexts);
        assertThat(all.path("Plan").path("Actual Rows").asInt()).isEqualTo(contexts.size());
        assertThat(proofWork(all.path("Plan"))).isEqualTo(1000);
        // Default PostgreSQL settings must not aggressively compile the recursive
        // JSON body for every context. Assert plan work, not machine wall-clock time.
        assertThat(all.path("JIT").path("Options").path("Optimization").asBoolean()).isFalse();
        try(EntityManager em=factory.createEntityManager()) {
            var notes=new ProductionSalesRequirements(em).analysisItems(contexts);
            assertThat(notes).hasSize(contexts.size());
            assertThat(notes.values()).allSatisfy(requirements -> assertThat(requirements).singleElement()
                    .extracting(ProductionSalesRequirements.Requirement::salesOrderItemId).isEqualTo(line));
        }
    }

    private static JsonNode explainRequirements(List<UUID> contexts) throws Exception {
        String sql=ProductionSalesRequirements.sql("""
                SELECT item.id AS context_id,item.id AS analysis_item_id,item.sales_order_item_id
                FROM production_material_analysis_items item WHERE item.id=ANY(?) AND NOT item.is_deleted
                """);
        try(var connection=java.sql.DriverManager.getConnection(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());
            var statement=connection.prepareStatement("EXPLAIN (ANALYZE,FORMAT JSON) "+sql)) {
            statement.setQueryTimeout(20);
            statement.setArray(1,connection.createArrayOf("uuid",contexts.toArray()));
            try(var result=statement.executeQuery()) {
                result.next();return new ObjectMapper().readTree(result.getString(1)).get(0);
            }
        }
    }

    private static long proofWork(JsonNode node) {
        long work=node.path("Subplan Name").asText().equals("CTE proof")
                ?node.path("Actual Rows").asLong()*node.path("Actual Loops").asLong():0;
        for(JsonNode child:node.path("Plans"))work+=proofWork(child);
        return work;
    }

    @Test void descendantsInheritOnlyTheirSourceAndSharedChildrenKeepConflictingInstructionsSeparate() {
        UUID analysis=UUID.randomUUID(), goods=UUID.randomUUID(), orderA=UUID.randomUUID(), orderB=UUID.randomUUID();
        UUID lineA=UUID.randomUUID(), lineB=UUID.randomUUID(), rootA=UUID.randomUUID(), rootB=UUID.randomUUID();
        UUID materialA=UUID.randomUUID(), materialB=UUID.randomUUID(), child=UUID.randomUUID(), grandchild=UUID.randomUUID();
        UUID childMaterial=UUID.randomUUID(), shared=UUID.randomUUID(), action=UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,name) VALUES (?,?)",goods,"同一货品");
        jdbc.update("INSERT INTO sales_orders(id,bill_no,remark) VALUES (?,?,?),(?,?,?)",orderA,"XD-A","全单不要打字",orderB,"XD-B","全单需要打字");
        jdbc.update("INSERT INTO sales_order_items(id,order_id,goods_id,remark) VALUES (?,?,?,?),(?,?,?,?)",lineA,orderA,goods,"产品A单独要求",lineB,orderB,goods,"产品B单独要求");
        jdbc.update("INSERT INTO production_material_analysis_items(id,analysis_id,sales_order_item_id) VALUES (?,?,?),(?,?,?)",rootA,analysis,lineA,rootB,analysis,lineB);
        jdbc.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id) VALUES (?,?,?),(?,?,?),(?,?,?)",materialA,analysis,rootA,materialB,analysis,rootB,childMaterial,analysis,child);
        jdbc.update("INSERT INTO production_material_analysis_items(id,analysis_id,parent_analysis_material_id) VALUES (?,?,?),(?,?,?),(?,?,NULL)",child,analysis,materialA,grandchild,analysis,childMaterial,shared,analysis);
        jdbc.update("INSERT INTO preplan_supply_actions(id,status) VALUES (?, 'ISSUED')",action);
        jdbc.update("INSERT INTO preplan_aggregate_batches(analysis_id,action_id,anchor_analysis_item_id) VALUES (?,?,?)",analysis,action,shared);
        jdbc.update("INSERT INTO preplan_supply_action_allocations(action_id,analysis_id,analysis_material_id,allocated_qty) VALUES (?,?,?,10),(?,?,?,20)",action,analysis,materialA,action,analysis,materialB);
        try (EntityManager em=factory.createEntityManager()) {
            var query = new ProductionSalesRequirements(em);
            var notes = query.analysisItems(List.of(grandchild,shared));
            assertThat(notes.keySet()).containsExactlyInAnyOrder(grandchild,shared);
            assertThat(notes.get(grandchild)).singleElement().satisfies(note -> {
                assertThat(note.salesOrderItemId()).isEqualTo(lineA);
                assertThat(note.orderRemark()).isEqualTo("全单不要打字");
                assertThat(note.itemRemark()).isEqualTo("产品A单独要求");
            });
            assertThat(notes.get(shared)).extracting(ProductionSalesRequirements.Requirement::salesOrderItemId).containsExactly(lineA,lineB);
            jdbc.update("UPDATE preplan_supply_actions SET status='CANCELLED' WHERE id=?",action);
            assertThat(query.analysisItems(List.of(shared))).isEmpty();
            // UNION terminates even if corrupt legacy lineage contains a cycle.
            jdbc.update("UPDATE production_material_analysis_items SET parent_analysis_material_id=? WHERE id=?",childMaterial,rootA);
            assertThat(query.analysisItems(List.of(grandchild)).get(grandchild)).hasSize(1);
        }
    }

    @Test void aSplitSegmentReadsItsExactAllocationInsteadOfEverySalesLineOnThePlan() {
        UUID orderA=UUID.randomUUID(),orderB=UUID.randomUUID(),lineA=UUID.randomUUID(),lineB=UUID.randomUUID();
        UUID plan=UUID.randomUUID(),item=UUID.randomUUID(),segment=UUID.randomUUID(),manual=UUID.randomUUID();
        jdbc.update("INSERT INTO sales_orders(id,bill_no,remark) VALUES (?,?,?),(?,?,?)",orderA,"SPLIT-A","A要求",orderB,"SPLIT-B","B要求");
        jdbc.update("INSERT INTO sales_order_items(id,order_id) VALUES (?,?),(?,?)",lineA,orderA,lineB,orderB);
        jdbc.update("INSERT INTO production_plans(id) VALUES (?)",plan);
        jdbc.update("INSERT INTO production_plan_items(id,plan_id) VALUES (?,?)",item,plan);
        jdbc.update("INSERT INTO plan_order_item_links(plan_item_id,order_item_id,is_deleted,allocated_qty) VALUES (?,?,FALSE,10),(?,?,FALSE,20)",item,lineA,item,lineB);
        jdbc.update("INSERT INTO production_execution_segments(id,plan_id,source_plan_item_id) VALUES (?,?,?),(?,?,?)",segment,plan,item,manual,plan,item);
        jdbc.update("INSERT INTO execution_segment_sales_allocations(execution_segment_id,sales_order_item_id,allocated_qty) VALUES (?,?,20),(?,?,0)",segment,lineB,segment,lineA);
        try (EntityManager em=factory.createEntityManager()) {
            var query=new ProductionSalesRequirements(em);
            var notes=query.segments(List.of(segment,manual));
            assertThat(notes.get(segment)).singleElement().extracting(ProductionSalesRequirements.Requirement::salesOrderItemId).isEqualTo(lineB);
            assertThat(notes.get(manual)).hasSize(2);
            assertThat(query.planItems(List.of(item)).get(item)).hasSize(2);
            jdbc.update("UPDATE execution_segment_sales_allocations SET allocated_qty=0 WHERE execution_segment_id=?",segment);
            assertThat(query.segments(List.of(segment))).isEmpty();
            assertThat(query.analysisItems(List.of())).isEmpty();
        }
    }

    @Test void independentlyRetainedChildKeepsItsRecordedSalesInstructionsAfterParentWithdrawal() {
        UUID analysis=UUID.randomUUID(),unit=UUID.randomUUID(),product=UUID.randomUUID(),component=UUID.randomUUID();
        UUID order=UUID.randomUUID(),line=UUID.randomUUID(),root=UUID.randomUUID(),oldParent=UUID.randomUUID(),child=UUID.randomUUID();
        UUID sourceParent=UUID.randomUUID(),original=UUID.randomUUID(),canonical=UUID.randomUUID(),edge=UUID.randomUUID();
        UUID parentAction=UUID.randomUUID(),childAction=UUID.randomUUID(),parentBatch=UUID.randomUUID(),childBatch=UUID.randomUUID();
        jdbc.update("INSERT INTO goods(id,name) VALUES (?,?)",product,"撤回父批仍保留的产品");
        jdbc.update("INSERT INTO sales_orders(id,bill_no,remark) VALUES (?,?,?)",order,"PARENT-WITHDRAW","订单统一保留");
        jdbc.update("INSERT INTO sales_order_items(id,order_id,goods_id,remark) VALUES (?,?,?,?)",line,order,product,"子件不得丢失的要求");
        jdbc.update("INSERT INTO production_material_analysis_items(id,analysis_id,sales_order_item_id) VALUES (?,?,?)",root,analysis,line);
        jdbc.update("INSERT INTO production_material_analysis_items(id,analysis_id,source_type) VALUES (?,?,'AGGREGATE_MAKE'),(?,?,'AGGREGATE_MAKE')",oldParent,analysis,child,analysis);
        jdbc.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,node_role,goods_id,unit_id) VALUES (?,?,?,'root','ROOT_SUPPLY',?,?)",sourceParent,analysis,root,product,unit);
        jdbc.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,parent_node_key,bom_item_id,goods_id,unit_id) VALUES (?,?,?,'part','root',?,?,?)",original,analysis,root,edge,component,unit);
        jdbc.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,node_key,bom_item_id,goods_id,unit_id) VALUES (?,?,?,'canonical',?,?,?)",canonical,analysis,oldParent,edge,component,unit);
        jdbc.update("INSERT INTO preplan_supply_actions(id,analysis_id,status,goods_id,unit_id,route) VALUES (?,?,'CANCELLED',?,?,'MAKE'),(?,?,'IN_PROGRESS',?,?,'MAKE')",parentAction,analysis,product,unit,childAction,analysis,component,unit);
        jdbc.update("INSERT INTO preplan_aggregate_batches(id,analysis_id,action_id,anchor_analysis_item_id,route) VALUES (?,?,?,?,'MAKE'),(?,?,?,?,'MAKE')",parentBatch,analysis,parentAction,oldParent,childBatch,analysis,childAction,child);
        jdbc.update("INSERT INTO preplan_aggregate_material_aliases(batch_id,source_material_id,source_parent_material_id,aggregate_material_id,relative_bom_path,qty) VALUES (?,?,?,?,ARRAY[?]::uuid[],10)",parentBatch,original,sourceParent,canonical,edge);
        jdbc.update("INSERT INTO preplan_supply_action_allocations(action_id,analysis_id,analysis_material_id,allocated_qty) VALUES (?,?,?,10)",childAction,analysis,canonical);
        String intent="{\"sourcePrivateQtyByTargetMaterialLineId\":{\""+canonical+"\":{\""+original+"\":10}}}";
        jdbc.update("INSERT INTO preplan_aggregate_batch_events(batch_id,event_type,intent_snapshot) VALUES (?,'CREATE',CAST(? AS jsonb))",childBatch,intent);
        try (EntityManager em=factory.createEntityManager()) {
            var query=new ProductionSalesRequirements(em);
            assertThat(query.analysisItems(List.of(child)).get(child)).singleElement().satisfies(note -> {
                assertThat(note.salesOrderItemId()).isEqualTo(line);
                assertThat(note.orderRemark()).isEqualTo("订单统一保留");
                assertThat(note.itemRemark()).isEqualTo("子件不得丢失的要求");
            });
            // A partially issued child owns only its recorded slice, even while
            // the active parent also serves another sales order of the same product.
            UUID otherOrder=UUID.randomUUID(),otherLine=UUID.randomUUID(),otherRoot=UUID.randomUUID(),otherMaterial=UUID.randomUUID();
            jdbc.update("INSERT INTO sales_orders(id,bill_no,remark) VALUES (?,'OTHER-PARENT-SOURCE','另一单不得混入')",otherOrder);
            jdbc.update("INSERT INTO sales_order_items(id,order_id,goods_id) VALUES (?,?,?)",otherLine,otherOrder,product);
            jdbc.update("INSERT INTO production_material_analysis_items(id,analysis_id,sales_order_item_id) VALUES (?,?,?)",otherRoot,analysis,otherLine);
            jdbc.update("INSERT INTO production_material_analysis_materials(id,analysis_id,analysis_item_id,goods_id,unit_id) VALUES (?,?,?,?,?)",otherMaterial,analysis,otherRoot,product,unit);
            jdbc.update("INSERT INTO preplan_supply_action_allocations(action_id,analysis_id,analysis_material_id,allocated_qty) VALUES (?,?,?,10),(?,?,?,10)",parentAction,analysis,sourceParent,parentAction,analysis,otherMaterial);
            jdbc.update("UPDATE preplan_supply_actions SET status='IN_PROGRESS' WHERE id=?",parentAction);
            assertThat(query.analysisItems(List.of(child)).get(child)).singleElement().extracting(ProductionSalesRequirements.Requirement::salesOrderItemId).isEqualTo(line);
            // Also defend an invalid legacy physical-parent pointer; legal
            // aggregate anchors above use NULL and resolve through allocations.
            jdbc.update("UPDATE production_material_analysis_items SET parent_analysis_material_id=? WHERE id=?",canonical,child);
            assertThat(query.analysisItems(List.of(child)).get(child)).singleElement().extracting(ProductionSalesRequirements.Requirement::salesOrderItemId).isEqualTo(line);
            jdbc.update("UPDATE production_material_analysis_items SET parent_analysis_material_id=NULL WHERE id=?",child);
            jdbc.update("UPDATE preplan_supply_actions SET status='CANCELLED' WHERE id=?",parentAction);
            // Unbalanced evidence and a changed frozen BOM edge cannot invent a source bridge.
            jdbc.update("UPDATE preplan_supply_action_allocations SET allocated_qty=11 WHERE action_id=?",childAction);
            assertThat(query.analysisItems(List.of(child))).isEmpty();
            jdbc.update("UPDATE preplan_supply_action_allocations SET allocated_qty=10 WHERE action_id=?",childAction);
            jdbc.update("UPDATE production_material_analysis_materials SET bom_item_id=? WHERE id=?",UUID.randomUUID(),canonical);
            assertThat(query.analysisItems(List.of(child))).isEmpty();
        }
    }
}
