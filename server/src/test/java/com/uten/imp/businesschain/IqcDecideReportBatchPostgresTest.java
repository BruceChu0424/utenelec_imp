package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionDecideRequest;
import com.uten.imp.features.warehouse.inbound.dto.BatchInspectionReportRequest;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/**
 * 品质批量审批整份检验报告（2026-10-10 decide-report）：多张收货单一次请求原子提交。
 *
 * <p>钉三件事：混合采购/委外的整份报告同事务提交且同体重放不产生新事实；任一单冲突
 * 整批回滚（好单不留半提交状态）并按单号报错；只读权限不能提交。</p>
 */
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.concurrency.verify-nested-footprint=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class IqcDecideReportBatchPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties){FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired MockMvc http;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    /** 1 张采购收货单 + 1 张委外进仓单，各 2 行（每行待检 1.25）。 */
    private record Stage(Map<UUID,List<WarehouseIqcScaleFixture.Receipt>> byReceipt,
                         List<String> billNos,Authentication actor){}

    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInService preStock;

    private Stage prepare(){
        return prepare(2,2);
    }

    private Stage prepare(int receipts,int lines){
        var scenario=new WarehouseIqcMultiLineFixture(beans,db).prepare(receipts,lines,"iqc-report-"+UUID.randomUUID().toString().substring(0,8));
        var masters=new FullChainEndToEndTest();beans.autowireBean(masters);masters.loginAs(scenario.world().superAdminUserId());
        Map<UUID,List<WarehouseIqcScaleFixture.Receipt>> byReceipt=new LinkedHashMap<>();
        for(var row:scenario.receipts())byReceipt.computeIfAbsent(row.id(),ignored->new ArrayList<>()).add(row);
        assertEquals(receipts,byReceipt.size());
        List<String> billNos=new ArrayList<>();
        for(var entry:byReceipt.entrySet()){
            String table=entry.getValue().getFirst().type().equals("PURCHASE")?"purchase_receipts":"subcontract_receipts";
            billNos.add(db.queryForObject("SELECT bill_no FROM "+table+" WHERE id=?",String.class,entry.getKey()));
        }
        return new Stage(byReceipt,billNos,SecurityContextHolder.getContext().getAuthentication());
    }

    private BatchInspectionReportRequest report(Stage stage,BigDecimal corruptedRemainingForLastReceipt){
        List<BatchInspectionReportRequest.Receipt> receipts=new ArrayList<>();
        boolean last=true;
        for(var entry:stage.byReceipt().entrySet()){
            List<BatchInspectionDecideRequest.Item> items=new ArrayList<>();
            for(var row:entry.getValue()){
                BigDecimal remaining=new BigDecimal("1.2500");
                if(last&&corruptedRemainingForLastReceipt!=null)remaining=corruptedRemainingForLastReceipt;
                items.add(new BatchInspectionDecideRequest.Item(row.inspectionId(),remaining,
                        new BigDecimal("0.7500"),new BigDecimal("0.5000"),"iqc-report-key-"+row.inspectionId()));
            }
            var first=entry.getValue().getFirst();
            receipts.add(new BatchInspectionReportRequest.Receipt(first.type(),first.id(),items));
            last=false;
        }
        return new BatchInspectionReportRequest(receipts,"整份检验报告一次提交");
    }

    private JsonNode call(Stage stage,Object body,int expected)throws Exception{
        var response=http.perform(post("/api/procurement/inspection/decide-report")
                        .with(authentication(stage.actor())).contentType("application/json").content(json.writeValueAsBytes(body)))
                .andReturn().getResponse();
        assertEquals(expected,response.getStatus(),response.getContentAsString());
        return response.getContentAsByteArray().length==0?json.createObjectNode():json.readTree(response.getContentAsByteArray());
    }

    @Test void mixedReportCommitsAtomicallyAndSameBodyReplaysSilently()throws Exception{
        Stage stage=prepare();
        var request=report(stage,null);
        JsonNode result=call(stage,request,200);
        assertEquals(2,result.path("receiptCount").asInt());
        assertEquals(4,result.path("lineCount").asInt());
        assertFalse(result.path("replay").asBoolean());
        assertEquals(2,result.path("results").size());
        String facts=facts(stage);
        assertEquals(4,resolvedItemCount(stage),"每行 0.75+0.50=1.25 全量判定后应全部结案");
        JsonNode replay=call(stage,request,200);
        assertTrue(replay.path("replay").asBoolean());
        assertEquals(facts,facts(stage),"同体重放不产生新质量事实");
    }

    @Test void conflictingReceiptRollsBackTheWholeReportWithBillLabel()throws Exception{
        Stage stage=prepare();
        String before=facts(stage);
        JsonNode error=call(stage,report(stage,new BigDecimal("9.9999")),409);
        String message=error.path("message").asText();
        assertTrue(message.matches(".*(采购收货单|委外进仓单).*：.*"),"逐单报错要带单据类型与单号标签："+message);
        assertTrue(stage.billNos().stream().anyMatch(message::contains),"错误信息包含真实收货单号");
        assertEquals(before,facts(stage),"任一单冲突整批回滚，好单不留任何质量事实");
        // 同一报告体修正后重提：两张单全部正常提交（回滚过的单重新执行）。
        JsonNode fixed=call(stage,report(stage,null),200);
        assertEquals(2,fixed.path("receiptCount").asInt());
        assertFalse(fixed.path("replay").asBoolean());
        assertEquals(4,resolvedItemCount(stage));
    }

    @Test void viewOnlyAuthorityCannotSubmitTheReport()throws Exception{
        Stage stage=prepare();
        var user=(AuthUser)stage.actor().getPrincipal();
        var read=new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(
                new AuthUser(user.getId(),user.getEmployeeId(),"iqc-report-read",Set.of("procurement_inspection:view"),false,true,false),
                null,java.util.Collections.emptyList());
        var response=http.perform(post("/api/procurement/inspection/decide-report")
                        .with(authentication(read)).contentType("application/json")
                        .content(json.writeValueAsBytes(report(stage,null))))
                .andReturn().getResponse();
        assertEquals(403,response.getStatus());
        assertEquals(0,passFailEventCount(stage));
    }

    /**
     * 业务链回归①：同一张订货单的多张收货单（一单多送，最常见真实形态）合在整份报告里
     * 一个事务提交——联合预锁按合并偏序一次拿齐共享的订货单头/行，不会互相死锁或越界。
     */
    @Test void sharedOrderReceiptsCommitTogetherInOneReport()throws Exception{
        Stage stage=prepare(4,2);
        // 夹具 4 张收货单 = 2 PURCHASE(同一张采购订货单) + 2 SUBCONTRACT(同一张委外订货单)。
        assertEquals(2,stage.byReceipt().values().stream().filter(rows->rows.getFirst().type().equals("PURCHASE")).count());
        JsonNode result=call(stage,report(stage,null),200);
        assertEquals(4,result.path("receiptCount").asInt());
        assertEquals(8,result.path("lineCount").asInt());
        assertEquals(8,resolvedItemCount(stage));
    }

    /**
     * 业务链回归②：旧版逐单 decide-batch 已提交的单，在整份报告 decide-report 里静默重放
     * （旧版草稿→新版重试的迁移路径；两入口共用同一命令哈希与事件 UUID 派生）。
     */
    @Test void legacyPerReceiptCommitReplaysInsideTheWholeReport()throws Exception{
        Stage stage=prepare();
        var first=stage.byReceipt().entrySet().iterator().next();
        var singleType=first.getValue().getFirst().type();
        // 与整份报告完全同构的行与原因：旧入口先提交第一张单。
        var single=new BatchInspectionDecideRequest(
                first.getValue().stream().map(row->new BatchInspectionDecideRequest.Item(row.inspectionId(),
                        new BigDecimal("1.2500"),new BigDecimal("0.7500"),new BigDecimal("0.5000"),
                        "iqc-report-key-"+row.inspectionId())).toList(),
                "整份检验报告一次提交");
        var response=http.perform(post("/api/procurement/inspection/"+singleType+"/"+first.getKey()+"/decide-batch")
                        .with(authentication(stage.actor())).contentType("application/json").content(json.writeValueAsBytes(single)))
                .andReturn().getResponse();
        assertEquals(200,response.getStatus(),response.getContentAsString());
        int firstReceiptEvents=db.queryForObject(
                "SELECT count(*) FROM procurement_inspection_events e JOIN procurement_inspection_items i ON i.id=e.inspection_item_id WHERE i.receipt_id=? AND e.action IN ('PASS','FAIL')",
                Integer.class,first.getKey());
        assertEquals(4,firstReceiptEvents);
        JsonNode result=call(stage,report(stage,null),200);
        assertFalse(result.path("replay").asBoolean(),"整份报告不是纯重放(第二张单是新执行)");
        assertEquals(first.getKey().toString(),result.path("results").get(0).path("receiptId").asText());
        assertTrue(result.path("results").get(0).path("replayed").asBoolean(),"旧入口已提交的单静默重放");
        assertFalse(result.path("results").get(1).path("replayed").asBoolean());
        assertEquals(firstReceiptEvents,db.queryForObject(
                "SELECT count(*) FROM procurement_inspection_events e JOIN procurement_inspection_items i ON i.id=e.inspection_item_id WHERE i.receipt_id=? AND e.action IN ('PASS','FAIL')",
                Integer.class,first.getKey()),"重放不给已提交的单补新事实");
        assertEquals(4,resolvedItemCount(stage));
    }

    /**
     * 业务链回归③：先入库后检(ADR-090)在整份报告下不变——每张收货单仍各合成一个自动转正批次、
     * 库存按上架仓进账、不再给仓库发「待确认入库」任务、同体重放不翻倍。
     */
    @Test void preStockedBatchKeepsAutoStockInSemanticsPerReceipt()throws Exception{
        Stage stage=prepare(4,2);
        SecurityContextHolder.getContext().setAuthentication(stage.actor());
        for(var entry:stage.byReceipt().entrySet()){
            var rows=entry.getValue();
            preStock.preStockIn(rows.getFirst().type(),entry.getKey(),new com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInRequest(
                    rows.stream().map(row->new com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInItem(
                            row.inspectionId(),row.warehouseId(),"BATCH-"+row.inspectionId().toString().substring(0,4))).toList()));
        }
        JsonNode result=call(stage,report(stage,null),200);
        assertEquals(4,result.path("receiptCount").asInt());
        assertEquals(8,resolvedItemCount(stage));
        for(var entry:stage.byReceipt().entrySet()){
            var rows=entry.getValue();
            assertEquals(1,db.queryForObject(
                    "SELECT count(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=? AND origin='PRE_STOCKED_AUTO'",
                    Integer.class,entry.getKey()),"每张收货单一个自动转正批次");
            assertEquals(rows.size(),db.queryForObject(
                    "SELECT confirmed_count FROM procurement_iqc_stock_in_batches WHERE receipt_id=? AND origin='PRE_STOCKED_AUTO'",
                    Integer.class,entry.getKey()));
            for(var row:rows){
                // 报告每行合格 0.75/不合格 0.50：自动转正只转合格量，不合格量不进库存(ADR-090)。
                assertEquals(0,new BigDecimal("0.7500").compareTo(db.queryForObject(
                        "SELECT warehouse_stocked_base_qty FROM procurement_inspection_items WHERE id=?",BigDecimal.class,row.inspectionId())));
                assertEquals(0,new BigDecimal("0.7500").compareTo(balance(row.warehouseId(),row.goodsId())),
                        "合格量按上架仓进库存，不合格量(0.50)不进");
            }
        }
        int warehousePendingNotices=0;
        for(UUID receiptId:stage.byReceipt().keySet()){
            warehousePendingNotices+=db.queryForObject(
                    "SELECT count(*) FROM business_outbox WHERE event_type='PROCUREMENT_IQC_STOCK_IN_PENDING' AND payload::text LIKE ?",
                    Integer.class,"%"+receiptId+"%");
        }
        assertEquals(0,warehousePendingNotices,"已上架合格行走自动转正，不再发仓库待确认入库事件");
    }

    /**
     * 40 秒命令截止的余量证据：20 张收货单 × 5 行(100 行、混合类型、共享订货单)整份一次提交，
     * 普通与全预入库(先入库后检，单张最重形态)各量一遍；20 张上限(全预入库实测 ~30s)的余量依据。
     */
    @Test void twentyReceiptBatchCompletesWithinDeadlineBudget()throws Exception{
        Stage stage=prepare(20,5);
        var request=report(stage,null);
        long started=System.currentTimeMillis();
        JsonNode result=call(stage,request,200);
        long elapsed=System.currentTimeMillis()-started;
        System.out.println("[decide-report] 20 receipts x 5 lines elapsedMs=" + elapsed);
        assertEquals(20,result.path("receiptCount").asInt());
        assertEquals(100,result.path("lineCount").asInt());
        assertEquals(100,resolvedItemCount(stage));
        assertTrue(elapsed<30_000,"20 张单的整份报告必须远低于服务端 40s 命令截止，实测 " + elapsed + "ms");
    }

    @Test void preStockedTwentyReceiptBatchAlsoCompletesWithinDeadlineBudget()throws Exception{
        Stage stage=prepare(20,5);
        SecurityContextHolder.getContext().setAuthentication(stage.actor());
        for(var entry:stage.byReceipt().entrySet()){
            var rows=entry.getValue();
            preStock.preStockIn(rows.getFirst().type(),entry.getKey(),new com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInRequest(
                    rows.stream().map(row->new com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInItem(
                            row.inspectionId(),row.warehouseId(),"BUDGET-"+row.inspectionId().toString().substring(0,4))).toList()));
        }
        var request=report(stage,null);
        long started=System.currentTimeMillis();
        JsonNode result=call(stage,request,200);
        long elapsed=System.currentTimeMillis()-started;
        System.out.println("[decide-report] pre-stocked 20 receipts x 5 lines elapsedMs=" + elapsed);
        assertEquals(20,result.path("receiptCount").asInt());
        assertEquals(100,resolvedItemCount(stage));
        assertTrue(elapsed<35_000,"全预入库 20 张单也须低于服务端 40s 命令截止(20 张上限的实测依据)，实测 " + elapsed + "ms");
    }

    private int resolvedItemCount(Stage stage){
        return db.queryForObject("SELECT count(*) FROM procurement_inspection_items WHERE receipt_id IN ("
                + placeholders(stage) + ") AND status='RESOLVED'",Integer.class,stage.byReceipt().keySet().toArray());
    }

    private int passFailEventCount(Stage stage){
        return db.queryForObject("""
                SELECT count(*) FROM procurement_inspection_events e
                JOIN procurement_inspection_items i ON i.id=e.inspection_item_id
                WHERE i.receipt_id IN (
                """ + placeholders(stage) + ") AND e.action IN ('PASS','FAIL')",Integer.class,stage.byReceipt().keySet().toArray());
    }

    private String facts(Stage stage){
        Object[] ids=stage.byReceipt().keySet().toArray();
        Object[] args=new Object[ids.length*2];
        System.arraycopy(ids,0,args,0,ids.length);
        System.arraycopy(ids,0,args,ids.length,ids.length);
        return db.queryForObject("""
                SELECT jsonb_build_object('inspections',(SELECT jsonb_agg(to_jsonb(i) ORDER BY id) FROM procurement_inspection_items i WHERE receipt_id IN (
                """ + placeholders(stage) + "))," + """
                    'events',(SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id) FROM procurement_inspection_events e JOIN procurement_inspection_items i ON i.id=e.inspection_item_id WHERE i.receipt_id IN (
                """ + placeholders(stage) + ")))::text",String.class,args);
    }

    private static String placeholders(Stage stage){
        return String.join(",",java.util.Collections.nCopies(stage.byReceipt().size(),"?"));
    }

    private BigDecimal balance(UUID warehouseId,UUID goodsId){
        BigDecimal value=db.queryForObject(
                "SELECT COALESCE(SUM(qty), 0) FROM stock_balances WHERE warehouse_id = ? AND goods_id = ?",
                BigDecimal.class,warehouseId,goodsId);
        return value==null?BigDecimal.ZERO:value;
    }
}
