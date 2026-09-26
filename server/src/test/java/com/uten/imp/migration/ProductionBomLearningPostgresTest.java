package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.sql.*;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/** Real migrated SQL projection/transaction tests. Fulfillment authorization
 * and physical inventory movements are covered by the service full-chain tests. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProductionBomLearningPostgresTest {
    static final PostgreSQLContainer<?> DATABASE=new PostgreSQLContainer<>("postgres:16-alpine");
    Connection db;
    String schema;
    UUID product,material,unit;
    record Batch(UUID segment,UUID demand,UUID report,UUID issue,UUID settlement) { }

    @BeforeAll static void migrate() {
        DATABASE.start();
        var migration=Flyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())
                .locations("classpath:db/migration").target("711").load();
        migration.migrate(); migration.validate();
        assertEquals(0,migration.migrate().migrationsExecuted);
    }
    @AfterAll static void stop(){DATABASE.stop();}
    @AfterEach void close()throws Exception {db.close();}
    @BeforeEach void fixture()throws Exception {
        db=connection(); schema="bom_learn_"+UUID.randomUUID().toString().replace("-","");
        sql("CREATE SCHEMA "+schema); sql("SET search_path TO "+schema+",public");
        for(String table:List.of("goods","units","production_execution_segments","production_daily_reports","production_daily_report_items",
                "production_material_demands","production_material_stock_postings","production_material_settlement_events","production_material_settlement_postings",
                "production_execution_segment_splits","production_actual_output_supplement_requests","production_actual_output_supplement_proofs",
                "production_actual_output_supplement_reversals","production_material_return_requests","production_material_return_request_items",
                "production_material_return_request_cancellations","stock_documents","business_outbox")) {
            com.uten.imp.support.MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(db,table);
            // Preserve real scalar defaults, while intentionally omitting the
            // unrelated business guards in this focused projection fixture.
            try(var statement=db.prepareStatement("""
                    SELECT attribute.attname,pg_get_expr(definition.adbin,definition.adrelid)
                    FROM pg_attribute attribute JOIN pg_attrdef definition ON definition.adrelid=attribute.attrelid AND definition.adnum=attribute.attnum
                    WHERE attribute.attrelid=CAST(? AS regclass)
                    """)) {
                statement.setString(1,"public."+table);
                try(var rows=statement.executeQuery()) {
                    while(rows.next()) {
                        String expression=rows.getString(2);
                        if(!expression.contains("(")||List.of("now()","gen_random_uuid()","txid_current()").contains(expression))
                            sql("ALTER TABLE "+table+" ALTER COLUMN \""+rows.getString(1)+"\" SET DEFAULT "+expression);
                    }
                }
            }
        }
        for(String table:List.of("goods_bom_items","goods_bom_learning_profiles","production_bom_learning_samples",
                "goods_bom_learning_material_totals","production_bom_learning_refresh_queue"))
            com.uten.imp.support.MigratedProjectionSchema.copyConstrainedTablesFromMigratedCatalog(db,table);
        for(String function:List.of("fn_production_execution_cost_scope(uuid)","fn_production_execution_cost_members(uuid)",
                "fn_material_issue_pending_return(uuid,uuid)","fn_bom_learning_manual_ownership()","fn_enqueue_bom_learning(uuid)",
                "fn_publish_learned_bom(uuid)","fn_refresh_bom_learning(uuid)","fn_drain_bom_learning_queue()","fn_touch_bom_learning()")) {
            String definition=scalar("SELECT pg_get_functiondef(CAST(? AS regprocedure))","public."+function);
            sql(definition.replace("FUNCTION public.","FUNCTION "+schema+"."));
        }
        try(var statement=db.createStatement();var rows=statement.executeQuery("""
                SELECT pg_get_triggerdef(trigger.oid) FROM pg_trigger trigger JOIN pg_class relation ON relation.oid=trigger.tgrelid
                JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
                WHERE namespace.nspname='public' AND NOT trigger.tgisinternal
                    AND (trigger.tgname LIKE 'trg_learn_bom_%' OR trigger.tgname IN('trg_drain_bom_learning_queue','trg_bom_learning_manual_ownership'))
                """)) {
            while(rows.next())sql(rows.getString(1).replace(" ON public."," ON "+schema+".").replace("FUNCTION public.","FUNCTION "+schema+"."));
        }
        unit=UUID.randomUUID();product=goods("自制");material=goods("采购");
        sql("INSERT INTO units(id,name) VALUES(?,'基本单位')",unit);
    }

    @Test void weightedTotalsUseRealOutputAndIncludeZeroForMaterialsAbsentFromOtherBatches()throws Exception {
        batch(product,"100","100","20",true);
        amount("0.2",bomQty(material));
        UUID secondMaterial=goods("采购");
        db.setAutoCommit(false);
        Batch second=batch(product,"300","300","90",false);
        addMaterial(second.segment,secondMaterial,"30");
        db.commit();db.setAutoCommit(true);
        amount("400",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        amount("0.275",bomQty(material)); amount("0.075",bomQty(secondMaterial));
        assertEquals("2",scalar("SELECT sample_count FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals("2",scalar("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted",product));
        assertEquals("0",scalar("SELECT count(*) FROM production_bom_learning_refresh_queue"));
    }

    @Test void draftAndPartialOutputCannotTeachAndReplayChangesNoTotalsOrRevision()throws Exception {
        Batch batch=batch(product,"100","50","20",true);
        assertEquals("PRODUCTION_OPEN",state(batch));
        assertEquals("0",scalar("SELECT count(*) FROM goods_bom_items"));
        UUID report=report(batch.segment,"50",0,false);
        assertEquals("PENDING_REPORT",state(batch));
        sql("UPDATE production_daily_reports SET status=1 WHERE id=?",report);
        amount("0.2",bomQty(material));
        String revision=scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment);
        for(int i=0;i<5;i++)sql("SELECT fn_enqueue_bom_learning(?)",batch.segment);
        assertEquals(revision,scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment));
        amount("100",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
    }

    @Test void confirmedReturnsReduceNetUseAndReversalRetractsContributionAndRestoresSameEdges()throws Exception {
        Batch batch=batch(product,"100","100","120",true);
        amount("1.2",bomQty(material));
        String originalEdge=scalar("SELECT id FROM goods_bom_items WHERE goods_id=?",product);
        db.setAutoCommit(false);
        settlement(batch.demand,"20","REVERSE","CONSUMED");
        UUID request=UUID.randomUUID();
        sql("INSERT INTO production_material_return_requests(id,execution_segment_id) VALUES(?,?)",request,batch.segment);
        sql("INSERT INTO stock_documents(id,status,is_deleted) VALUES(?,0,false)",request);
        sql("INSERT INTO production_material_return_request_items(request_id,issue_posting_id,qty_base) VALUES(?,?,20)",request,batch.issue);
        db.commit();db.setAutoCommit(true);
        assertEquals("PENDING_RETURN",state(batch));
        assertEquals("0",scalar("SELECT count(*) FROM goods_bom_items WHERE NOT is_deleted"));
        db.setAutoCommit(false);
        sql("UPDATE stock_documents SET status=1 WHERE id=?",request);
        sql("INSERT INTO production_material_stock_postings(demand_id,posting_type,qty_base,source_posting_id) VALUES(?,'GOOD_RETURN',20,?)",batch.demand,batch.issue);
        db.commit();db.setAutoCommit(true);
        amount("1",bomQty(material));
        sql("UPDATE production_daily_reports SET status=-1 WHERE id=?",batch.report);
        amount("0",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals("0",scalar("SELECT count(*) FROM goods_bom_items WHERE NOT is_deleted"));
        sql("UPDATE production_daily_reports SET status=1 WHERE id=?",batch.report);
        amount("1",bomQty(material));
        assertEquals(originalEdge,scalar("SELECT id FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted",product));
    }

    @Test void manualRecipeChangeKeepsAuthorityWhileNewSamplesStillAccumulate()throws Exception {
        batch(product,"100","100","20",true);
        sql("UPDATE goods_bom_items SET qty=3 WHERE goods_id=?",product);
        batch(product,"100","100","40",false);
        amount("3",bomQty(material));
        assertEquals("f",scalar("SELECT enabled FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        amount("200",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        amount("60",scalar("SELECT net_qty FROM goods_bom_learning_material_totals WHERE goods_id=?",product));
    }

    @Test void savingAndDeletingAnExtraDraftNeverErasesPreviouslyLearnedFacts()throws Exception {
        Batch batch=batch(product,"100","100","20",true);
        String revision=scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment);
        UUID draft=report(batch.segment,"5",0,false);
        amount("0.2",bomQty(material));
        amount("100",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals(revision,scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment));
        sql("UPDATE production_daily_reports SET is_deleted=true WHERE id=?",draft);
        amount("0.2",bomQty(material));
        assertEquals(revision,scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment));
    }

    @Test void anOpenDraftCannotHideARealConsumptionReversal()throws Exception {
        Batch batch=batch(product,"100","100","20",true);
        report(batch.segment,"5",0,false);
        settlement(batch.demand,"5","REVERSE","CONSUMED");
        amount("0",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals("MATERIAL_NOT_CLEARED",state(batch));
        assertEquals("0",scalar("SELECT count(*) FROM goods_bom_items WHERE NOT is_deleted"));
    }

    @Test void extraUnconsumedIssueRetainsCompletedKnowledgeUntilTheNextBatchCloses()throws Exception {
        Batch batch=batch(product,"100","100","20",true);
        String revision=scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment);
        sql("INSERT INTO production_material_stock_postings(demand_id,posting_type,qty_base) VALUES(?,'ISSUE',1)",batch.demand);
        amount("0.2",bomQty(material));
        amount("100",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals(revision,scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment));
        UUID draft=report(batch.segment,"5",0,false);
        settlement(batch.demand,"1","POST","CONSUMED");
        amount("100",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        sql("UPDATE production_daily_reports SET status=1 WHERE id=?",draft);
        amount("105",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        amount("21",scalar("SELECT net_qty FROM goods_bom_learning_material_totals WHERE goods_id=?",product));
        amount("0.2",bomQty(material));
    }

    @Test void cycleAndSameMaterialDifferentColorsBlockPublicationWithoutCorruptingHistory()throws Exception {
        sql("INSERT INTO goods_bom_items(goods_id,component_goods_id,qty) VALUES(?,?,1)",material,product);
        Batch batch=batch(product,"100","100","20",true);
        assertEquals("BOM_CYCLE",scalar("SELECT blocked_reason FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals("0",scalar("SELECT count(*) FROM goods_bom_items WHERE goods_id=?",product));
        amount("100",scalar("SELECT output_qty FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment));
    }

    @Test void differentColorsNeverCollapseIntoOneBomIdentity()throws Exception {
        batch(product,"100","100","20",true);
        db.setAutoCommit(false);
        Batch second=batch(product,"100","100","20",false);
        sql("UPDATE production_material_demands SET color_id=? WHERE id=?",UUID.randomUUID(),second.demand);
        db.commit();db.setAutoCommit(true);
        assertEquals("MATERIAL_COLOR_OR_UNIT_CONFLICT",scalar("SELECT blocked_reason FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        amount("0.2",bomQty(material));
        assertEquals("2",scalar("SELECT count(*) FROM goods_bom_learning_material_totals WHERE goods_id=?",product));
    }

    @Test void outputUnitConversionAndTrueOverproductionUseActualDenominator()throws Exception {
        db.setAutoCommit(false);
        Batch batch=batch(product,"100","110","44",true);
        sql("UPDATE production_execution_segments SET product_unit_rate=2 WHERE id=?",batch.segment);
        sql("UPDATE production_daily_report_items SET unit_rate=2 WHERE execution_segment_id=?",batch.segment);
        db.commit();db.setAutoCommit(true);
        amount("220",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        amount("0.2",bomQty(material));
        // Quality recovery reuses existing physical output; it is not a second
        // production denominator and cannot dilute the BOM.
        db.setAutoCommit(false);
        UUID recovery=report(batch.segment,"10",1,false);
        sql("UPDATE production_daily_report_items SET fqc_recovery_authorization_id=? WHERE report_id=?",UUID.randomUUID(),recovery);
        db.commit();db.setAutoCommit(true);
        amount("220",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
    }

    @Test void splitFamilyCountsPhysicalMaterialOnceAndWaitsForEveryBatch()throws Exception {
        db.setAutoCommit(false);
        Batch root=batch(product,"100","0","20",true);
        sql("DELETE FROM production_daily_report_items WHERE report_id=?",root.report);
        UUID first=UUID.randomUUID(),second=UUID.randomUUID();
        segment(first,product,"40",false,root.segment);segment(second,product,"60",false,root.segment);
        sql("INSERT INTO production_execution_segment_splits(source_segment_id,batch_segment_id,remaining_segment_id) VALUES(?,?,?)",root.segment,first,second);
        report(first,"40",1,false);
        db.commit();db.setAutoCommit(true);
        assertEquals("PRODUCTION_OPEN",state(root));
        report(second,"60",1,false);
        amount("100",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        amount("0.2",bomQty(material));
        assertEquals("1",scalar("SELECT sample_count FROM goods_bom_learning_profiles WHERE goods_id=?",product));
    }

    @Test void additionalActualPlanSharesOneMaterialFamilyWithoutDuplicatingOutput()throws Exception {
        Batch root=batch(product,"100","100","26",true);
        amount("0.26",bomQty(material));
        db.setAutoCommit(false);
        UUID supplement=UUID.randomUUID();segment(supplement,product,"30",false,null);
        sql("INSERT INTO production_actual_output_supplement_proofs(source_execution_segment_id,supplement_execution_segment_id) VALUES(?,?)",root.segment,supplement);
        db.commit();db.setAutoCommit(true);
        assertEquals("READY",state(root));
        amount("0.26",bomQty(material));
        report(supplement,"30",1,false);
        amount("130",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        amount("0.2",bomQty(material));
        assertEquals("1",scalar("SELECT sample_count FROM goods_bom_learning_profiles WHERE goods_id=?",product));
    }

    @Test void pendingWipAndUnitDriftRemoveEarlierContribution()throws Exception {
        Batch batch=batch(product,"100","100","20",true);
        db.setAutoCommit(false);
        settlement(batch.demand,"5","REVERSE","CONSUMED");settlement(batch.demand,"5","POST","LEGAL_WIP");
        db.commit();db.setAutoCommit(true);
        assertEquals("MATERIAL_NOT_CLEARED",state(batch));
        amount("0",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        db.setAutoCommit(false);
        settlement(batch.demand,"5","REVERSE","LEGAL_WIP");settlement(batch.demand,"5","POST","CONSUMED");
        sql("UPDATE production_material_demands SET unit_id=? WHERE id=?",UUID.randomUUID(),batch.demand);
        db.commit();db.setAutoCommit(true);
        assertEquals("MATERIAL_IDENTITY_CHANGED",state(batch));
        assertEquals("0",scalar("SELECT count(*) FROM goods_bom_items WHERE NOT is_deleted"));
    }

    @Test void concurrentFamiliesSerializeTheSameParentAndKeepExactTotals()throws Exception {
        Batch first=batch(product,"100","50","20",true),second=batch(product,"100","50","40",false);
        try(var pool=Executors.newFixedThreadPool(2)) {
            var a=pool.submit(()->approveSecondHalf(first));var b=pool.submit(()->approveSecondHalf(second));
            a.get(20,TimeUnit.SECONDS);b.get(20,TimeUnit.SECONDS);
        }
        amount("200",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        amount("0.3",bomQty(material));assertEquals("2",scalar("SELECT sample_count FROM goods_bom_learning_profiles WHERE goods_id=?",product));
    }

    @Test void businessResetRetainsAverageAsMasterBaselineAndNewSamplesAppend()throws Exception {
        batch(product,"100","100","20",true);
        // The runtime/ops policy truncates these business samples while keeping
        // the profile, exact material aggregates and learned master edges.
        sql("TRUNCATE production_bom_learning_samples,production_bom_learning_refresh_queue");
        batch(product,"300","300","90",false);
        amount("0.275",bomQty(material));
        amount("400",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals("1",scalar("SELECT count(*) FROM production_bom_learning_samples"));
        assertEquals("2",scalar("SELECT sample_count FROM goods_bom_learning_profiles WHERE goods_id=?",product));
    }

    @Test void quantityRefinementDoesNotTakeGraphTopologyLock()throws Exception {
        batch(product,"100","100","20",true);
        try(Connection graphWriter=connection()) {
            graphWriter.setAutoCommit(false);
            execute(graphWriter,"SELECT pg_advisory_xact_lock(hashtextextended('goods-bom-learning-graph',0))");
            sql("SET lock_timeout='2s'");
            batch(product,"100","100","40",false);
            amount("0.3",bomQty(material));
            graphWriter.rollback();
        }
    }

    private Void approveSecondHalf(Batch batch)throws Exception {
        try(Connection other=connection()) {
            execute(other,"SET search_path TO "+schema+",public");other.setAutoCommit(false);
            UUID report=UUID.randomUUID();execute(other,"INSERT INTO production_daily_reports(id,status,is_deleted) VALUES(?,1,false)",report);
            execute(other,"INSERT INTO production_daily_report_items(report_id,execution_segment_id,goods_id,unit_id,unit_rate,qty,is_final,is_deleted) VALUES(?,?,?,?,1,50,false,false)",report,batch.segment,product,unit);
            other.commit();return null;
        }
    }
    private UUID goods(String source)throws Exception {
        UUID id=UUID.randomUUID();sql("INSERT INTO goods(id,unit_id,source_type,is_deleted,auto_created) VALUES(?,?,?,false,false)",id,unit,source);return id;
    }
    private void segment(UUID id,UUID parent,String quantity,boolean discovery,UUID source)throws Exception {
        sql("INSERT INTO production_execution_segments(id,product_goods_id,product_unit_id,product_unit_rate,planned_qty,status,is_deleted,material_discovery_required,source_segment_id,split_root_segment_id) VALUES(?,?,?,1,?,'IN_PROGRESS',false,?,?,?)",
                id,parent,unit,new BigDecimal(quantity),discovery,source,source);
    }
    private Batch batch(UUID parent,String planned,String produced,String consumed,boolean discovery)throws Exception {
        boolean own=db.getAutoCommit();if(own)db.setAutoCommit(false);
        UUID segment=UUID.randomUUID();segment(segment,parent,planned,discovery,null);
        UUID[] materialIds=addMaterial(segment,material,consumed);
        UUID report=report(segment,produced,1,false);
        if(own){db.commit();db.setAutoCommit(true);}
        return new Batch(segment,materialIds[0],report,materialIds[1],materialIds[2]);
    }
    private UUID[] addMaterial(UUID segment,UUID component,String consumed)throws Exception {
        UUID demand=UUID.randomUUID(),issue=UUID.randomUUID();
        sql("INSERT INTO production_material_demands(id,execution_segment_id,goods_id,unit_id,is_deleted,status) VALUES(?,?,?,?,false,'FULFILLED')",demand,segment,component,unit);
        sql("INSERT INTO production_material_stock_postings(id,demand_id,posting_type,qty_base) VALUES(?,?,'ISSUE',?)",issue,demand,new BigDecimal(consumed));
        UUID settled=settlement(demand,consumed,"POST","CONSUMED");return new UUID[]{demand,issue,settled};
    }
    private UUID settlement(UUID demand,String qty,String eventType,String kind)throws Exception {
        UUID event=UUID.randomUUID(),posting=UUID.randomUUID();
        sql("INSERT INTO production_material_settlement_events(id,event_type) VALUES(?,?)",event,eventType);
        sql("INSERT INTO production_material_settlement_postings(id,event_id,demand_id,settlement_type,qty_base) VALUES(?,?,?,?,?)",posting,event,demand,kind,new BigDecimal(qty));return posting;
    }
    private UUID report(UUID segment,String qty,int status,boolean finished)throws Exception {
        UUID id=UUID.randomUUID();sql("INSERT INTO production_daily_reports(id,status,is_deleted) VALUES(?,?,false)",id,status);
        sql("INSERT INTO production_daily_report_items(report_id,execution_segment_id,goods_id,unit_id,unit_rate,qty,is_final,is_deleted) VALUES(?,?,?,?,1,?,?,false)",id,segment,product,unit,new BigDecimal(qty),finished);return id;
    }
    private String state(Batch batch)throws Exception{return scalar("SELECT state FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment);}
    private String bomQty(UUID component)throws Exception{return scalar("SELECT qty FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",product,component);}
    private static Connection connection()throws SQLException{return DriverManager.getConnection(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword());}
    private void sql(String sql,Object...args)throws SQLException{execute(db,sql,args);}
    private static void execute(Connection connection,String sql,Object...args)throws SQLException {
        try(var statement=connection.prepareStatement(sql)){for(int i=0;i<args.length;i++)statement.setObject(i+1,args[i]);statement.execute();}
    }
    private String scalar(String sql,Object...args)throws SQLException {
        try(var statement=db.prepareStatement(sql)){for(int i=0;i<args.length;i++)statement.setObject(i+1,args[i]);
            try(var rows=statement.executeQuery()){return rows.next()?rows.getString(1):null;}}
    }
    private static void amount(String expected,String actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(new BigDecimal(actual)),actual);}
}
