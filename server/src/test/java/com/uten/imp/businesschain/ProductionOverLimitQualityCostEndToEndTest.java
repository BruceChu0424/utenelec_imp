package com.uten.imp.businesschain;

import com.uten.imp.application.port.InventoryProductionCostPort;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.ProductionOverLimitDispositionService;
import com.uten.imp.features.production.dailyreport.ProductionOverLimitDispositionContracts.DecisionRequest;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import com.uten.imp.features.production.quality.ProductionFqcInspectionService;
import com.uten.imp.features.production.quality.ProductionFqcContracts.LotDecisionRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.warehouse.finishedin.FinishedArrivalTestSupport;
import com.uten.imp.features.warehouse.finishedin.ProductionFinishedArrivalRegistrationService;
import com.uten.imp.support.DailyReportApproveRequests;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Real report -> whole-lot FQC -> held excess -> disposition -> receipt -> cost. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionOverLimitQualityCostEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionDailyReportService reports;
    @Autowired ProductionOverLimitDispositionService dispositions;
    @Autowired ProductionFinishedArrivalRegistrationService arrivals;
    @Autowired ProductionFqcInspectionService quality;
    @Autowired InventoryProductionCostPort costs;
    @Autowired StockDocService stock;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void passBeforePlanningReleasesElevenHundredAndKeepsTheLastHundredAndItsCostHeld(){
        Scenario s=report1200(false);
        quality.decideLot(s.lot(),new LotDecisionRequest(new BigDecimal("1200"),BigDecimal.ZERO,null,null,"pass-"+s.report()));
        amount("1200",scalar("SELECT SUM(passed_qty) FROM production_fqc_inspections WHERE source_report_id=?",s.report()));
        amount("1100",draftQty(s.report()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_document_items WHERE source_daily_report_item_id=?",Integer.class,s.excess()));
        var bypass=assertThrows(org.springframework.dao.DataAccessException.class,()->db.update("""
                INSERT INTO stock_document_items
                SELECT (jsonb_populate_record(NULL::stock_document_items,to_jsonb(item)||jsonb_build_object(
                    'id',CAST(? AS text),'line_no',99,'qty',100,'reported_qty',100,'base_qty',100,
                    'source_daily_report_item_id',CAST(? AS text),'execution_segment_sales_allocation_id',NULL))).*
                FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id
                WHERE document.source_daily_report_id=? AND document.doc_type='FINISHED_IN'
                  AND NOT item.is_deleted ORDER BY item.line_no LIMIT 1
                """,UUID.randomUUID(),s.excess(),s.report()));
        assertTrue(String.valueOf(bypass.getMostSpecificCause().getMessage()).contains("超限产出尚未批准接收"),
                bypass.getMostSpecificCause().getMessage());
        s.fixture().fixture.confirmFinishedInboundFully(drafts(s.report()).getFirst());
        amount("1100",balance(s));
        assertTrue(db.queryForObject("SELECT fn_production_execution_has_pending_output(?)",Boolean.class,s.segment()));
        ReflectionTestUtils.invokeMethod(s.fixture(),"drainValuation",s.task());
        var held=costs.position(s.segment());
        amount("10000",held.actualKnownCostLocal());
        amount("9166.6667",held.allocatedToOutputsLocal());
        amount("833.3333",held.heldWipLocal());
        assertNotEquals("FINAL",db.queryForObject("SELECT state FROM stock_value_production_cost_objects WHERE execution_segment_id=?",String.class,s.segment()));

        var pending=dispositions.detail(s.caseId());
        var approval=new DecisionRequest("ACCEPT_PUBLIC","整批超限接收为公共备货",pending.rowVersion(),"accept-"+s.report());
        assertEquals("ACCEPTED",dispositions.decide(s.caseId(),approval).status());
        assertEquals("ACCEPTED",dispositions.decide(s.caseId(),approval).status());
        amount("100",draftQty(s.report()));
        amount("1100",balance(s));
        assertEquals(2,db.queryForObject("SELECT count(*) FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND NOT is_deleted",Integer.class,s.report()));
        s.fixture().fixture.confirmFinishedInboundFully(drafts(s.report()).getFirst());
        ReflectionTestUtils.invokeMethod(s.fixture(),"drainValuation",s.task());
        amount("1200",balance(s));
        amount("1200",scalar("SELECT fn_production_execution_cost_target(?)",s.segment()));
        amount("1000",scalar("SELECT planned_qty FROM production_execution_segments WHERE id=?",s.segment()));
        amount("0.1",scalar("SELECT allowed_overproduction_rate FROM production_execution_segments WHERE id=?",s.segment()));
        var complete=costs.position(s.segment());
        amount("10000",complete.actualKnownCostLocal());amount("10000",complete.allocatedToOutputsLocal());amount("0",complete.heldWipLocal());
        for(UUID doc:db.queryForList("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND status=1 AND NOT is_deleted ORDER BY bill_no DESC",UUID.class,s.report())){
            stock.reverseFinishedInbound(doc);
            ReflectionTestUtils.invokeMethod(s.fixture(),"drainValuation",s.task());
        }
        reports.reverse(s.report());
        amount("0",balance(s));
        amount("1000",scalar("SELECT fn_production_execution_cost_target(?)",s.segment()));
        assertEquals("WITHDRAWN",dispositions.detail(s.caseId()).status());
    }

    @Test void planningBeforeInspectionKeepsOnePhysicalLotAndOnePrestockedReceipt(){
        Scenario s=report1200(true);
        var pending=dispositions.detail(s.caseId());
        dispositions.decide(s.caseId(),new DecisionRequest("ACCEPT_PUBLIC","已核对整批接收",pending.rowVersion(),"early-"+s.report()));
        amount("0",balance(s));
        assertEquals(0,drafts(s.report()).size());
        quality.decideLot(s.lot(),new LotDecisionRequest(new BigDecimal("1200"),BigDecimal.ZERO,null,null,"early-pass-"+s.report()));
        amount("1200",balance(s));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND status=1 AND NOT is_deleted",Integer.class,s.report()));
    }

    @Test void delayedPlanningCannotReuseAnOldPrestockCountAsFreshReceiptForHeldOutput(){
        Scenario s=report1200(true);
        quality.decideLot(s.lot(),new LotDecisionRequest(new BigDecimal("1200"),BigDecimal.ZERO,null,null,"held-prestock-pass-"+s.report()));
        amount("1100",balance(s));amount("0",draftQty(s.report()));
        var pending=dispositions.detail(s.caseId());
        dispositions.decide(s.caseId(),new DecisionRequest("ACCEPT_PUBLIC","暂存超限产品已批准接收",pending.rowVersion(),"held-prestock-accept-"+s.report()));
        amount("1100",balance(s));amount("100",draftQty(s.report()));
        s.fixture().fixture.confirmFinishedInboundFully(drafts(s.report()).getFirst());
        amount("1200",balance(s));
    }

    @Test void wholeLotFailureConsumesTheHeldExcessBeforeAuthorizedOutput(){
        Scenario s=report1200(false);
        quality.decideLot(s.lot(),new LotDecisionRequest(new BigDecimal("1100"),new BigDecimal("100"),"SCRAP","超限尾批质量不合格","failure-"+s.report()));
        amount("1100",draftQty(s.report()));
        amount("100",scalar("SELECT failed_qty FROM production_fqc_inspections WHERE source_report_item_id=?",s.excess()));
        amount("0",scalar("SELECT passed_qty FROM production_fqc_inspections WHERE source_report_item_id=?",s.excess()));
        var pending=dispositions.detail(s.caseId());
        dispositions.decide(s.caseId(),new DecisionRequest("ACCEPT_PUBLIC","只批准接收，不能把不良变合格",pending.rowVersion(),"failed-accept-"+s.report()));
        amount("1100",draftQty(s.report()));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM stock_document_items WHERE source_daily_report_item_id=?",Integer.class,s.excess()));
    }

    @Test void approvingOriginalExcessAlsoReleasesItsAlreadyInspectedRecoveryWithoutDuplicatingCostBasis(){
        Scenario s=report1200(false);
        quality.decideLot(s.lot(),new LotDecisionRequest(new BigDecimal("1100"),new BigDecimal("100"),"REWORK","超限尾批返工后重新送检","rework-"+s.report()));
        List<ReportablePlanLine> sources=ReflectionTestUtils.invokeMethod(s.fixture(),"sources",s.task());
        ReportablePlanLine recovery=sources.stream().filter(row->row.fqcRecoveryAuthorizationId()!=null).findFirst().orElseThrow();
        DailyReportSaveRequest request=ReflectionTestUtils.invokeMethod(s.fixture(),"reportRequest",s.task(),recovery,"100","0");
        UUID recoveryReport=reports.approve(reports.create(request).getId(),DailyReportApproveRequests.freshKey()).getId();
        UUID recoveryItem=db.queryForObject("SELECT id FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",UUID.class,recoveryReport);
        assertTrue(db.queryForObject("SELECT is_over_limit FROM production_daily_report_items WHERE id=?",Boolean.class,recoveryItem));
        assertEquals(s.excess(),db.queryForObject("SELECT fn_daily_report_output_authorization_root(?)",UUID.class,recoveryItem));
        FinishedArrivalTestSupport.registerAll(arrivals,recoveryReport,"recovery-arrival-"+recoveryReport,s.warehouse(),"返工实物暂存",null,false);
        UUID recoveryLot=db.queryForObject("SELECT output_lot_id FROM production_daily_report_items WHERE id=?",UUID.class,recoveryItem);
        quality.decideLot(recoveryLot,new LotDecisionRequest(new BigDecimal("100"),BigDecimal.ZERO,null,null,"recovery-pass-"+recoveryReport));
        amount("0",draftQty(recoveryReport));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_over_limit_dispositions WHERE report_item_id=?",Integer.class,recoveryItem));
        var pending=dispositions.detail(s.caseId());
        dispositions.decide(s.caseId(),new DecisionRequest("ACCEPT_PUBLIC","原批超限及其返工恢复一并接收",pending.rowVersion(),"recovery-accept-"+s.report()));
        amount("100",draftQty(recoveryReport));
        amount("1200",scalar("SELECT fn_production_execution_cost_target(?)",s.segment()));
        s.fixture().fixture.confirmFinishedInboundFully(drafts(s.report()).getFirst());
        s.fixture().fixture.confirmFinishedInboundFully(drafts(recoveryReport).getFirst());
        amount("1200",balance(s));
    }

    @SuppressWarnings("unchecked")
    private Scenario report1200(boolean preStocked){
        var fixture=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(fixture);fixture.prepare();
        Object task=ReflectionTestUtils.invokeMethod(fixture,"createStartedTask","overlimit-quality-"+UUID.randomUUID(),false,"1000");
        List<ReportablePlanLine> sources=ReflectionTestUtils.invokeMethod(fixture,"sources",task);
        DailyReportSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"reportRequest",task,sources.getFirst(),"1200","1000");
        request.getItems().getFirst().setOverLimitReason("整模尾批已完成，实物如实登记");
        UUID report=reports.approve(reports.create(request).getId(),DailyReportApproveRequests.freshKey()).getId();
        UUID excess=db.queryForObject("SELECT id FROM production_daily_report_items WHERE report_id=? AND is_over_limit AND NOT is_deleted",UUID.class,report);
        UUID segment=ReflectionTestUtils.invokeMethod(task,"segment");
        UUID product=ReflectionTestUtils.invokeMethod(task,"product");
        Object world=ReflectionTestUtils.invokeMethod(task,"world");
        UUID warehouse=ReflectionTestUtils.invokeMethod(world,"warehouseId");
        UUID lot=db.queryForObject("SELECT output_lot_id FROM production_daily_report_items WHERE id=?",UUID.class,excess);
        UUID caseId=db.queryForObject("SELECT id FROM production_over_limit_dispositions WHERE report_item_id=?",UUID.class,excess);
        amount("1200",scalar("SELECT SUM(qty) FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",report));
        assertEquals(3,db.queryForObject("SELECT count(*) FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",Integer.class,report));
        FinishedArrivalTestSupport.registerAll(arrivals,report,"arrival-"+report,warehouse,"超限实物隔离暂存",null,preStocked);
        return new Scenario(fixture,task,report,segment,product,warehouse,excess,lot,caseId);
    }
    private List<UUID> drafts(UUID report){return db.queryForList("SELECT id FROM stock_documents WHERE source_daily_report_id=? AND doc_type='FINISHED_IN' AND status=0 AND NOT is_deleted ORDER BY bill_no",UUID.class,report);}
    private BigDecimal draftQty(UUID report){return scalar("SELECT COALESCE(SUM(item.qty),0) FROM stock_document_items item JOIN stock_documents document ON document.id=item.doc_id WHERE document.source_daily_report_id=? AND document.doc_type='FINISHED_IN' AND document.status=0 AND NOT document.is_deleted AND NOT item.is_deleted",report);}
    private BigDecimal balance(Scenario s){return db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE warehouse_id=? AND goods_id=?",BigDecimal.class,s.warehouse(),s.product());}
    private BigDecimal scalar(String sql,Object arg){return db.queryForObject(sql,BigDecimal.class,arg);}
    private static void amount(String expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+", got "+actual);}
    private record Scenario(WorkshopPublicSurplusEndToEndTest fixture,Object task,UUID report,UUID segment,UUID product,UUID warehouse,UUID excess,UUID lot,UUID caseId){}
}
