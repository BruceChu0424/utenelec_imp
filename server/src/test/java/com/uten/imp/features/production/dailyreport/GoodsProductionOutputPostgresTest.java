package com.uten.imp.features.production.dailyreport;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.GoodsProductionOutputQueryPort.Query;
import com.uten.imp.features.production.ProductionDocumentAccessPolicy;
import com.uten.imp.security.OwnerVisibility.OwnerScope;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.containers.PostgreSQLContainer;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

/** Real query SQL with the repository's exact family functions and workbench progress expression.
 * Deliberately has no inventory/valuation tables: approved workshop progress must not depend on receipts.
 * Full schema/Spring/permission routing is separately exercised by GoodsCostHttpSmokeEndToEndTest.
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class GoodsProductionOutputPostgresTest {
    static final PostgreSQLContainer<?> POSTGRES=new PostgreSQLContainer<>("postgres:16-alpine");
    static JdbcTemplate db;
    GoodsProductionOutputQueryService service;
    ProductionDocumentAccessPolicy access;
    final UUID goods=UUID.randomUUID(),unit=UUID.randomUUID(),owner=UUID.randomUUID();
    @BeforeAll static void database() throws Exception {
        POSTGRES.start();var data=new DriverManagerDataSource(POSTGRES.getJdbcUrl(),POSTGRES.getUsername(),POSTGRES.getPassword());
        db=new JdbcTemplate(data);
        // Keep the query-only isolation, but take actual column types/defaults/keys from
        // current migrations rather than creating new hand-written schema debt.
        com.uten.imp.support.MigratedProjectionSchema.createCurrentTables(db,
                "units", "production_plans", "production_execution_segments",
                "production_execution_segment_splits", "production_actual_output_supplement_proofs",
                "production_actual_output_supplement_reversals", "production_daily_reports",
                "production_daily_report_commands", "production_daily_report_items",
                "production_fqc_contribution_adjustments");
        String family=resource("V701__actual_supplement_material_and_cost_scope.sql");
        for(String name:List.of("fn_production_execution_cost_scope","fn_production_execution_cost_members")) {
            int start=family.indexOf(name.equals("fn_production_execution_cost_scope")?"CREATE OR REPLACE FUNCTION "+name:"CREATE FUNCTION "+name);
            db.execute(family.substring(start,family.indexOf("$$;",start)+3));
        }
        String workbench=resource("V696__actual_output_workbench_progress.sql");
        int expression=workbench.indexOf("    SELECT SUM(item.qty) FILTER");
        String progress=workbench.substring(expression,workbench.indexOf(") progress ON TRUE",expression));
        db.execute("CREATE VIEW v_production_execution_workbench_segments AS SELECT segment.id segment_id,"
                +"COALESCE(progress.effective_reported_qty,0) reported_qty FROM production_execution_segments segment LEFT JOIN LATERAL ("
                +progress+") progress ON TRUE");
    }
    private static String resource(String name) throws Exception {
        try(var input=GoodsProductionOutputPostgresTest.class.getResourceAsStream("/db/migration/"+name)) {
            assertThat(input).isNotNull();return new String(input.readAllBytes(),StandardCharsets.UTF_8);
        }
    }
    @AfterAll static void stop(){POSTGRES.stop();}
    @BeforeEach void setup(){
        db.execute("TRUNCATE units,production_plans,production_execution_segments,production_execution_segment_splits,"
                +"production_actual_output_supplement_proofs,production_actual_output_supplement_reversals,production_daily_reports,"
                +"production_daily_report_commands,production_daily_report_items,production_fqc_contribution_adjustments");
        db.update("INSERT INTO units(id,name) VALUES(?,?)",unit,"箱");
        access=mock(ProductionDocumentAccessPolicy.class);when(access.scope()).thenReturn(new OwnerScope(true,Set.of()));
        service=new GoodsProductionOutputQueryService(new NamedParameterJdbcTemplate(db),access);
    }
    @Test void noApprovedReportIsUnknownRatherThanZeroAndDoesNotCreateAnything(){
        UUID scope=segment("ZX-DRAFT");report(scope,0,"2026-09-30","999","8",null);
        var summary=service.summary(new Query(goods,null));
        assertThat(summary.state()).isEqualTo("NONE");assertThat(summary.effectiveCompletedQty()).isNull();
        assertThat(summary.scopeId()).isNull();assertThat(db.queryForObject("SELECT count(*) FROM production_daily_report_items",Integer.class)).isEqualTo(1);
    }
    @Test void approvedUnreceivedProductionUsesOriginalReportUnitAndExactStrings() throws Exception {
        UUID scope=segment("ZX-BOX");report(scope,1,"2026-09-29","2.1234","0.5",null);
        var summary=service.summary(new Query(goods,null));
        assertThat(summary.scopeId()).isEqualTo(scope);assertThat(summary.state()).isEqualTo("IN_PROGRESS");
        assertThat(summary.unitName()).isEqualTo("箱");assertThat(summary.effectiveCompletedQty()).isEqualByComparingTo("2.1234");
        assertThat(summary.reportedDefectQty()).isEqualByComparingTo("0.5");assertThat(summary.lastReportUpdatedAt()).isNotNull();
        var json=new ObjectMapper().findAndRegisterModules().valueToTree(summary);
        assertThat(json.path("effectiveCompletedQty").isTextual()).isTrue();assertThat(json.path("effectiveCompletedQty").asText()).isEqualTo("2.1234");
        assertThat(db.queryForObject("SELECT to_regclass('stock_value_production_cost_objects') IS NULL",Boolean.class)).isTrue();
    }
    @Test void summaryJsonRetainsExactDecimalStringsBeyondReportingStorageScale() throws Exception {
        BigDecimal exact=new BigDecimal("2.1234567891");
        var summary=new com.uten.imp.application.port.GoodsProductionOutputQueryPort.Summary(
                goods,"READY","EXPLICIT_EXECUTION_SCOPE",UUID.randomUUID(),"ZX-EXACT",null,null,null,unit,"箱",
                exact,exact,BigDecimal.ZERO,BigDecimal.ZERO,1,1,false,List.of("APPROVED_DAILY_REPORT"),List.of());
        var json=new ObjectMapper().findAndRegisterModules().valueToTree(summary);
        assertThat(json.path("effectiveCompletedQty").isTextual()).isTrue();
        assertThat(json.path("effectiveCompletedQty").asText()).isEqualTo("2.1234567891");
    }
    @Test void familyCountsDisjointDestinationsPublicOutputAndFqcRecoveryWithoutDoubleCounting(){
        UUID root=segment("ZX-ROOT"),first=segment("ZX-1"),second=segment("ZX-2"),extra=segment("ZX-PLUS");
        db.update("UPDATE production_execution_segments SET source_segment_id=?,split_root_segment_id=? WHERE id IN (?,?)",root,root,first,second);
        db.update("INSERT INTO production_execution_segment_splits(source_segment_id,batch_segment_id,remaining_segment_id) VALUES(?,?,?)",root,first,second);
        db.update("INSERT INTO production_actual_output_supplement_proofs(id,source_execution_segment_id,supplement_execution_segment_id) VALUES(?,?,?)",UUID.randomUUID(),first,extra);
        UUID r=report(first,1,"2026-09-29","60","3",null),item=db.queryForObject("SELECT id FROM production_daily_report_items WHERE report_id=?",UUID.class,r);
        UUID batch=UUID.randomUUID();db.update("UPDATE production_daily_report_items SET output_batch_id=?,output_batch_qty=100,destination='WORKSHOP' WHERE id=?",batch,item);
        line(r,first,"40","0",null);
        db.update("UPDATE production_daily_report_items SET output_batch_id=?,output_batch_qty=100,is_public_output=true WHERE report_id=? AND id<>?",batch,r,item);
        db.update("INSERT INTO production_fqc_contribution_adjustments(source_report_item_id,adjusted_qty) VALUES(?,10)",item);
        report(first,1,"2026-09-30","10","9",UUID.randomUUID()); // recovery is already offset by original FQC deduction; its defects are not initial production defects
        report(second,1,"2026-09-29","20","1",null);report(extra,1,"2026-09-30","5","0",null);
        report(second,0,"2026-10-01","700","7",null);report(extra,-1,"2026-10-02","800","8",null);
        var summary=service.summary(new Query(goods,extra));
        assertThat(summary.scopeId()).isEqualTo(root);assertThat(summary.memberCount()).isEqualTo(4);
        assertThat(summary.approvedReportCount()).isEqualTo(4);assertThat(summary.hasDraftReports()).isTrue();
        assertThat(summary.approvedReportedQty()).isEqualByComparingTo("135");assertThat(summary.fqcDeductedQty()).isEqualByComparingTo("10");
        assertThat(summary.effectiveCompletedQty()).isEqualByComparingTo("125");assertThat(summary.reportedDefectQty()).isEqualByComparingTo("4");
    }
    @Test void latestSelectsApprovalFactWithinBusinessDateAndWithdrawalFallsBack(){
        UUID older=segment("ZX-OLD"),newer=segment("ZX-NEW");UUID oldReport=report(older,1,"2026-09-29","10","0",null);
        UUID newReport=report(newer,1,"2026-09-29","3","0",null);
        db.update("INSERT INTO production_daily_report_commands(report_id,command_kind,created_at) VALUES(?,'APPROVE','2026-09-29T10:00Z'),(?,'APPROVE','2026-09-29T11:00Z')",oldReport,newReport);
        db.update("UPDATE production_daily_reports SET updated_at='2026-10-10' WHERE id=?",oldReport);
        assertThat(service.summary(new Query(goods,null)).scopeId()).isEqualTo(newer);
        db.update("UPDATE production_daily_reports SET status=-1 WHERE id=?",newReport);
        assertThat(service.summary(new Query(goods,null)).scopeId()).isEqualTo(older);
        db.update("UPDATE production_daily_reports SET status=-1 WHERE id=?",oldReport);
        assertThat(service.summary(new Query(goods,null)).state()).isEqualTo("NONE");
    }
    @Test void mixedOrMissingFrozenUnitsNeverProducePartialQuantities(){
        UUID scope=segment("ZX-UNIT");report(scope,1,"2026-09-29","4","1",null);
        db.update("UPDATE production_daily_report_items SET unit_rate=1");
        var mixed=service.summary(new Query(goods,null));assertThat(mixed.state()).isEqualTo("PENDING_UNIT");assertThat(mixed.effectiveCompletedQty()).isNull();
        db.update("UPDATE production_daily_report_items SET unit_rate=10");db.update("UPDATE production_execution_segments SET product_unit_id=NULL");
        assertThat(service.summary(new Query(goods,null)).state()).isEqualTo("PENDING_UNIT");
    }
    @Test void explicitWrongGoodsRejectedWithoutReturningAnotherProduct(){
        UUID scope=segment("ZX-GOODS");report(scope,1,"2026-09-29","4","1",null);
        assertThatThrownBy(()->service.summary(new Query(UUID.randomUUID(),scope))).hasMessageContaining("不匹配");
    }
    @Test void finishedScopeIsReadyAndInaccessibleMemberCannotBecomePartialFamily(){
        UUID root=segment("ZX-ROOT"),child=segment("ZX-CHILD");report(root,1,"2026-09-29","4","0",null);
        db.update("UPDATE production_execution_segments SET status='COMPLETED'");
        assertThat(service.summary(new Query(goods,null)).state()).isEqualTo("READY");
        db.update("INSERT INTO production_actual_output_supplement_proofs(id,source_execution_segment_id,supplement_execution_segment_id) VALUES(?,?,?)",UUID.randomUUID(),root,child);
        db.update("UPDATE production_plans SET maker_id=? WHERE id=(SELECT plan_id FROM production_execution_segments WHERE id=?)",UUID.randomUUID(),child);
        when(access.scope()).thenReturn(new OwnerScope(false,Set.of(owner)));
        assertThat(service.summary(new Query(goods,null)).state()).isEqualTo("NONE");
    }
    UUID segment(String code){UUID id=UUID.randomUUID(),plan=UUID.randomUUID();
        db.update("INSERT INTO production_plans(id,maker_id) VALUES(?,?)",plan,owner);
        db.update("INSERT INTO production_execution_segments(id,plan_id,segment_code,product_goods_id,product_unit_id,product_unit_rate,status) VALUES(?,?,?,?,?,10,'IN_PROGRESS')",id,plan,code,goods,unit);return id;}
    UUID report(UUID segment,int status,String date,String qty,String defect,UUID recovery){UUID id=UUID.randomUUID();
        db.update("INSERT INTO production_daily_reports(id,bill_date,status,maker_id) VALUES(?,?,?,?)",id,LocalDate.parse(date),status,owner);
        line(id,segment,qty,defect,recovery);return id;}
    void line(UUID report,UUID segment,String qty,String defect,UUID recovery){
        db.update("INSERT INTO production_daily_report_items(id,report_id,execution_segment_id,goods_id,unit_id,unit_rate,qty,defect_qty,fqc_recovery_authorization_id) VALUES(?,?,?,?,?,10,?,?,?)",
                UUID.randomUUID(),report,segment,goods,unit,new BigDecimal(qty),new BigDecimal(defect),recovery);}
}
