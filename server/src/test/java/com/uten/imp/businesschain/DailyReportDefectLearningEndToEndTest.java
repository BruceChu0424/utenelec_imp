package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemDto;
import com.uten.imp.features.production.dailyreport.dto.DailyReportItemLine;
import com.uten.imp.features.production.dailyreport.dto.DailyReportSaveRequest;
import com.uten.imp.features.production.dailyreport.dto.ReportablePlanLine;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.stock.dto.ProductionMaterialReturnConfirmRequest;
import com.uten.imp.support.DailyReportApproveRequests;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.postgresql.util.PSQLException;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/**
 * ADR-129: a daily report records its defects only. Good output, stock, FQC and over-production
 * never see them; the learned real usage stays per good unit and the defects only derive the
 * usage per produced unit and the defect rate.
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class DailyReportDefectLearningEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionDailyReportService reports;
    private WorkshopPublicSurplusEndToEndTest fixture;

    @BeforeEach void prepare(){fixture=new WorkshopPublicSurplusEndToEndTest();beans.autowireBean(fixture);fixture.prepare();}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    /**
     * Manual design usage 1 per product. 4 good + 1 defective, then 6 good + 2 defective with one unit
     * physically counted back: 9 used for 10 good and 3 defective pieces.
     */
    @Test void defectsAreRecordedOnlyAndTeachThePerProducedUsageAndTheDefectRate(){
        Object task=invoke(fixture,"createStartedTask","defect-learn-"+UUID.randomUUID(),false,"10");
        UUID product=invoke(task,"product"),material=invoke(task,"material");
        UUID plan=invoke(task,"plan"),planItem=invoke(task,"planItem");
        FullChainEndToEndTest.World world=invoke(task,"world");

        DailyReportSaveRequest first=invoke(fixture,"reportRequest",task,source(task),"4","4");
        first.getItems().getFirst().setDefectQty(new BigDecimal("1"));
        UUID firstReport=reports.approve(reports.create(first).getId(),DailyReportApproveRequests.freshKey()).getId();
        DailyReportItemDto firstItem=onlyItem(firstReport);
        qty("4",firstItem.getQty());qty("1",firstItem.getDefectQty());
        qty("4",planQuantity(planItem,"fqty"));

        // 6 + 2 on top of 4 + 1 is 13 pieces for a plan of 10: only the good pieces count against the plan.
        DailyReportSaveRequest last=invoke(fixture,"reportRequest",task,source(task),"6","5.9");
        last.getItems().getFirst().setIsFinal(true);last.getItems().getFirst().setDefectQty(new BigDecimal("2"));
        last.setSurplusReturnRequested(true);
        last.getMaterialLines().getFirst().setCountedLeftoverQty(new BigDecimal("1"));
        UUID lastReport=reports.approve(reports.create(last).getId(),DailyReportApproveRequests.freshKey()).getId();
        DailyReportItemDto lastItem=onlyItem(lastReport);
        qty("6",lastItem.getQty());qty("2",lastItem.getDefectQty());assertFalse(lastItem.isActualSurplus());
        qty("10",planQuantity(planItem,"fqty"));
        qty("10",planQuantity(planItem,"qty"));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_plans WHERE source_daily_report_id IN (?,?) AND NOT is_deleted",
                Integer.class,firstReport,lastReport),"defects never create a make-up plan");

        UUID returned=db.queryForObject("SELECT id FROM stock_documents WHERE doc_type='WDRAW' AND plan_no=(SELECT bill_no FROM production_plans WHERE id=?) AND NOT is_deleted",UUID.class,plan);
        beans.getBean(StockDocService.class).confirmProductionMaterialReturn(returned,
                new ProductionMaterialReturnConfirmRequest(world.warehouseId(),"defect-learn-return-"+returned));

        // The planning number stays per good unit: 9 / 10.
        Map<String,Object> usage=db.queryForMap("""
                SELECT net_qty,exposure_output_qty,exposure_defect_qty,actual_qty FROM goods_bom_actual_usages
                WHERE goods_id=? AND component_goods_id=?
                """,product,material);
        qty("9",usage.get("net_qty"));qty("10",usage.get("exposure_output_qty"));
        qty("3",usage.get("exposure_defect_qty"));qty("0.9",usage.get("actual_qty"));
        Map<String,Object> learned=db.queryForMap("""
                SELECT actual_status,actual_qty,defect_qty,actual_per_produced_qty,defect_rate FROM v_goods_bom_actual_usage
                WHERE goods_id=? AND component_goods_id=?
                """,product,material);
        assertEquals("ACTUAL",learned.get("actual_status"));
        qty("0.9",learned.get("actual_qty"));qty("3",learned.get("defect_qty"));
        ratio("9","13",learned.get("actual_per_produced_qty"));ratio("3","13",learned.get("defect_rate"));
        Map<String,Object> edge=db.queryForMap("""
                SELECT usage.usage_basis,usage.actual_qty,usage.defect_qty,usage.actual_per_produced_qty,usage.defect_rate
                FROM v_goods_bom_item_usage usage JOIN goods_bom_items edge ON edge.id=usage.bom_item_id
                WHERE edge.goods_id=? AND edge.component_goods_id=? AND NOT edge.is_deleted
                """,product,material);
        assertEquals("ACTUAL",edge.get("usage_basis"));
        qty("0.9",edge.get("actual_qty"));qty("3",edge.get("defect_qty"));
        ratio("9","13",edge.get("actual_per_produced_qty"));ratio("3","13",edge.get("defect_rate"));
        qty("1",db.queryForObject("SELECT qty FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",
                BigDecimal.class,product,material));
        Map<String,Object> sample=db.queryForMap("SELECT output_qty,defect_qty FROM production_bom_learning_samples WHERE goods_id=?",product);
        qty("10",sample.get("output_qty"));qty("3",sample.get("defect_qty"));
        qty("3",db.queryForObject("SELECT total_defect_qty FROM goods_bom_learning_profiles WHERE goods_id=?",BigDecimal.class,product));

        // Arrival, FQC and the finished receipt only ever carry the good pieces.
        for(UUID report:List.of(firstReport,lastReport))invoke(fixture,"finishInbound",task,report);
        qty("4",inspectedQty(firstItem.getId()));qty("6",inspectedQty(lastItem.getId()));
        qty("10",planQuantity(planItem,"iqty"));
        qty("10",db.queryForObject("SELECT COALESCE(SUM(qty),0) FROM stock_balances WHERE goods_id=?",BigDecimal.class,product));

        // A new material analysis adopts the real usage together with its defect rate (3/13, 6 decimals).
        FullChainEndToEndTest chain=(FullChainEndToEndTest)ReflectionTestUtils.getField(fixture,"fixture");
        UUID order=chain.createApprovedOrder(world,product,"10","100");
        UUID orderItem=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        var analyses=beans.getBean(com.uten.imp.features.production.analysis.MaterialAnalysisService.class);
        var view=analyses.preview(new com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewRequest(
                null,null,null,world.warehouseId(),"defect-learn-preview-"+order,
                List.of(new com.uten.imp.features.production.analysis.MaterialAnalysisContracts.PreviewItem("SALES_ORDER_ITEM",orderItem,
                        null,null,null,null,null,BusinessTime.today().plusDays(10),new BigDecimal("10")))));
        var node=view.flatMaterials().stream().filter(row->material.equals(row.goodsId())).findFirst().orElseThrow();
        assertEquals("ACTUAL",node.usageBasis());
        qty("0.9",node.bomQty());
        qty("0.230769",node.usageDefectRate());
    }

    /** One entered batch split into a sales and a public slice keeps its defects once, on the first slice. */
    @Test void aBatchKeepsItsDefectsOnItsFirstSliceAndTheDatabaseRejectsALaterSlice(){
        Object task=invoke(fixture,"createStartedTask","defect-slices-"+UUID.randomUUID(),true,"10");
        UUID planItem=invoke(task,"planItem");
        List<ReportablePlanLine> sources=invoke(fixture,"sources",task);
        ReportablePlanLine sales=sources.stream().filter(row->row.orderItemId()!=null).findFirst().orElseThrow();

        DailyReportSaveRequest negative=invoke(fixture,"reportRequest",task,sales,"10","10");
        negative.getItems().getFirst().setDefectQty(new BigDecimal("-1"));
        ApiException rejected=assertThrows(ApiException.class,()->reports.create(negative));
        assertEquals("不良数不能为负",rejected.getMessage());

        DailyReportSaveRequest request=invoke(fixture,"reportRequest",task,sales,"10","10");
        request.getItems().getFirst().setDefectQty(new BigDecimal("2"));
        UUID draft=reports.create(request).getId();
        List<DailyReportItemDto> slices=reports.detail(draft).getItems();
        assertEquals(2,slices.size());
        assertEquals(1,slices.stream().map(DailyReportItemDto::getOutputBatchId).distinct().count());
        qty("5",slices.get(0).getQty());qty("2",slices.get(0).getDefectQty());assertFalse(slices.get(0).isPublicOutput());
        qty("5",slices.get(1).getQty());qty("0",slices.get(1).getDefectQty());assertTrue(slices.get(1).isPublicOutput());
        for(DailyReportItemDto slice:slices)qty("10",slice.getOutputBatchQty());

        // Moving the defects onto the later slice would let one batch count them again.
        UUID firstSlice=slices.get(0).getId(),laterSlice=slices.get(1).getId();
        RuntimeException moved=assertThrows(RuntimeException.class,()->db.update(
                "UPDATE production_daily_report_items SET defect_qty=CASE WHEN id=? THEN 0 ELSE 2 END WHERE id IN (?,?)",
                firstSlice,firstSlice,laterSlice));
        Throwable cause=moved;while(cause.getCause()!=null)cause=cause.getCause();
        PSQLException postgres=assertInstanceOf(PSQLException.class,cause);
        assertEquals("23514",postgres.getSQLState());
        assertEquals("daily_report_defect_first_slice",postgres.getServerErrorMessage().getConstraint());
        qty("2",db.queryForObject("SELECT defect_qty FROM production_daily_report_items WHERE id=?",BigDecimal.class,firstSlice));
        qty("0",db.queryForObject("SELECT defect_qty FROM production_daily_report_items WHERE id=?",BigDecimal.class,laterSlice));

        // 10 good + 2 defective on a plan of 10 is not over-production.
        UUID approved=reports.approve(draft,DailyReportApproveRequests.freshKey()).getId();
        assertTrue(reports.detail(approved).getItems().stream().noneMatch(DailyReportItemDto::isActualSurplus));
        qty("10",planQuantity(planItem,"fqty"));
    }

    /**
     * 130 good + 5 defective sent on to the next step: 100 goes directly to the parent demand, 30 is public
     * surplus inside the approved 30% tolerance. The defects stay on the transferred slice and are neither
     * handed to the next step nor counted against the tolerance.
     */
    @Test void aDirectTransferKeepsItsDefectsOnTheTransferredSliceAndOutOfTheTransferAndTheTolerance(){
        WorkshopDirectTransferBatchEndToEndTest transfers=new WorkshopDirectTransferBatchEndToEndTest();
        beans.autowireBean(transfers);transfers.prepare();
        Object c=invoke(transfers,"create","defect-dt-"+UUID.randomUUID(),false);
        FullChainEndToEndTest.World world=invoke(c,"world");
        UUID childSegment=invoke(c,"childSegment"),target=invoke(transfers,"parentDemand",c);
        invoke(transfers,"approveOverproductionRate",childSegment,world.superAdminUserId(),"0.30");
        FullChainEndToEndTest chain=(FullChainEndToEndTest)ReflectionTestUtils.getField(transfers,"fixture");
        assertNotNull(chain);chain.loginAs(invoke(c,"workerUser"));

        DailyReportSaveRequest report=new DailyReportSaveRequest();
        report.setIdempotencyKey("defect-dt-"+childSegment);report.setBillDate(BusinessTime.today());
        report.setWarehouseId(invoke(c,"leaf"));report.setDepartmentId(invoke(c,"workshop"));
        UUID worker=invoke(c,"worker");report.setWorkerIds(List.of(worker));
        DailyReportItemLine item=new DailyReportItemLine();
        item.setLineNo(1);item.setExecutionSegmentId(childSegment);
        item.setPlanItemId(db.queryForObject("SELECT source_plan_item_id FROM production_execution_segments WHERE id=?",UUID.class,childSegment));
        item.setGoodsId(invoke(c,"child"));item.setUnitId(world.unitId());item.setUnitRate(BigDecimal.ONE);
        item.setQty(new BigDecimal("130"));item.setDefectQty(new BigDecimal("5"));item.setIsFinal(false);
        // ADR-127 起直送入口是「去向分配」子行(每条=接收需求+数量), 不再是行级
        // destination/directTransferDemandId; 100 直送父需求、30 容差内公共超产。
        item.setAllocations(List.of(com.uten.imp.features.production.dailyreport.dto
                        .DailyReportOutputAllocationLine.direct(target,new BigDecimal("100")),
                com.uten.imp.features.production.dailyreport.dto
                        .DailyReportOutputAllocationLine.warehouse(new BigDecimal("30"))));
        report.setItems(List.of(item));
        report.setMaterialLines(invoke(transfers,"directInputUse",c,item.getQty()));
        UUID draft=reports.create(report).getId();

        List<DailyReportItemDto> slices=reports.detail(draft).getItems();
        assertEquals(2,slices.size());
        assertEquals(1,slices.stream().map(DailyReportItemDto::getOutputBatchId).distinct().count());
        DailyReportItemDto direct=slices.get(0),surplus=slices.get(1);
        assertEquals("WORKSHOP",direct.getDestination());qty("100",direct.getQty());qty("5",direct.getDefectQty());
        assertTrue(surplus.isActualSurplus());assertEquals("WAREHOUSE",surplus.getDestination());
        qty("30",surplus.getQty());qty("0",surplus.getDefectQty());

        reports.approve(draft,DailyReportApproveRequests.freshKey());
        qty("100",db.queryForObject("""
                SELECT COALESCE(sum(qty),0) FROM production_workshop_direct_transfer_items
                WHERE to_demand_id=? AND reversal_id IS NULL
                """,BigDecimal.class,target));
        qty("130",db.queryForObject("SELECT COALESCE(sum(qty),0) FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",
                BigDecimal.class,draft));
        qty("5",db.queryForObject("SELECT COALESCE(sum(defect_qty),0) FROM production_daily_report_items WHERE report_id=? AND NOT is_deleted",
                BigDecimal.class,draft));
    }

    private DailyReportItemDto onlyItem(UUID report){
        List<DailyReportItemDto> items=reports.detail(report).getItems();
        assertEquals(1,items.size());
        return items.getFirst();
    }
    private ReportablePlanLine source(Object task){
        List<ReportablePlanLine> sources=invoke(fixture,"sources",task);
        return sources.getFirst();
    }
    private BigDecimal planQuantity(UUID planItem,String field){
        return db.queryForObject("SELECT "+field+" FROM production_plan_items WHERE id=?",BigDecimal.class,planItem);
    }
    private BigDecimal inspectedQty(UUID reportItem){
        return db.queryForObject("SELECT reported_qty FROM production_fqc_inspections WHERE source_report_item_id=?",BigDecimal.class,reportItem);
    }
    private static <T> T invoke(Object target,String method,Object... args){
        return ReflectionTestUtils.invokeMethod(target,method,args);
    }
    private static void qty(String expected,Object actual){
        assertNotNull(actual);BigDecimal value=new BigDecimal(actual.toString());
        assertEquals(0,new BigDecimal(expected).compareTo(value),"expected "+expected+" but was "+value);
    }
    private static void ratio(String numerator,String denominator,Object actual){
        assertNotNull(actual);
        BigDecimal expected=new BigDecimal(numerator).divide(new BigDecimal(denominator),10,RoundingMode.HALF_UP);
        BigDecimal value=new BigDecimal(actual.toString()).setScale(10,RoundingMode.HALF_UP);
        assertEquals(0,expected.compareTo(value),"expected "+numerator+"/"+denominator+" but was "+actual);
    }
}
