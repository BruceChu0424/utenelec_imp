package com.uten.imp.businesschain;

import com.uten.imp.application.port.LineSideWarehousePort;
import com.uten.imp.features.stock.valuation.ProductionInventoryValueService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.time.LocalDate;
import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

import static org.junit.jupiter.api.Assertions.*;

/**
 * ADR-131 §4.6 生产成本投入发现只有一个口径 (包 S1):
 * <ul>
 *   <li>{@code v_production_cost_input_candidates} 第一段与改造前的清账投入发现查询逐行相等 (回归);</li>
 *   <li>刷新成本对象改读视图后, 清账投入照旧逐条登记;</li>
 *   <li>成本完整性门追加的两条: (i) 绑定内料仓的段有晚于已结算截止日的已审报工;
 *       (ii) 有期间分摊切片尚未登记为投入 (本批一起登记的除外)。</li>
 * </ul>
 * 完整性门两条在一个回滚的事务里按库内真实守卫造数后求值, 提交时的结算断言不参与。
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
class ProductionCostInputCandidatesPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired NamedParameterJdbcTemplate named;
    @Autowired PlatformTransactionManager transactions;
    @Autowired LineSideWarehousePort lineSide;
    private FullChainEndToEndTest fixture;

    /** 改造前 ProductionInventoryValueService 的投入发现查询原文 (回归基线, 不随实现改动)。 */
    private static final String FORMER_DISCOVERY = """
            SELECT e.result_node_id,p.id,p.settlement_type,pool.goods_id,pool.color_id
            FROM production_material_settlement_postings p
            JOIN production_material_demands demand ON demand.id=p.demand_id
            JOIN stock_value_events e ON e.source_event_id=p.id AND e.source_doc_type='PRODUCTION_CONSUMED_VALUE'
            JOIN stock_value_nodes n ON n.id=e.result_node_id JOIN stock_value_pools pool ON pool.id=n.pool_id
            WHERE demand.execution_segment_id IN (SELECT segment_id FROM fn_production_execution_cost_members(:id))
                AND n.active AND NOT EXISTS(
                SELECT 1 FROM stock_value_production_cost_inputs i WHERE i.approved_posting_id=p.id)
            ORDER BY p.id LIMIT 100
            """;

    /** 改造前查询去掉范围与"未登记"过滤后的全集, 与视图第一段逐列对齐。 */
    private static final String FORMER_ALL = """
            SELECT demand.execution_segment_id,e.result_node_id,p.id,
                   CASE WHEN p.settlement_type='CONSUMED' THEN 'CONSUMED' ELSE 'NORMAL_LOSS' END,
                   pool.goods_id,pool.color_id,n.active
            FROM production_material_settlement_postings p
            JOIN production_material_demands demand ON demand.id=p.demand_id
            JOIN stock_value_events e ON e.source_event_id=p.id AND e.source_doc_type='PRODUCTION_CONSUMED_VALUE'
            JOIN stock_value_nodes n ON n.id=e.result_node_id JOIN stock_value_pools pool ON pool.id=n.pool_id
            """;
    private static final String VIEW_SETTLEMENT_BRANCH = """
            SELECT member_segment_id,result_node_id,approved_posting_id,input_kind,goods_id,color_id,node_active
            FROM v_production_cost_input_candidates WHERE input_kind<>'PERIODIC_MATERIAL'
            """;

    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void candidateViewReproducesTheFormerSettlementDiscoveryRowByRow(){
        Case c=consumedFirstHalf("input-candidates");
        UUID scope=scope(c.segment());
        List<List<Object>> former=named.queryForList(FORMER_DISCOVERY,Map.of("id",scope)).stream()
                .map(row->Arrays.asList(row.get("result_node_id"),row.get("id"),
                        "CONSUMED".equals(row.get("settlement_type"))?"CONSUMED":"NORMAL_LOSS",
                        row.get("goods_id"),row.get("color_id"))).toList();
        List<List<Object>> current=candidates(scope);
        assertFalse(former.isEmpty(),"The fixture must leave confirmed consumption waiting for its cost object");
        assertEquals(former,current);
        // 整库口径: 视图清账段与改造前查询的全集双向无差异 (含节点是否有效)
        assertEquals(0,db.queryForObject("SELECT count(*) FROM (("+FORMER_ALL+") EXCEPT ALL ("+VIEW_SETTLEMENT_BRANCH+")) difference",Integer.class));
        assertEquals(0,db.queryForObject("SELECT count(*) FROM (("+VIEW_SETTLEMENT_BRANCH+") EXCEPT ALL ("+FORMER_ALL+")) difference",Integer.class));

        // 成品入库登记产出时刷新成本对象: 改读视图后, 这些清账投入逐条登记, 种类与原口径一致
        fixture.confirmFinishedInboundFully(c.inbound());
        assertTrue(candidates(scope).isEmpty());
        assertEquals(former.size(),db.queryForObject("""
                SELECT count(*) FROM stock_value_production_cost_inputs input
                JOIN production_material_settlement_postings posting ON posting.id=input.approved_posting_id
                JOIN stock_value_events event ON event.source_event_id=posting.id
                  AND event.source_doc_type='PRODUCTION_CONSUMED_VALUE' AND event.result_node_id=input.input_node_id
                WHERE input.execution_segment_id=?
                  AND input.input_kind=CASE WHEN posting.settlement_type='CONSUMED' THEN 'CONSUMED' ELSE 'NORMAL_LOSS' END
                """,Integer.class,scope));
    }

    @Test void periodicCompletenessWaitsForTheClosedPeriodAndItsRegisteredAllocations(){
        Case c=consumedFirstHalf("input-gate");
        fixture.confirmFinishedInboundFully(c.inbound());
        UUID scope=scope(c.segment());
        UUID user=c.world().superAdminUserId();
        UUID workshop=db.queryForObject("SELECT workshop_department_id FROM production_execution_segments WHERE id=?",UUID.class,c.segment());
        LocalDate reported=db.queryForObject("""
                SELECT max(report.bill_date) FROM production_daily_reports report
                JOIN production_daily_report_items item ON item.report_id=report.id AND NOT item.is_deleted
                WHERE item.execution_segment_id=? AND report.status=1 AND NOT report.is_deleted""",LocalDate.class,c.segment());
        assertNotNull(workshop);assertNotNull(reported);
        UUID kg=massUnit();
        UUID granule=granule(kg);
        assertTrue(periodicComplete(scope,""),"A scope never bound to a workshop material bin is unaffected");

        new TransactionTemplate(transactions).executeWithoutResult(status->{
            LocalDate goLive=reported.minusDays(10);
            UUID bin=lineSide.ensure(workshop,c.world().warehouseId());
            UUID period=UUID.randomUUID();
            db.update("""
                    INSERT INTO workshop_material_settings(workshop_department_id,periodic_enabled,periodic_bin_warehouse_id,
                        go_live_date,enabled_by,enabled_at,created_by)
                    VALUES (?,TRUE,?,?,?,now(),?)""",workshop,bin,goLive,user,user);
            db.update("""
                    INSERT INTO workshop_material_periods(id,bin_warehouse_id,workshop_department_id,period_no,start_date,created_by)
                    VALUES (?,?,?,1,?,?)""",period,bin,workshop,goLive,user);
            db.update("""
                    INSERT INTO production_execution_periodic_materials(execution_segment_id,bin_warehouse_id,material_goods_id,
                        unit_id,origin,bom_item_id,design_qty_snapshot,effective_from,created_by)
                    VALUES (?,?,?,?,'BOM',?,0.0125,?,?)""",c.segment(),bin,granule,kg,UUID.randomUUID(),goLive,user);

            // (i) 已审报工日期晚于已结算截止日 (启用日前一天): 不完整, 整条完整性门随之不完整
            assertFalse(periodicComplete(scope,""));
            assertFalse(fullyComplete(scope,""));

            // 这一期盘点截止到报工日并有了有效结算 (结算事务里期间状态稍后才改为已结算, 有效结算同样算截止)
            db.update("""
                    UPDATE workshop_material_periods SET status='COUNTING',end_date=?,counting_started_by=?,
                        counting_started_at=now(),row_version=row_version+1 WHERE id=?""",reported,user,period);
            db.update("UPDATE workshop_material_periods SET status='COUNTED',row_version=row_version+1 WHERE id=?",period);
            UUID line=UUID.randomUUID(),close=UUID.randomUUID(),material=UUID.randomUUID(),allocation=UUID.randomUUID();
            db.update("""
                    INSERT INTO workshop_material_period_lines(id,period_id,goods_id,unit_id,cost_basis,opening_qty,
                        transfer_in_qty,closing_qty)
                    VALUES (?,?,?,?,'OWN',0,10,0)""",line,period,granule,kg);
            db.update("""
                    INSERT INTO workshop_material_period_closes(id,period_id,close_no,trigger_kind,closed_by)
                    VALUES (?,?,1,'AFTER_COUNT',?)""",close,period,user);
            db.update("""
                    INSERT INTO workshop_material_close_materials(id,close_id,period_line_id,cost_basis,theory_qty,outcome,consumed_qty)
                    VALUES (?,?,?,'OWN',10,'ALLOCATED',10)""",material,close,line);
            db.update("""
                    INSERT INTO workshop_material_close_allocations(id,close_material_id,cost_scope_segment_id,basis_qty,
                        allocated_qty,is_tail)
                    VALUES (?,?,?,10,10,TRUE)""",allocation,material,scope);

            // (i) 已满足; (ii) 分摊到本范围的切片还没登记为投入: 仍不完整
            assertFalse(periodicComplete(scope,""));
            // 本批刷新一起登记的分摊不算"尚未登记"
            assertTrue(periodicComplete(scope,allocation.toString()));
            assertTrue(periodicComplete(scope,UUID.randomUUID()+","+allocation));
            // 撤销结算后分摊行已撤回, 不再等它登记
            db.update("UPDATE workshop_material_close_allocations SET reversed_at=now() WHERE id=?",allocation);
            assertTrue(periodicComplete(scope,""));
            status.setRollbackOnly();
        });
        assertTrue(periodicComplete(scope,""));
    }

    // ---------------------------------------------------------------------------------------------

    private List<List<Object>> candidates(UUID scope){
        String sql=(String)ReflectionTestUtils.getField(ProductionInventoryValueService.class,"INPUT_CANDIDATES_SQL");
        return named.queryForList(sql,Map.of("id",scope)).stream()
                .map(row->Arrays.asList(row.get("result_node_id"),row.get("id"),row.get("input_kind"),
                        row.get("goods_id"),row.get("color_id"))).toList();
    }

    /** 只求值完整性门新增的两条。 */
    private boolean periodicComplete(UUID scope,String batch){
        String fragment=(String)ReflectionTestUtils.getField(ProductionInventoryValueService.class,"PERIODIC_MATERIAL_COMPLETE_SQL");
        return Boolean.TRUE.equals(named.queryForObject("SELECT "+fragment,Map.of("id",scope,"periodicBatch",batch),Boolean.class));
    }

    /** 刷新时实际执行的整条完整性门 (原三条 + 新增两条)。 */
    private boolean fullyComplete(UUID scope,String batch){
        String sql=(String)ReflectionTestUtils.getField(ProductionInventoryValueService.class,"COST_SCOPE_COMPLETE_SQL");
        return Boolean.TRUE.equals(named.queryForObject(sql,Map.of("id",scope,"periodicBatch",batch),Boolean.class));
    }

    private UUID scope(UUID segment){
        return db.queryForObject("SELECT fn_production_execution_cost_scope(?)",UUID.class,segment);
    }

    private UUID massUnit(){
        UUID kg=UUID.randomUUID();
        db.update("INSERT INTO units(id,legacy_id,code,name,status) VALUES (?,?,?,'千克','使用')",
                kg,900_000_000+ThreadLocalRandom.current().nextInt(90_000_000),"KG-"+kg.toString().substring(0,8));
        db.update("""
                INSERT INTO unit_measurement_profiles(unit_id, measurement_dimension, mass_unit_code, provenance)
                VALUES (?, 'MASS', 'KG', 'MANUAL_GOVERNANCE')""",kg);
        return kg;
    }

    private UUID granule(UUID kg){
        UUID id=UUID.randomUUID();
        int legacy=db.queryForObject("SELECT legacy_id FROM units WHERE id=?",Integer.class,kg);
        db.update("""
                INSERT INTO goods(id,code,name,source_type,status,unit_id,unit_legacy_id,price,code_sequence,
                                  issue_method,periodic_cost_basis)
                VALUES (?,?,?,'采购','使用',?,?,10,(SELECT coalesce(max(code_sequence),0)+1 FROM goods),'PERIODIC','OWN')""",
                id,"WMG-"+id.toString().substring(0,8),"注塑颗粒-"+id.toString().substring(0,4),kg,legacy);
        return id;
    }

    /** 与 FinishedInboundCostFootprintEndToEndTest 同一夹具: 领料 10 件的料, 报工 5 件, 实耗已清账、成品待点收。 */
    private Case consumedFirstHalf(String tag){
        var w=fixture.seedWorld(tag+"-"+UUID.randomUUID());fixture.loginAs(w.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture,"receiveOpeningInputsForA",w,"10");
        UUID plan=ReflectionTestUtils.invokeMethod(fixture,"approvedPlan",w,w.goodsA(),"10","10");
        ReflectionTestUtils.invokeMethod(fixture,"issueReadyPlanAndMaterials",w,plan);
        UUID item=db.queryForObject("SELECT id FROM production_plan_items WHERE plan_id=? AND goods_id=? AND NOT is_deleted",UUID.class,plan,w.goodsA());
        UUID orderItem=db.queryForObject("SELECT order_item_id FROM plan_order_item_links WHERE plan_item_id=? AND NOT is_deleted",UUID.class,item);
        UUID segment=db.queryForObject("SELECT id FROM production_execution_segments WHERE source_plan_item_id=? AND NOT is_deleted",UUID.class,item);
        UUID report=ReflectionTestUtils.invokeMethod(fixture,"reportAndApprove",w,item,orderItem,w.goodsA(),"5");
        return new Case(w,segment,fixture.finishedInDocForReport(report));
    }

    private record Case(FullChainEndToEndTest.World world,UUID segment,UUID inbound){}
}
