package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.features.production.dailyreport.dto.*;
import com.uten.imp.features.production.execution.SegmentTransitionRequest;
import com.uten.imp.features.production.fulfillment.ProductionMaterialDiscoveryContracts.*;
import com.uten.imp.features.stock.dto.StockDocIssueRequest;
import com.uten.imp.support.DailyReportApproveRequests;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;

/** Actual planning -> unknown-material request -> warehouse issue -> repeated
 * reports -> real return receipt -> weighted BOM -> report reversal. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class ProductionBomLearningEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ProductionDailyReportService reports;
    ProductionMaterialDiscoveryEndToEndTest task;
    UUID demand,reporter;

    @BeforeEach void prepare() {
        task=new ProductionMaterialDiscoveryEndToEndTest();beans.autowireBean(task);task.prepare();
        // The workshop's suggestion remains an audit fact; warehouse-confirmed real
        // material and actual net consumption alone determine the learned component.
        var pending=task.discovery.request(task.segment,new Request(task.version(),"learn-request-"+task.segment,
                List.of(new RequestedMaterial(task.world.goodsE(),null,task.world.unitId(),new BigDecimal("21")))));
        task.receive(task.world.goodsD(),"22");
        var configured=task.discovery.configure(pending.requestId(),new Configure(pending.version(),"learn-configure-"+task.segment,
                List.of(new Material(task.world.goodsD(),null,task.world.unitId(),task.world.warehouseId(),new BigDecimal("22")))));
        assertEquals(task.world.goodsE(),configured.suggestedItems().getFirst().goodsId());
        assertEquals(task.world.goodsD(),configured.items().getFirst().goodsId());
        demand=configured.items().getFirst().demandId();
        UUID draw=configured.drawDocIds().getFirst();var issue=new StockDocIssueRequest();issue.setIdempotencyKey("learn-issue-"+draw);
        issue.setLines(db.query("SELECT id,qty FROM stock_document_items WHERE doc_id=? AND NOT is_deleted",(rs,index)->{
            var line=new StockDocIssueRequest.Line();line.setItemId(rs.getObject(1,UUID.class));line.setQty(rs.getBigDecimal(2));return line;},draw));
        task.stock.approveAndIssue(draw,issue);
        task.segments.start(task.plan,task.segment,new SegmentTransitionRequest(task.version(),"learn-start-"+task.segment));
        reporter=task.fixture.createUserWithPerms(task.world,"learn-reporter-"+UUID.randomUUID(),
                "production_execution:view","production_daily_report:create","production_daily_report:edit",
                "production_daily_report:approve","production_daily_report:reverse");
        db.update("UPDATE employees SET department_id=? WHERE id=(SELECT employee_id FROM users WHERE id=?)",task.workshop,reporter);
        task.fixture.loginAs(reporter);
    }
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void finalMaterialReturnMustActuallyReachWarehouseBeforeLearningAndReverseRetractsIt() {
        UUID first=report("40","8",false);
        amount("0",profileOutput());
        UUID last=report("60","12",true);
        amount("0",profileOutput());
        // 余料待仓库实收：物料未核清，本族还没有任何贡献(ADR-129 §2.4)。
        assertEquals(0,db.queryForObject("SELECT count(*) FROM production_bom_learning_samples WHERE execution_root_id=? AND jsonb_array_length(materials)>0",Integer.class,task.segment));
        UUID returned=db.queryForObject("SELECT id FROM production_material_return_requests WHERE execution_segment_id=?",UUID.class,task.segment);
        task.fixture.loginAs(task.world.superAdminUserId());task.stock.approve(returned);
        amount("100",profileOutput());amount("0.2",bomQty());
        assertEquals(0,db.queryForObject("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",Integer.class,task.world.goodsC(),task.world.goodsE()));
        amount("22",db.queryForObject("SELECT required_qty FROM production_material_demands WHERE id=?",BigDecimal.class,demand));
        assertEquals(1,db.queryForObject("SELECT count(*) FROM production_bom_learning_samples WHERE goods_id=? AND output_qty>0",Integer.class,task.world.goodsC()));
        amount("2",db.queryForObject("SELECT returned_qty FROM v_production_material_clearance WHERE demand_id=?",BigDecimal.class,demand));
        task.fixture.loginAs(reporter);reports.reverse(last);
        amount("0",profileOutput());
        // 冲销撤回贡献：真实使用数量变为没数据，学习边不自动撤下，计算回退到设计值(最后同步值)。
        assertEquals(1,db.queryForObject("SELECT count(*) FROM goods_bom_items WHERE goods_id=? AND NOT is_deleted",Integer.class,task.world.goodsC()));
        assertEquals("DESIGN",db.queryForObject("SELECT usage.usage_basis FROM v_goods_bom_item_usage usage JOIN goods_bom_items edge ON edge.id=usage.bom_item_id WHERE edge.goods_id=? AND NOT edge.is_deleted",String.class,task.world.goodsC()));
        amount("0.2",bomQty());
        amount("40",db.queryForObject("SELECT qty FROM production_daily_report_items WHERE report_id=?",BigDecimal.class,first));
    }

    @Test void realActualSurplusBelongsInOneOutputDenominatorAndApprovalReplayDoesNotRelearn() {
        UUID report=report("110","22",false);
        amount("110",profileOutput());amount("0.2",bomQty());
        amount("100",db.queryForObject("SELECT planned_qty FROM production_execution_segments WHERE id=?",BigDecimal.class,task.segment));
        amount("10",db.queryForObject("SELECT sum(qty) FROM production_daily_report_items WHERE report_id=? AND is_actual_surplus",BigDecimal.class,report));
        assertEquals(1,db.queryForObject("SELECT sample_count FROM goods_bom_learning_profiles WHERE goods_id=?",Integer.class,task.world.goodsC()));
    }

    private UUID report(String quantity,String consumed,boolean returnSurplus) {
        var request=new DailyReportSaveRequest();request.setIdempotencyKey("learning-report-"+UUID.randomUUID());request.setBillDate(BusinessTime.today());
        request.setWarehouseId(task.world.warehouseId());request.setDepartmentId(task.workshop);request.setWorkerId(task.worker);request.setWorkerIds(List.of(task.worker));
        var source=db.queryForMap("""
                SELECT segment.source_plan_item_id,allocation.id AS allocation_id,allocation.sales_order_item_id
                FROM production_execution_segments segment JOIN execution_segment_sales_allocations allocation ON allocation.execution_segment_id=segment.id
                WHERE segment.id=?
                """,task.segment);
        var line=new DailyReportItemLine();line.setGoodsId(task.world.goodsC());line.setUnitId(task.world.unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(quantity));line.setPlanItemId((UUID)source.get("source_plan_item_id"));line.setExecutionSegmentId(task.segment);
        line.setExecutionSegmentSalesAllocationId((UUID)source.get("allocation_id"));line.setSalesOrderItemId((UUID)source.get("sales_order_item_id"));line.setIsFinal(false);
        request.setItems(List.of(line));var use=new DailyReportMaterialUsageLine();use.setDemandId(demand);use.setQtyBase(new BigDecimal(consumed));
        request.setMaterialLines(List.of(use));request.setSurplusReturnRequested(returnSurplus);
        UUID id=reports.create(request).getId();var command=DailyReportApproveRequests.freshKey();reports.approve(id,command);
        Long revision=db.queryForObject("SELECT (SELECT revision FROM goods_bom_learning_profiles WHERE goods_id=?)",Long.class,task.world.goodsC());
        reports.approve(id,command);
        assertEquals(revision,db.queryForObject("SELECT (SELECT revision FROM goods_bom_learning_profiles WHERE goods_id=?)",Long.class,task.world.goodsC()));
        return id;
    }
    // 档案在第一份有效样本写出时才建(ADR-129 §2.4)，之前按 0 计。
    private BigDecimal profileOutput(){return db.queryForObject("SELECT COALESCE((SELECT total_output_qty FROM goods_bom_learning_profiles WHERE goods_id=?),0)",BigDecimal.class,task.world.goodsC());}
    private BigDecimal bomQty(){return db.queryForObject("SELECT qty FROM goods_bom_items WHERE goods_id=? AND component_goods_id=? AND NOT is_deleted",BigDecimal.class,task.world.goodsC(),task.world.goodsD());}
    private static void amount(String expected,BigDecimal actual){assertNotNull(actual);assertEquals(0,new BigDecimal(expected).compareTo(actual),actual.toString());}
}
