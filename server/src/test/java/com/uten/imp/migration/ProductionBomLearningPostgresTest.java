package com.uten.imp.migration;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.testcontainers.containers.PostgreSQLContainer;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.sql.*;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

import static org.junit.jupiter.api.Assertions.*;

/** Real migrated SQL projection/transaction tests of the ADR-129 learning engine.
 * Fulfillment authorization and physical inventory movements are covered by the
 * service full-chain tests. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class ProductionBomLearningPostgresTest {
    static final PostgreSQLContainer<?> DATABASE=new PostgreSQLContainer<>("postgres:16-alpine");
    static String actualUsageView,usageView;
    Connection db;
    String schema;
    UUID product,material,unit;
    record Batch(UUID segment,UUID demand,UUID report,UUID issue,UUID settlement) { }

    @BeforeAll static void migrate()throws Exception {
        DATABASE.start();
        var migration=Flyway.configure().dataSource(DATABASE.getJdbcUrl(),DATABASE.getUsername(),DATABASE.getPassword())
                .locations("classpath:db/migration").load();
        migration.migrate(); migration.validate();
        assertEquals(0,migration.migrate().migrationsExecuted);
        // Read with the default search path so relation names stay unqualified
        // and the private fixture schema shadows them.
        try(Connection plain=connection();var statement=plain.createStatement();
            var rows=statement.executeQuery("SELECT pg_get_viewdef('public.v_goods_bom_actual_usage'::regclass,true),"
                    +"pg_get_viewdef('public.v_goods_bom_item_usage'::regclass,true)")) {
            assertTrue(rows.next());actualUsageView=rows.getString(1);usageView=rows.getString(2);
        }
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
                "production_material_return_request_cancellations","production_execution_periodic_materials","stock_documents","business_outbox")) {
            com.uten.imp.support.MigratedProjectionSchema.copyEmptyTablesFromMigratedCatalog(db,table);
            // Preserve real scalar defaults, while intentionally omitting the
            // unrelated business guards in this focused projection fixture.
            try(var statement=db.prepareStatement("""
                    SELECT attribute.attname,pg_get_expr(definition.adbin,definition.adrelid)
                    FROM pg_attribute attribute JOIN pg_attrdef definition ON definition.adrelid=attribute.attrelid AND definition.adnum=attribute.attnum
                    WHERE attribute.attrelid=CAST(? AS regclass) AND attribute.attgenerated=''
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
                "production_bom_learning_refresh_queue","goods_bom_actual_usages"))
            com.uten.imp.support.MigratedProjectionSchema.copyConstrainedTablesFromMigratedCatalog(db,table);
        sql("CREATE VIEW v_goods_bom_actual_usage AS "+actualUsageView);
        sql("CREATE VIEW v_goods_bom_item_usage AS "+usageView);
        for(String function:List.of("fn_production_execution_cost_scope(uuid)","fn_production_execution_cost_members(uuid)",
                "fn_material_issue_pending_return(uuid,uuid)","fn_bom_learning_manual_ownership()","fn_enqueue_bom_learning(uuid)",
                "fn_publish_learned_bom(uuid,boolean)","fn_refresh_bom_learning(uuid,boolean)","fn_drain_bom_learning_queue()",
                "fn_touch_bom_learning()","fn_goods_bom_material_cost(uuid)","fn_relearn_bom_actual_usage(uuid,uuid,uuid)",
                "fn_bom_learning_uncovered_output(uuid[],uuid,uuid)",
                "fn_bom_learning_periodic_exposure_is_proven(uuid[],uuid,uuid)")) {
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

    @Test void materialExposureStartsWhenTheMaterialIsUsedAndDiscoveryCountsKnownMaterialsAsZero()throws Exception {
        batch(product,"100","100","20",true);
        amount("0.2",bomQty(material));
        amount("0.2",actual(material));
        UUID secondMaterial=goods("采购");
        db.setAutoCommit(false);
        Batch second=batch(product,"300","300","90",true);
        addMaterial(second.segment,secondMaterial,"30");
        db.commit();db.setAutoCommit(true);
        // 110/400 for the first material. The second one is new: the first on-site
        // batch was exposed to it as well, so it is 30/400 and not 30/300.
        amount("0.275",actual(material)); amount("0.075",actual(secondMaterial));
        // Learned edges keep both columns equal.
        amount("0.275",bomQty(material)); amount("0.075",bomQty(secondMaterial));
        // A later on-site batch that does not use the second material still counts for it.
        batch(product,"100","100","20",true);
        amount("0.06",actual(secondMaterial));
        assertEquals("3",scalar("SELECT sample_count FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,secondMaterial));
        amount("500",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals("3",scalar("SELECT sample_count FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals("2",scalar("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted AND learning_profile_goods_id=?",product,product));
        assertEquals("0",scalar("SELECT count(*) FROM production_bom_learning_refresh_queue"));
    }

    @Test void manualBomParentLearnsActualUsageWithoutTouchingTheDesignQuantity()throws Exception {
        UUID edge=manualEdge(product,material,"0.25");
        String version=scalar("SELECT xmin::text FROM goods_bom_items WHERE id=?",edge);
        batch(product,"100","100","20",false);
        amount("0.25",bomQty(material));
        assertNull(scalar("SELECT learning_profile_goods_id FROM goods_bom_items WHERE id=?",edge));
        assertEquals(version,scalar("SELECT xmin::text FROM goods_bom_items WHERE id=?",edge));
        amount("0.2",scalar("SELECT actual_qty FROM v_goods_bom_item_usage WHERE bom_item_id=?",edge));
        amount("0.2",scalar("SELECT effective_qty FROM v_goods_bom_item_usage WHERE bom_item_id=?",edge));
        assertEquals("ACTUAL",scalar("SELECT usage_basis FROM v_goods_bom_item_usage WHERE bom_item_id=?",edge));
        assertEquals("f",scalar("SELECT system_learned FROM v_goods_bom_item_usage WHERE bom_item_id=?",edge));
    }

    @Test void nonLinearEdgesKeepTheirDesignRuleAndPartialPackagesScaleToTheirBasis()throws Exception {
        UUID packaged=manualEdge(product,material,"2");
        sql("UPDATE goods_bom_items SET consumption_basis='PER_PACKAGE',basis_output_qty=50,allow_partial_package=TRUE WHERE id=?",packaged);
        batch(product,"100","100","3",false);
        // 0.03 per unit, i.e. 1.5 per 50-unit package.
        amount("1.5",scalar("SELECT actual_qty FROM v_goods_bom_item_usage WHERE bom_item_id=?",packaged));
        amount("1.5",scalar("SELECT effective_qty FROM v_goods_bom_item_usage WHERE bom_item_id=?",packaged));
        assertEquals("t",scalar("SELECT linear FROM v_goods_bom_item_usage WHERE bom_item_id=?",packaged));
        sql("UPDATE goods_bom_items SET allow_partial_package=FALSE WHERE id=?",packaged);
        assertEquals("f",scalar("SELECT linear FROM v_goods_bom_item_usage WHERE bom_item_id=?",packaged));
        assertEquals("NOT_LINEAR",scalar("SELECT actual_status FROM v_goods_bom_item_usage WHERE bom_item_id=?",packaged));
        assertNull(scalar("SELECT actual_qty FROM v_goods_bom_item_usage WHERE bom_item_id=?",packaged));
        amount("2",scalar("SELECT effective_qty FROM v_goods_bom_item_usage WHERE bom_item_id=?",packaged));
        amount("0.03",scalar("SELECT actual_per_unit_qty FROM v_goods_bom_item_usage WHERE bom_item_id=?",packaged));
    }

    @Test void unfinishedFamiliesWriteNothingAndReplayChangesNoTotalsOrRevision()throws Exception {
        Batch batch=batch(product,"100","50","20",true);
        assertNull(state(batch));
        assertEquals("0",scalar("SELECT count(*) FROM goods_bom_learning_profiles"));
        assertEquals("0",scalar("SELECT count(*) FROM goods_bom_items"));
        UUID report=report(batch.segment,"50",0,false);
        assertNull(state(batch));
        sql("UPDATE production_daily_reports SET status=1 WHERE id=?",report);
        amount("0.2",bomQty(material));
        String revision=scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment);
        for(int i=0;i<5;i++)sql("SELECT fn_enqueue_bom_learning(?)",batch.segment);
        assertEquals(revision,scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment));
        amount("100",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
    }

    @Test void confirmedReturnsReduceNetUseAndReversalWithdrawsTheContributionButKeepsTheEdge()throws Exception {
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
        // The old 120 is no longer proven by the 100 still consumed: withdrawn,
        // calculation falls back to the unchanged design value of the edge.
        assertNull(actual(material));
        amount("1.2",bomQty(material));
        assertEquals("DESIGN",scalar("SELECT usage_basis FROM v_goods_bom_item_usage WHERE bom_item_id=CAST(? AS uuid)",originalEdge));
        db.setAutoCommit(false);
        sql("UPDATE stock_documents SET status=1 WHERE id=?",request);
        sql("INSERT INTO production_material_stock_postings(demand_id,posting_type,qty_base,source_posting_id) VALUES(?,'GOOD_RETURN',20,?)",batch.demand,batch.issue);
        db.commit();db.setAutoCommit(true);
        amount("1",actual(material)); amount("1",bomQty(material));
        sql("UPDATE production_daily_reports SET status=-1 WHERE id=?",batch.report);
        amount("0",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertNull(actual(material));
        assertEquals(originalEdge,scalar("SELECT id FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted",product));
        sql("UPDATE production_daily_reports SET status=1 WHERE id=?",batch.report);
        amount("1",actual(material));
        assertEquals(originalEdge,scalar("SELECT id FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted",product));
    }

    @Test void editingTheDesignQuantityHandsOnlyThatEdgeToPeopleWhileActualKeepsLearning()throws Exception {
        batch(product,"100","100","20",true);
        String edge=scalar("SELECT id FROM goods_bom_items WHERE goods_id=?",product);
        sql("UPDATE goods_bom_items SET summary='只改备注' WHERE goods_id=?",product);
        assertEquals(product.toString(),scalar("SELECT learning_profile_goods_id FROM goods_bom_items WHERE id=CAST(? AS uuid)",edge));
        sql("UPDATE goods_bom_items SET qty=3 WHERE goods_id=?",product);
        assertNull(scalar("SELECT learning_profile_goods_id FROM goods_bom_items WHERE id=CAST(? AS uuid)",edge));
        batch(product,"100","100","40",false);
        amount("3",bomQty(material));
        amount("0.3",actual(material));
        amount("200",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
    }

    @Test void aPersonDeletingALearnedComponentIsNeverUndoneByLearning()throws Exception {
        batch(product,"100","100","20",true);
        sql("UPDATE goods_bom_items SET is_deleted=TRUE,deleted_at=now() WHERE goods_id=?",product);
        assertNotNull(scalar("SELECT learning_released_at FROM goods_bom_items WHERE goods_id=?",product));
        UUID other=goods("采购");
        db.setAutoCommit(false);
        Batch next=batch(product,"100","100","20",true);
        addMaterial(next.segment,other,"5");
        db.commit();db.setAutoCommit(true);
        assertEquals("0",scalar("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",product,material));
        // Both on-site batches were exposed to the new material: 5/200.
        amount("0.025",bomQty(other));
        amount("0.2",actual(material));
    }

    @Test void savingAndDeletingAnExtraDraftNeverErasesPreviouslyLearnedFacts()throws Exception {
        Batch batch=batch(product,"100","100","20",true);
        String revision=scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment);
        UUID draft=report(batch.segment,"5",0,false);
        amount("0.2",actual(material));
        amount("100",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        sql("UPDATE production_daily_reports SET is_deleted=true WHERE id=?",draft);
        amount("0.2",actual(material));
        amount("0.2",bomQty(material));
        assertNotNull(revision);
    }

    @Test void anOpenDraftCannotHideARealConsumptionReversal()throws Exception {
        Batch batch=batch(product,"100","100","20",true);
        report(batch.segment,"5",0,false);
        settlement(batch.demand,"5","REVERSE","CONSUMED");
        amount("0",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals("PENDING_REPORT",state(batch));
        assertNull(actual(material));
    }

    @Test void extraUnconsumedIssueRetainsCompletedKnowledgeUntilTheNextBatchCloses()throws Exception {
        Batch batch=batch(product,"100","100","20",true);
        String revision=scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment);
        sql("INSERT INTO production_material_stock_postings(demand_id,posting_type,qty_base) VALUES(?,'ISSUE',1)",batch.demand);
        amount("0.2",actual(material));
        amount("100",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals(revision,scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment));
        UUID draft=report(batch.segment,"5",0,false);
        settlement(batch.demand,"1","POST","CONSUMED");
        amount("100",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        sql("UPDATE production_daily_reports SET status=1 WHERE id=?",draft);
        amount("105",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        amount("21",scalar("SELECT net_qty FROM goods_bom_actual_usages WHERE goods_id=?",product));
        amount("0.2",actual(material));
    }

    @Test void cycleBlocksCreatingTheLearnedRecipeWithoutLosingTheActualUsage()throws Exception {
        sql("INSERT INTO goods_bom_items(goods_id,component_goods_id,qty) VALUES(?,?,1)",material,product);
        Batch batch=batch(product,"100","100","20",true);
        assertEquals("BOM_CYCLE",scalar("SELECT blocked_reason FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals("0",scalar("SELECT count(*) FROM goods_bom_items WHERE goods_id=?",product));
        amount("100",scalar("SELECT output_qty FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment));
        amount("0.2",actual(material));
    }

    @Test void twoColorsOfOneOnSiteMaterialBlockCreationButStillFormOneActualUsage()throws Exception {
        db.setAutoCommit(false);
        Batch batch=batch(product,"100","100","10",true);
        UUID[] red=addMaterial(batch.segment,material,"10");
        sql("UPDATE production_material_demands SET color_id=? WHERE id=?",UUID.randomUUID(),red[0]);
        db.commit();db.setAutoCommit(true);
        assertEquals("MATERIAL_COLOR_OR_UNIT_CONFLICT",scalar("SELECT blocked_reason FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals("0",scalar("SELECT count(*) FROM goods_bom_items WHERE goods_id=?",product));
        amount("0.2",actual(material));
        assertEquals("1",scalar("SELECT count(*) FROM goods_bom_actual_usages WHERE goods_id=?",product));
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
        // production denominator and cannot dilute the usage.
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
        assertNull(state(root));
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
        amount("0.26",actual(material));
        report(supplement,"30",1,false);
        amount("130",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        amount("0.2",bomQty(material));
        assertEquals("1",scalar("SELECT sample_count FROM goods_bom_learning_profiles WHERE goods_id=?",product));
    }

    @Test void pendingWipAndUnitDriftWithdrawTheContributionButNotTheRecipe()throws Exception {
        Batch batch=batch(product,"100","100","20",true);
        db.setAutoCommit(false);
        settlement(batch.demand,"5","REVERSE","CONSUMED");settlement(batch.demand,"5","POST","LEGAL_WIP");
        db.commit();db.setAutoCommit(true);
        amount("0",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertNull(actual(material));
        db.setAutoCommit(false);
        settlement(batch.demand,"5","REVERSE","LEGAL_WIP");settlement(batch.demand,"5","POST","CONSUMED");
        db.commit();db.setAutoCommit(true);
        amount("0.2",actual(material));
        sql("UPDATE production_material_demands SET unit_id=? WHERE id=?",UUID.randomUUID(),batch.demand);
        assertNull(actual(material));
        assertEquals("1",scalar("SELECT count(*) FROM goods_bom_items WHERE NOT is_deleted"));
    }

    @Test void relearningStartsFromNowAndFallsBackToDesignUntilNewDataArrives()throws Exception {
        batch(product,"100","100","20",true);
        amount("0.2",actual(material));
        assertEquals("1",scalar("SELECT fn_relearn_bom_actual_usage(?,?,?)",product,material,UUID.randomUUID()));
        assertNull(actual(material));
        amount("0.2",scalar("SELECT effective_qty FROM v_goods_bom_item_usage u JOIN goods_bom_items b ON b.id=u.bom_item_id WHERE b.goods_id=?",product));
        batch(product,"100","100","30",false);
        amount("0.3",actual(material));
        amount("0.3",bomQty(material));
    }

    @Test void aRuleThatCannotTakeAnAverageIsReportedBeforeMissingData()throws Exception {
        UUID fixed=manualEdge(product,material,"4");
        sql("UPDATE goods_bom_items SET consumption_basis='FIXED_BATCH' WHERE id=?",fixed);
        assertEquals("NOT_LINEAR",scalar("SELECT actual_status FROM v_goods_bom_item_usage WHERE bom_item_id=?",fixed));
        assertEquals("DESIGN",scalar("SELECT usage_basis FROM v_goods_bom_item_usage WHERE bom_item_id=?",fixed));
        assertNull(scalar("SELECT actual_per_unit_qty FROM v_goods_bom_item_usage WHERE bom_item_id=?",fixed));
    }

    /** ADR-129 §2.9: a family counted before the relearn only moves the baseline, whatever happens to it later. */
    @Test void aFamilyFromBeforeTheRelearnNeverLeaksIntoTheNewAverage()throws Exception {
        Batch old=batch(product,"100","100","20",false);
        sql("SELECT fn_relearn_bom_actual_usage(?,?,?)",product,material,UUID.randomUUID());
        sql("UPDATE production_daily_reports SET status=-1 WHERE id=?",old.report);
        assertNull(actual(material));
        batch(product,"100","100","30",false);
        batch(product,"100","100","30",false);
        amount("0.3",actual(material));
        assertWindow("60","200","2");
        // Approved again: still the old process, still outside the new window.
        sql("UPDATE production_daily_reports SET status=1 WHERE id=?",old.report);
        amount("0.3",actual(material));
        assertWindow("60","200","2");
        amount("80",scalar("SELECT net_qty FROM goods_bom_actual_usages WHERE goods_id=?",product));
        // A later correction of the old family moves the baseline only.
        settlement(old.demand,"5","REVERSE","CONSUMED");
        amount("0.3",actual(material));
        assertWindow("60","200","2");
        assertEquals("0",scalar("SELECT count(*) FROM goods_bom_actual_usages WHERE net_qty<baseline_net_qty OR exposure_output_qty<baseline_exposure_output_qty OR sample_count<baseline_sample_count"));
    }

    /** ADR-129 §2.4: on-site materials average over every finished on-site batch, in any finishing order. */
    @Test void onSiteExposureDoesNotDependOnWhichBatchFinishesFirst()throws Exception {
        UUID other=goods("采购");
        Batch first=onSite(material,"100");
        onSite(other,"100");
        amount("0.5",actual(material)); amount("0.5",actual(other));
        assertTrue(scalar("SELECT materials::text FROM production_bom_learning_samples WHERE execution_root_id=?",first.segment).contains(other.toString()));
        // The first family's own next refresh finds nothing new to add.
        String revision=scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",first.segment);
        sql("SELECT fn_enqueue_bom_learning(?)",first.segment);
        assertEquals(revision,scalar("SELECT revision FROM production_bom_learning_samples WHERE execution_root_id=?",first.segment));
        amount("200",scalar("SELECT exposure_output_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,other));
    }

    /** ADR-111 fence: a component deleted while the learned recipe is being created is refused, never linked. */
    @Test void creatingALearnedEdgeWaitsForAConcurrentComponentDeleteAndThenRefuses()throws Exception {
        try(Connection deleter=connection();Connection observer=connection();var pool=Executors.newSingleThreadExecutor()) {
            execute(deleter,"SET search_path TO "+schema+",public");deleter.setAutoCommit(false);
            execute(deleter,"SELECT id FROM goods WHERE id=? FOR UPDATE",material);
            execute(deleter,"UPDATE goods SET is_deleted=TRUE WHERE id=?",material);
            var learning=pool.submit(()->batch(product,"100","100","20",true));
            long deadline=System.nanoTime()+TimeUnit.SECONDS.toNanos(20);
            while(true) {
                try(var statement=observer.createStatement();var rows=statement.executeQuery(
                        "SELECT count(*) FROM pg_locks WHERE NOT granted AND locktype IN('transactionid','tuple')")) {
                    rows.next();if(rows.getInt(1)>0)break;
                }
                assertTrue(System.nanoTime()<deadline,"the learner never waited for the component");
                Thread.sleep(50);
            }
            deleter.commit();
            learning.get(20,TimeUnit.SECONDS);
        }
        assertEquals("MATERIAL_IDENTITY_CHANGED",scalar("SELECT blocked_reason FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        assertEquals("0",scalar("SELECT count(*) FROM goods_bom_items WHERE goods_id=?",product));
    }

    /** Real usage stays per good unit; reported defects only give the per-produced usage and the defect rate. */
    @Test void defectsKeepThePerGoodUsageAndGiveThePerProducedUsageAndTheDefectRate()throws Exception {
        db.setAutoCommit(false);
        Batch batch=batch(product,"100","100","22",false);
        sql("UPDATE production_daily_report_items SET defect_qty=10 WHERE report_id=?",batch.report);
        db.commit();db.setAutoCommit(true);
        amount("0.22",actual(material));
        String window="SELECT %s FROM v_goods_bom_actual_usage WHERE goods_id=? AND component_goods_id=?";
        amount("10",scalar(window.formatted("defect_qty"),product,material));
        amount("0.2",scalar(window.formatted("actual_per_produced_qty"),product,material));
        amount("0.0909",scalar(window.formatted("round(defect_rate,4)"),product,material));
        amount("10",scalar("SELECT total_defect_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        // Changing only the defect count re-teaches the family.
        sql("UPDATE production_daily_report_items SET defect_qty=32 WHERE report_id=?",batch.report);
        amount("0.22",actual(material));
        amount("0.1667",scalar(window.formatted("round(actual_per_produced_qty,4)"),product,material));
        amount("32",scalar("SELECT total_defect_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        // Same figures on the BOM edge.
        String edge="SELECT %s FROM v_goods_bom_item_usage u JOIN goods_bom_items b ON b.id=u.bom_item_id WHERE b.goods_id=?";
        amount("32",scalar(edge.formatted("defect_qty"),product));
        amount("0.2424",scalar(edge.formatted("round(defect_rate,4)"),product));
        // A relearn starts a new defect window too; the old family's later changes stay outside it.
        sql("SELECT fn_relearn_bom_actual_usage(?,?,?)",product,material,UUID.randomUUID());
        sql("UPDATE production_daily_report_items SET defect_qty=40 WHERE report_id=?",batch.report);
        amount("0",scalar(window.formatted("defect_qty"),product,material));
        assertNull(scalar(window.formatted("defect_rate"),product,material));
        db.setAutoCommit(false);
        Batch next=batch(product,"50","50","12",false);
        sql("UPDATE production_daily_report_items SET defect_qty=10 WHERE report_id=?",next.report);
        db.commit();db.setAutoCommit(true);
        amount("0.24",actual(material));
        amount("0.2",scalar(window.formatted("actual_per_produced_qty"),product,material));
        amount("10",scalar(window.formatted("defect_qty"),product,material));
    }

    @Test void concurrentFamiliesSerializeTheSameParentAndKeepExactTotals()throws Exception {
        Batch first=batch(product,"100","50","20",true),second=batch(product,"100","50","40",false);
        try(var pool=Executors.newFixedThreadPool(2)) {
            var a=pool.submit(()->approveSecondHalf(first));var b=pool.submit(()->approveSecondHalf(second));
            a.get(20,TimeUnit.SECONDS);b.get(20,TimeUnit.SECONDS);
        }
        amount("200",scalar("SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?",product));
        amount("0.3",actual(material));assertEquals("2",scalar("SELECT sample_count FROM goods_bom_learning_profiles WHERE goods_id=?",product));
    }

    @Test void touchingTheSameFamilyInTwoOpenTransactionsDoesNotBlockBeforeCommit()throws Exception {
        Batch batch=batch(product,"100","50","20",true);
        try(Connection first=connection();Connection second=connection()) {
            for(Connection connection:List.of(first,second)) {
                execute(connection,"SET search_path TO "+schema+",public");connection.setAutoCommit(false);
            }
            execute(first,"INSERT INTO production_material_stock_postings(demand_id,posting_type,qty_base) VALUES(?,'ISSUE',1)",batch.demand);
            execute(second,"SET lock_timeout='1s'");
            execute(second,"INSERT INTO production_material_stock_postings(demand_id,posting_type,qty_base) VALUES(?,'ISSUE',1)",batch.demand);
            first.rollback();second.rollback();
        }
    }

    @Test void businessResetRetainsAverageAsMasterBaselineAndNewSamplesAppend()throws Exception {
        batch(product,"100","100","20",true);
        // The runtime/ops policy truncates these business samples while keeping
        // the profile, the actual-usage totals and learned master edges.
        sql("TRUNCATE production_bom_learning_samples,production_bom_learning_refresh_queue");
        batch(product,"300","300","90",false);
        amount("0.275",actual(material)); amount("0.275",bomQty(material));
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

    @Test void materialCostFormulaMatchesTheDesignRecipe()throws Exception {
        sql("UPDATE goods SET price=2 WHERE id=?",material);
        manualEdge(product,material,"0.5");
        amount("1",scalar("SELECT fn_goods_bom_material_cost(?)",product));
    }

    @Test void manualPeriodicRecipeDoesNotBlockLearningAnActuallyConsumedOrderInsert()throws Exception {
        UUID pellets=goods("采购");
        sql("UPDATE goods SET issue_method='PERIODIC',periodic_cost_basis='OWN' WHERE id=?",pellets);
        UUID periodic=manualEdge(product,pellets,"0.05");
        sql("UPDATE goods_bom_items SET hard_gate=false WHERE id=?",periodic);
        batch(product,"100","100","100",true);
        amount("1",actual(material));
        amount("1",bomQty(material));
        amount("0.05",bomQty(pellets));
        assertNull(scalar("SELECT learning_profile_goods_id FROM goods_bom_items WHERE id=?",periodic));
    }

    @Test void historicalOrderUseDoesNotPublishAPeriodicRecipeOrBlockTheReportTransaction()throws Exception {
        // An old ORDER demand is fully cleared, but its family still has an
        // unapproved report when the material becomes PERIODIC.
        Batch old=batch(product,"100","50","20",true);
        sql("UPDATE goods SET issue_method='PERIODIC',periodic_cost_basis='OWN' WHERE id=?",material);
        String guard=scalar("SELECT pg_get_functiondef('public.fn_guard_periodic_bom_edge()'::regprocedure)");
        sql(guard.replace("FUNCTION public.","FUNCTION "+schema+"."));
        sql("CREATE TRIGGER periodic_shape BEFORE INSERT OR UPDATE ON goods_bom_items FOR EACH ROW EXECUTE FUNCTION fn_guard_periodic_bom_edge()");
        report(old.segment,"50",1,false);
        amount("0.2",actual(material));
        assertNull(bomQty(material));
        assertEquals("0",scalar("SELECT count(*) FROM production_bom_learning_refresh_queue"));
    }

    @Test void mixedDiscoveryDoesNotTreatPeriodicConsumptionAsZeroOrderConsumption()throws Exception {
        batch(product,"100","100","20",true);
        sql("UPDATE goods SET issue_method='PERIODIC',periodic_cost_basis='OWN' WHERE id=?",material);
        sql("UPDATE goods_bom_items SET hard_gate=false WHERE goods_id=? AND component_goods_id=?",product,material);
        UUID insert=goods("采购");
        onSite(insert,"100");
        // No ORDER demand for pellets in the later mixed batch says nothing
        // about their actual PERIODIC use; preserve the historical observation.
        amount("0.2",actual(material));
        amount("100",scalar("SELECT exposure_output_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,material));
        amount("0.5",actual(insert));
    }

    @Test void newHistoricalPeriodicObservationDoesNotBackfillUnrelatedDiscoveryFamilies()throws Exception {
        batch(product,"100","100","20",true);
        UUID pellets=goods("采购");
        sql("UPDATE goods SET issue_method='PERIODIC',periodic_cost_basis='OWN' WHERE id=?",pellets);
        onSite(pellets,"10");
        amount("0.1",actual(pellets));
        amount("100",scalar("SELECT exposure_output_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,pellets));
        assertNull(bomQty(pellets));
    }

    @Test void manualOrderRecipeStillProtectsItsStructureAlongsidePeriodicWeights()throws Exception {
        manualEdge(product,material,"0.25");
        UUID pellets=goods("采购");
        sql("UPDATE goods SET issue_method='PERIODIC',periodic_cost_basis='OWN' WHERE id=?",pellets);
        UUID periodic=manualEdge(product,pellets,"0.05");
        sql("UPDATE goods_bom_items SET hard_gate=false WHERE id=?",periodic);
        UUID insert=goods("采购");
        onSite(insert,"100");
        amount("1",actual(insert));
        assertNull(bomQty(insert));
        amount("0.25",bomQty(material));
        amount("0.05",bomQty(pellets));
    }

    @Test void forwardRepairWithdrawsOnlyUnsupportedPeriodicZerosAndPreservesRelearnWindow()throws Exception {
        restoreV739LearningFunctions();
        batch(product,"100","100","20",true);
        Batch oldPending=batch(product,"100","50","10",false);
        sql("UPDATE goods SET issue_method='PERIODIC',periodic_cost_basis='OWN' WHERE id=?",material);
        sql("UPDATE goods_bom_items SET hard_gate=false WHERE goods_id=? AND component_goods_id=?",product,material);
        UUID insert=goods("采购");
        Batch mixed=onSite(insert,"100");
        bindPeriodic(mixed.segment,material,0);
        amount("0.1",actual(material)); // V739 incorrectly counted mixed as zero pellets.
        assertNull(bomQty(insert)); // Its manual PERIODIC edge blocked the insert.
        sql("SELECT fn_relearn_bom_actual_usage(?,?,NULL)",product,material);
        report(oldPending.segment,"50",1,false);
        String rawStock=scalar("SELECT sum(qty_base) FROM production_material_stock_postings");
        String rawUse=scalar("SELECT sum(qty_base) FROM production_material_settlement_postings");
        String rawOutput=scalar("SELECT sum(qty) FROM production_daily_report_items");
        amount("0.1",scalar("SELECT actual_qty FROM v_goods_bom_actual_usage WHERE goods_id=? AND component_goods_id=?",product,material));
        applyPeriodicIsolationMigration();
        amount("30",scalar("SELECT net_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,material));
        amount("200",scalar("SELECT exposure_output_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,material));
        amount("100",scalar("SELECT baseline_exposure_output_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,material));
        amount("0.1",scalar("SELECT actual_qty FROM v_goods_bom_actual_usage WHERE goods_id=? AND component_goods_id=?",product,material));
        assertFalse(scalar("SELECT materials::text FROM production_bom_learning_samples WHERE execution_root_id=?",mixed.segment).contains(material.toString()));
        assertTrue(scalar("SELECT entry_generations::text FROM production_bom_learning_samples WHERE execution_root_id=?",mixed.segment).contains(material.toString()));
        assertEquals(rawStock,scalar("SELECT sum(qty_base) FROM production_material_stock_postings"));
        assertEquals(rawUse,scalar("SELECT sum(qty_base) FROM production_material_settlement_postings"));
        assertEquals(rawOutput,scalar("SELECT sum(qty) FROM production_daily_report_items"));
        assertNotNull(bomQty(insert));
        assertEquals("0",scalar("SELECT count(*) FROM production_bom_learning_refresh_queue"));
        // Replaying the same physical facts neither changes the repaired totals
        // nor leaks a withdrawn old-generation exposure into the current window.
        sql("SELECT fn_enqueue_bom_learning(?)",mixed.segment);
        amount("100",scalar("SELECT exposure_output_qty FROM v_goods_bom_actual_usage WHERE goods_id=? AND component_goods_id=?",product,material));
    }

    @Test void forwardRepairPublishesCompletedMixedRecipeWithoutRewritingItsFacts()throws Exception {
        restoreV739LearningFunctions();
        UUID pellets=goods("采购");
        sql("UPDATE goods SET issue_method='PERIODIC',periodic_cost_basis='OWN' WHERE id=?",pellets);
        UUID periodic=manualEdge(product,pellets,"0.05");
        sql("UPDATE goods_bom_items SET hard_gate=false WHERE id=?",periodic);
        Batch completed=batch(product,"100","100","100",true);
        assertNull(bomQty(material));
        String sample=scalar("SELECT row_to_json(sample)::text FROM production_bom_learning_samples sample WHERE execution_root_id=?",completed.segment);
        applyPeriodicIsolationMigration();
        amount("1",bomQty(material));
        amount("0.05",bomQty(pellets));
        assertEquals(sample,scalar("SELECT row_to_json(sample)::text FROM production_bom_learning_samples sample WHERE execution_root_id=?",completed.segment));
    }

    @Test void forwardRepairRemovesUnsupportedPeriodicZeroFromAReopenedFamily()throws Exception {
        restoreV739LearningFunctions();
        batch(product,"100","100","20",true);
        sql("UPDATE goods SET issue_method='PERIODIC',periodic_cost_basis='OWN' WHERE id=?",material);
        sql("UPDATE goods_bom_items SET hard_gate=false WHERE goods_id=? AND component_goods_id=?",product,material);
        UUID insert=goods("采购");
        Batch mixed=onSite(insert,"100");
        bindPeriodic(mixed.segment,material,0);
        report(mixed.segment,"10",0,false);
        assertEquals("PENDING_REPORT",state(mixed));
        amount("0.1",actual(material));
        applyPeriodicIsolationMigration();
        amount("0.2",actual(material));
        amount("0.5",actual(insert));
        assertEquals("PENDING_REPORT",state(mixed));
        assertFalse(scalar("SELECT materials::text FROM production_bom_learning_samples WHERE execution_root_id=?",mixed.segment).contains(material.toString()));
    }

    @Test void forwardRepairAndRefreshPreserveAnEarlierOrderZeroWhenPeriodicBindingStartsLater()throws Exception {
        restoreV739LearningFunctions();
        batch(product,"100","100","20",true);
        UUID insert=goods("采购");
        Batch earlier=onSite(insert,"100");
        amount("0.1",actual(material)); // This zero was a legitimate ORDER observation.
        sql("UPDATE goods SET issue_method='PERIODIC',periodic_cost_basis='OWN' WHERE id=?",material);
        sql("UPDATE goods_bom_items SET hard_gate=false WHERE goods_id=? AND component_goods_id=?",product,material);
        bindPeriodic(earlier.segment,material,1); // The old report predates PERIODIC use.
        applyPeriodicIsolationMigration();
        amount("0.1",actual(material));
        sql("SELECT fn_enqueue_bom_learning(?)",earlier.segment);
        amount("0.1",actual(material));
        amount("200",scalar("SELECT exposure_output_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,material));
        assertTrue(scalar("SELECT materials::text FROM production_bom_learning_samples WHERE execution_root_id=?",earlier.segment).contains(material.toString()));
    }

    @Test void forwardRepairBoundsMixedDateZeroWithoutErasingTheEarlierOrderExposure()throws Exception {
        restoreV739LearningFunctions();
        batch(product,"100","100","20",true);
        UUID insert=goods("采购");
        Batch mixed=onSite(insert,"100");
        sql("UPDATE goods SET issue_method='PERIODIC',periodic_cost_basis='OWN' WHERE id=?",material);
        sql("UPDATE goods_bom_items SET hard_gate=false WHERE goods_id=? AND component_goods_id=?",product,material);
        bindPeriodic(mixed.segment,material,1);
        UUID later=report(mixed.segment,"100",1,false);
        sql("UPDATE production_daily_reports SET bill_date=current_date+1 WHERE id=?",later);
        amount("300",scalar("SELECT exposure_output_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,material));
        applyPeriodicIsolationMigration();
        amount("200",scalar("SELECT exposure_output_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,material));
        amount("0.1",actual(material));
        assertTrue(scalar("SELECT materials::text FROM production_bom_learning_samples WHERE execution_root_id=?",mixed.segment).contains(material.toString()));
    }

    private void bindPeriodic(UUID segment,UUID component,int daysFromToday)throws Exception {
        sql("INSERT INTO production_execution_periodic_materials(execution_segment_id,bin_warehouse_id,material_goods_id,unit_id,origin,effective_from) VALUES(?,?,?,?,'CHOICE',current_date+?)",
                segment,UUID.randomUUID(),component,unit,daysFromToday);
    }

    @Test void preservedHistoricalZeroShrinksAfterPartialOutputReversalWithoutLeakingPastRelearn()throws Exception {
        restoreV739LearningFunctions();
        batch(product,"100","100","20",true);
        UUID insert=goods("采购");
        Batch earlier=onSite(insert,"100");
        sql("UPDATE production_daily_report_items SET defect_qty=10 WHERE report_id=?",earlier.report);
        sql("SELECT fn_relearn_bom_actual_usage(?,?,NULL)",product,material);
        sql("UPDATE goods SET issue_method='PERIODIC',periodic_cost_basis='OWN' WHERE id=?",material);
        sql("UPDATE goods_bom_items SET hard_gate=false WHERE goods_id=? AND component_goods_id=?",product,material);
        bindPeriodic(earlier.segment,material,1);
        applyPeriodicIsolationMigration();
        // Later PERIODIC output keeps the family total above the old exposure;
        // it must not hide a reversal of the earlier ORDER report.
        UUID later=report(earlier.segment,"100",1,false);
        sql("UPDATE production_daily_reports SET bill_date=current_date+1 WHERE id=?",later);
        sql("UPDATE production_daily_report_items SET defect_qty=20 WHERE report_id=?",later);
        // The family stays closed via its explicit final report, but some
        // previously approved output and defects have been disproven.
        sql("UPDATE production_daily_report_items SET qty=50,defect_qty=4,is_final=true WHERE report_id=?",earlier.report);
        assertEquals("READY",state(earlier));
        amount("150",scalar("SELECT exposure_output_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,material));
        amount("150",scalar("SELECT baseline_exposure_output_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,material));
        amount("4",scalar("SELECT exposure_defect_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,material));
        amount("4",scalar("SELECT baseline_exposure_defect_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,material));
        amount("0",scalar("SELECT exposure_output_qty FROM v_goods_bom_actual_usage WHERE goods_id=? AND component_goods_id=?",product,material));
        assertNull(scalar("SELECT actual_qty FROM v_goods_bom_actual_usage WHERE goods_id=? AND component_goods_id=?",product,material));
    }

    private void restoreV739LearningFunctions()throws Exception {
        String migration=migrationText("V739__bom_design_and_actual_usage.sql");
        for(String name:List.of("fn_publish_learned_bom","fn_refresh_bom_learning","fn_drain_bom_learning_queue")) {
            int start=migration.indexOf("CREATE FUNCTION "+name+"(");
            int end=migration.indexOf("END $$;",start)+"END $$;".length();
            assertTrue(start>=0&&end>start,name);
            sql(migration.substring(start,end).replace("CREATE FUNCTION "+name+"(","CREATE OR REPLACE FUNCTION "+schema+"."+name+"("));
        }
    }
    private void applyPeriodicIsolationMigration()throws Exception {
        sql(migrationText("V789__bom_learning_periodic_material_isolation.sql"));
    }
    private String migrationText(String name)throws Exception {
        try(var stream=getClass().getResourceAsStream("/db/migration/"+name)) {
            assertNotNull(stream,name);
            return new String(stream.readAllBytes(),StandardCharsets.UTF_8).replace("\r\n","\n");
        }
    }

    private void assertWindow(String net,String exposure,String samples)throws Exception {
        String window="SELECT %s FROM v_goods_bom_actual_usage WHERE goods_id=? AND component_goods_id=?";
        amount(net,scalar(window.formatted("net_qty"),product,material));
        amount(exposure,scalar(window.formatted("exposure_output_qty"),product,material));
        assertEquals(samples,scalar(window.formatted("sample_count"),product,material));
    }
    /** A finished on-site batch of 100 that used only the given material. */
    private Batch onSite(UUID component,String consumed)throws Exception {
        db.setAutoCommit(false);
        UUID segment=UUID.randomUUID();segment(segment,product,"100",true,null);
        UUID[] materialIds=addMaterial(segment,component,consumed);
        UUID report=report(segment,"100",1,false);
        db.commit();db.setAutoCommit(true);
        return new Batch(segment,materialIds[0],report,materialIds[1],materialIds[2]);
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
    private UUID manualEdge(UUID parent,UUID component,String qty)throws Exception {
        UUID id=UUID.randomUUID();
        sql("INSERT INTO goods_bom_items(id,goods_id,component_goods_id,qty) VALUES(?,?,?,?)",id,parent,component,new BigDecimal(qty));return id;
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
        UUID id=UUID.randomUUID();sql("INSERT INTO production_daily_reports(id,status,is_deleted,bill_date) VALUES(?,?,false,current_date)",id,status);
        sql("INSERT INTO production_daily_report_items(report_id,execution_segment_id,goods_id,unit_id,unit_rate,qty,is_final,is_deleted) VALUES(?,?,?,?,1,?,?,false)",id,segment,product,unit,new BigDecimal(qty),finished);return id;
    }
    private String state(Batch batch)throws Exception{return scalar("SELECT state FROM production_bom_learning_samples WHERE execution_root_id=?",batch.segment);}
    private String bomQty(UUID component)throws Exception{return scalar("SELECT qty FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",product,component);}
    private String actual(UUID component)throws Exception{return scalar("SELECT actual_qty FROM goods_bom_actual_usages WHERE goods_id=? AND component_goods_id=?",product,component);}
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
