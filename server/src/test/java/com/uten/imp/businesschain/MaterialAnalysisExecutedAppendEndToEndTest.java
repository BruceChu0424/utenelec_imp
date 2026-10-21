package com.uten.imp.businesschain;

import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.BatchResult;
import com.uten.imp.features.production.analysis.AggregateMaterialOrderContracts.GroupInput;
import com.uten.imp.features.production.dailyreport.dto.DailyReportMaterialUsageLine;
import com.uten.imp.features.production.execution.ProductionDrawRequest;
import com.uten.imp.features.production.execution.ProductionDrawRequestService;
import com.uten.imp.features.production.execution.ProductionExecutionSegmentService;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static com.uten.imp.businesschain.AggregateMaterialOrderEndToEndTest.amount;
import static org.junit.jupiter.api.Assertions.*;

/** A real draw/start/report is an append boundary; old quantities and identities are immutable. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class MaterialAnalysisExecutedAppendEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry) {
        FullChainEndToEndTest.registerDataSource(registry);
    }
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired ProductionDrawRequestService draws;
    @Autowired StockDocService stocks;
    @Autowired ProductionExecutionSegmentService segments;
    AggregateMaterialOrderEndToEndTest h;
    @BeforeEach void before() { h=new AggregateMaterialOrderEndToEndTest();beans.autowireBean(h);h.before(); }
    @AfterEach void after() { h.after(); }

    @ParameterizedTest @ValueSource(strings={"DRAW_SUBMITTED","STARTED","PARTIAL_INBOUND"})
    void appendCreatesAnIndependentTwentyAfterExecutionAndKeepsTheOriginalHundred(String phase) {
        var c=h.create(true,false,"100",false,1,"1");var w=c.world();
        h.fixture.receiveSubcontractMaterial(w,c.material(),"120");
        GroupInput firstInput=input(c,"100",false);
        UUID originalMaterial=firstInput.materialLineIds().getFirst();
        BatchResult first=h.writer.submit(c.analysis(),h.command(c,List.of(firstInput)))
                .batches().getFirst();
        UUID originalSegment=h.db.queryForObject("SELECT id FROM production_execution_segments WHERE plan_id=? AND NOT is_deleted",UUID.class,first.planId());
        String originalCode=h.db.queryForObject("SELECT segment_code FROM production_execution_segments WHERE id=?",String.class,originalSegment);
        UUID originalDemand=h.db.queryForObject("SELECT id FROM production_material_demands WHERE execution_segment_id=? AND NOT is_deleted",UUID.class,originalSegment);
        var item=new ProductionDrawRequest.Item(originalSegment,version(originalSegment));
        var preview=draws.preview(new ProductionDrawRequest.PreviewRequest(List.of(item)));
        draws.submit(new ProductionDrawRequest.SubmitRequest(List.of(item),"append-draw-"+originalSegment,preview.fingerprint()));
        if(!"DRAW_SUBMITTED".equals(phase)) {
            for(UUID document:preview.lines().stream().map(ProductionDrawRequest.Line::drawId).distinct().toList()) {
                var issue=new StockDocIssueRequest();issue.setIdempotencyKey("append-issue-"+document);
                issue.setLines(preview.lines().stream().filter(row->document.equals(row.drawId())).map(row->{
                    var line=new StockDocIssueRequest.Line();line.setItemId(row.drawItemId());line.setQty(row.qty());return line;
                }).toList());
                stocks.approveAndIssue(document,issue);
            }
            segments.start(first.planId(),originalSegment,new SegmentTransitionRequest(version(originalSegment),"append-start-"+originalSegment));
        }
        if("PARTIAL_INBOUND".equals(phase)) {
            UUID planItem=h.db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",UUID.class,first.planId());
            var usage=new DailyReportMaterialUsageLine();usage.setDemandId(originalDemand);usage.setQtyBase(new BigDecimal("30"));
            UUID report=h.fixture.reportAndApproveExecutionSegment(w,planItem,null,c.common(),originalSegment,null,
                    "30",false,"0",null,null,List.of(usage));
            for(UUID inbound:h.db.queryForList("SELECT id FROM stock_documents WHERE doc_type='FINISHED_IN' AND source_daily_report_id=? AND NOT is_deleted",UUID.class,report))
                h.fixture.confirmFinishedInboundFully(inbound);
        }
        h.fixture.loginAs(w.superAdminUserId());

        var command=h.command(c,List.of(input(c,"20",true)));
        var added=h.writer.submit(c.analysis(),command).batches().getFirst();
        assertNotEquals(first.planId(),added.planId(),phase);
        assertNotEquals(first.batchId(),added.batchId(),phase);
        assertTrue(h.writer.submit(c.analysis(),command).replayed());
        amount("100",h.db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,originalSegment));
        assertEquals(originalCode,h.db.queryForObject("SELECT segment_code FROM production_execution_segments WHERE id=?",String.class,originalSegment));
        amount("100",h.db.queryForObject("SELECT required_qty FROM production_material_demands WHERE id=?",BigDecimal.class,originalDemand));
        amount("100",h.db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,first.planId()));
        amount("20",h.db.queryForObject("SELECT qty FROM production_plan_items WHERE plan_id=? AND NOT is_deleted",BigDecimal.class,added.planId()));
        assertEquals(2,h.count("SELECT count(*) FROM production_plans WHERE material_analysis_id=? AND NOT is_deleted",c.analysis()));
        amount("100",h.db.queryForObject("SELECT SUM(requested_qty) FROM preplan_supply_actions WHERE analysis_id=? AND route='MAKE' AND status<>'CANCELLED'",BigDecimal.class,c.analysis()));
        amount("20",h.db.queryForObject("SELECT SUM(public_surplus_qty) FROM preplan_supply_actions WHERE analysis_id=? AND route='MAKE' AND status<>'CANCELLED'",BigDecimal.class,c.analysis()));
        var current=h.analyses.detail(c.analysis());
        var original=current.flatMaterials().stream().filter(row->row.materialLineId().equals(originalMaterial)).findFirst().orElseThrow();
        amount("100",original.sourceRequiredQty());
        amount("120",original.aggregatePreparation().orderedQty());
        // Partial inbound consumes only that batch's materials; it is never re-expanded on append.
        amount("PARTIAL_INBOUND".equals(phase)?"30":"0",h.db.queryForObject(
                "SELECT COALESCE(SUM(base_qty),0) FROM stock_document_items item JOIN stock_documents doc ON doc.id=item.doc_id WHERE item.execution_segment_id=? AND doc.doc_type='FINISHED_IN' AND doc.status=1 AND NOT doc.is_deleted AND NOT item.is_deleted",BigDecimal.class,originalSegment));
    }

    private long version(UUID segment) {
        return h.db.queryForObject("SELECT lock_version FROM production_execution_segments WHERE id=?",Long.class,segment);
    }

    private GroupInput input(AggregateMaterialOrderEndToEndTest.Case c,String qty,boolean extra) {
        var input=h.input(c,c.common(),"MAKE",qty,extra);
        assertEquals(1,input.materialLineIds().size());
        // The UI records every original line's actual input. Legacy requests
        // without that proof intentionally cannot claim an exact original total.
        return new GroupInput(input.clientGroupKey(),input.materialLineIds(),input.route(),input.qty(),input.allowPublicExtra(),
                input.departmentId(),input.workerId(),input.teamDepartmentId(),input.billDate(),input.deliveryDate(),
                input.productNo(),input.allowedOverproductionRate(),input.safetyQty(),
                Map.of(input.materialLineIds().getFirst(),input.qty()));
    }
}
