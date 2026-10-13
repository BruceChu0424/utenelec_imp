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
        "uten.inventory.value-work.enabled=false",
        "uten.features.goods-owner-scope-enabled=false","uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@org.springframework.context.annotation.Import(ProductionJdbcMeasurement.Configuration.class)
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
class IqcDecideReportBatchPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties){FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired ObjectMapper json;
    @Autowired MockMvc http;
    @org.springframework.test.context.bean.override.mockito.MockitoSpyBean
    com.uten.imp.features.production.analysis.MaterialAnalysisService analyses;
    @org.springframework.test.context.bean.override.mockito.MockitoSpyBean
    com.uten.imp.features.production.analysis.MaterialAnalysisSupplyWakeupService wakeup;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementInspectionService inspections;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    /** 1 张采购收货单 + 1 张委外进仓单，各 2 行（每行待检 1.25）。 */
    private record Stage(Map<UUID,List<WarehouseIqcScaleFixture.Receipt>> byReceipt,
                         List<String> billNos,Authentication actor,UUID analysisId){}

    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInService preStock;
    @Autowired com.uten.imp.features.notice.outbox.BusinessOutboxScheduler outboxScheduler;

    private void isolatePerformanceDelivery() {
        if(Boolean.getBoolean("uten.perf.isolate-outbox"))outboxScheduler.close();
    }

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
        return new Stage(byReceipt,billNos,SecurityContextHolder.getContext().getAuthentication(),scenario.analysisId());
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
        assertQualityValueSources(stage);
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
        Object analysisSpy=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(analyses);
        org.mockito.Mockito.clearInvocations(analysisSpy);
        ProductionJdbcMeasurement.Sample measured=ProductionJdbcMeasurement.begin();
        JsonNode result;
        // Measure the business transaction itself. The HTTP task-snapshot filter owns a separate
        // read transaction, so counting all HTTP commits would mislabel this atomic report as two.
        try { result=json.valueToTree(inspections.decideReport(report(stage,null))); }
        finally { ProductionJdbcMeasurement.end(); }
        assertEquals(1,refreshes(stage),"All four receipt scopes share one final analysis refresh");
        assertEquals(1,measured.commits,"Quality, physical stock, source allocation and final projection commit together");
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
        String committed=facts(stage);
        org.mockito.Mockito.clearInvocations(analysisSpy);
        assertTrue(call(stage,report(stage,null),200).path("replay").asBoolean());
        assertEquals(0,refreshes(stage),"Pure acknowledged replay must not refresh the analysis again");
        assertEquals(committed,facts(stage));
    }

    @Test void finalAnalysisFailureRollsBackAllReceiptQualityStockAndOriginalKeysCanRetry(){
        Stage stage=prepare(4,2);
        SecurityContextHolder.getContext().setAuthentication(stage.actor());
        for(var rows:stage.byReceipt().values()) {
            preStock.preStockIn(rows.getFirst().type(),rows.getFirst().id(),
                    new com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInRequest(
                            rows.stream().map(row -> new com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInItem(
                                    row.inspectionId(),row.warehouseId(),"ROLLBACK")).toList()));
        }
        String before=facts(stage);
        var request=report(stage,null);
        var wakeupTarget=org.springframework.test.util.AopTestUtils.<com.uten.imp.features.production.analysis.MaterialAnalysisSupplyWakeupService>getUltimateTargetObject(wakeup);
        org.mockito.Mockito.doAnswer(invocation -> {
            assertEquals(8,resolvedItemCount(stage),"All quality writes precede the final projection");
            for(var rows:stage.byReceipt().values()) for(var row:rows) {
                assertEquals(0,new BigDecimal("0.7500").compareTo(balance(row.warehouseId(),row.goodsId())),
                        "Each physical stock-in is immediate before the final projection");
            }
            throw new IllegalStateException("final quality projection failed");
        }).when(wakeupTarget).afterQualityReportCompleted(org.mockito.ArgumentMatchers.anyList(),org.mockito.ArgumentMatchers.anyList());
        try {
            assertThrows(IllegalStateException.class,()->inspections.decideReport(request));
        } finally {
            org.mockito.Mockito.doCallRealMethod().when(wakeupTarget)
                    .afterQualityReportCompleted(org.mockito.ArgumentMatchers.anyList(),org.mockito.ArgumentMatchers.anyList());
        }
        assertEquals(before,facts(stage));
        for(var rows:stage.byReceipt().values()) for(var row:rows) {
            assertEquals(0,balance(row.warehouseId(),row.goodsId()).signum());
            assertEquals(0,db.queryForObject("SELECT count(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?",
                    Integer.class,row.id()));
        }
        assertFalse(inspections.decideReport(request).replay());
        assertEquals(8,resolvedItemCount(stage));
    }

    @Test void partialStockThenFailureOnlyResolutionEachRefreshTheSharedAnalysisOnce(){
        Stage stage=prepare();
        SecurityContextHolder.getContext().setAuthentication(stage.actor());
        for(var rows:stage.byReceipt().values()) {
            preStock.preStockIn(rows.getFirst().type(),rows.getFirst().id(),
                    new com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInRequest(
                            rows.stream().map(row -> new com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInItem(
                                    row.inspectionId(),row.warehouseId(),"PARTIAL")).toList()));
        }
        Object spy=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(analyses);
        for(boolean resolve:List.of(false,true)) {
            var request=new BatchInspectionReportRequest(stage.byReceipt().values().stream().map(rows ->
                    new BatchInspectionReportRequest.Receipt(rows.getFirst().type(),rows.getFirst().id(),rows.stream().map(row ->
                            new BatchInspectionDecideRequest.Item(row.inspectionId(),new BigDecimal(resolve?"0.7500":"1.2500"),
                                    new BigDecimal(resolve?"0":"0.5000"),new BigDecimal(resolve?"0.7500":"0"),
                                    "iqc-partial-"+resolve+"-"+row.inspectionId())).toList())).toList(),"剩余不合格结案");
            org.mockito.Mockito.clearInvocations(spy);
            assertFalse(inspections.decideReport(request).replay());
            assertEquals(1,refreshes(stage),resolve?"Failure-only resolved receipts still refresh shortages":"Partial automatic stock-in refreshes without receipt completion");
            assertEquals(resolve?4:0,resolvedItemCount(stage));
            for(var rows:stage.byReceipt().values()) for(var row:rows) {
                assertEquals(0,new BigDecimal("0.5000").compareTo(balance(row.warehouseId(),row.goodsId())));
            }
        }
    }

    /**
     * 40 秒命令截止的余量证据：20 张收货单 × 5 行(100 行、混合类型、共享订货单)整份一次提交，
     * 普通与全预入库(先入库后检，单张最重形态)各量一遍；20 张上限(全预入库实测 ~30s)的余量依据。
     */
    @Test void twentyReceiptBatchCompletesWithinDeadlineBudget()throws Exception{
        isolatePerformanceDelivery();
        Stage stage=prepare(20,5);
        var request=report(stage,null);
        Object analysisSpy=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(analyses);
        org.mockito.Mockito.clearInvocations(analysisSpy);
        long started=System.currentTimeMillis();
        JsonNode result;
        ProductionJdbcMeasurement.Sample measured=ProductionJdbcMeasurement.begin();
        try { result=call(stage,request,200); }
        finally { ProductionJdbcMeasurement.end(); }
        long elapsed=System.currentTimeMillis()-started;
        System.out.println("[decide-report] 20 receipts x 5 lines elapsedMs=" + elapsed);
        System.out.println("[decide-report] breakdown " + json.writeValueAsString(measured.result()));
        assertEquals(20,result.path("receiptCount").asInt());
        assertEquals(100,result.path("lineCount").asInt());
        assertEquals(100,resolvedItemCount(stage));
        assertEquals(1,refreshes(stage),"20 receipt scopes must not refresh the shared analysis 20 times");
        assertTrue(elapsed<30_000,"20 张单的整份报告必须远低于服务端 40s 命令截止，实测 " + elapsed + "ms");
    }

    @Test void preStockedTwentyReceiptBatchAlsoCompletesWithinDeadlineBudget()throws Exception{
        isolatePerformanceDelivery();
        boolean allPass=Boolean.getBoolean("uten.perf.iqc-all-pass");
        int repetitions=Integer.getInteger("uten.perf.iqc-repetitions",1);
        assertTrue(repetitions>=1&&repetitions<=10);
        for(int run=0;run<repetitions;run++) {
        Stage stage=prepare(20,5);
        SecurityContextHolder.getContext().setAuthentication(stage.actor());
        for(var entry:stage.byReceipt().entrySet()){
            var rows=entry.getValue();
            preStock.preStockIn(rows.getFirst().type(),entry.getKey(),new com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInRequest(
                    rows.stream().map(row->new com.uten.imp.features.warehouse.inbound.ProcurementIqcPreStockInContracts.PreStockInItem(
                            row.inspectionId(),row.warehouseId(),"BUDGET-"+row.inspectionId().toString().substring(0,4))).toList()));
        }
        var request=allPass?new BatchInspectionReportRequest(stage.byReceipt().values().stream().map(rows->
                new BatchInspectionReportRequest.Receipt(rows.getFirst().type(),rows.getFirst().id(),rows.stream().map(row->
                        new BatchInspectionDecideRequest.Item(row.inspectionId(),new BigDecimal("1.2500"),
                                new BigDecimal("1.2500"),BigDecimal.ZERO,"iqc-report-key-"+row.inspectionId())).toList())).toList(),null):report(stage,null);
        Object analysisSpy=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(analyses);
        org.mockito.Mockito.clearInvocations(analysisSpy);
        var resources=CommandResourceMeasurement.begin((org.testcontainers.containers.GenericContainer<?>)
                org.springframework.test.util.ReflectionTestUtils.getField(FullChainEndToEndTest.class,"POSTGRES"));
        long started=System.currentTimeMillis();
        JsonNode result;
        ProductionJdbcMeasurement.Sample measured=ProductionJdbcMeasurement.begin();
        Map<String,Object> resourceMetrics;
        long finished;
        try { result=call(stage,request,200); }
        finally { finished=System.currentTimeMillis();resourceMetrics=resources.finish();ProductionJdbcMeasurement.end(); }
        long elapsed=finished-started;
        System.out.println("[decide-report] pre-stocked 20 receipts x 5 lines run="+run+" elapsedMs=" + elapsed
                + " jdbcCalls="+measured.jdbcCalls+" logicalStatements="+measured.logicalStatements);
        String reportDirectory=System.getProperty("uten.perf.quality-report-directory");
        if(reportDirectory!=null){
            var directory=java.nio.file.Path.of(reportDirectory);java.nio.file.Files.createDirectories(directory);
            Map<String,Object> sample=new LinkedHashMap<>(measured.result());
            sample.put("resources",resourceMetrics);
            sample.put("phase",allPass?"iqc-prestock-20x5-all-pass":"iqc-prestock-20x5-mixed");
            sample.put("decisionSplit",Map.of("passedPerLine",allPass?"1.2500":"0.7500","failedPerLine",allPass?"0.0000":"0.5000"));
            sample.put("expectedStockedQuantity",allPass?"125.0000":"75.0000");
            sample.put("elapsedMillis",elapsed);sample.put("run",run);
            sample.put("sourceIdentity",System.getProperty("uten.perf.source-identity","unspecified"));
            sample.put("outboxIsolated",Boolean.getBoolean("uten.perf.isolate-outbox"));
            sample.put("scope","synthetic 20 receipts x 5 rows, mixed purchase/subcontract, real pre-stock; MockMvc full HTTP filters with injected fixture authentication and both real commits; excludes TCP/TLS/JWT verification and client UI");
            sample.put("databaseSettings",db.queryForMap("SELECT current_setting('server_version') AS version,current_setting('fsync') AS fsync,current_setting('synchronous_commit') AS synchronous_commit,current_setting('full_page_writes') AS full_page_writes,(SELECT version FROM flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank DESC LIMIT 1) AS schema_head"));
            json.writerWithDefaultPrettyPrinter().writeValue(directory.resolve("iqc-prestock-20x5-"+run+".json").toFile(),sample);
        }
        assertEquals(20,result.path("receiptCount").asInt());
        assertEquals(100,resolvedItemCount(stage));
        assertEquals(1,refreshes(stage),"100 physical quality lines must retain one final shared-analysis refresh");
        assertPhysicalQualityFacts(stage,new BigDecimal(allPass?"125.0000":"75.0000"));
        Map<String,String> committed=performanceFacts();
        org.mockito.Mockito.clearInvocations(analysisSpy);
        assertTrue(call(stage,request,200).path("replay").asBoolean());
        assertEquals(0,refreshes(stage),"Original-key replay must not refresh analysis again");
        assertEquals(committed,performanceFacts(),"Original-key replay must leave physical, funding and value facts unchanged");
        assertTrue(elapsed<35_000,"全预入库 20 张单也须低于服务端 40s 命令截止(20 张上限的实测依据)，实测 " + elapsed + "ms");
        }
    }

    private void assertQualityValueSources(Stage stage){
        assertEquals(0,db.queryForObject("""
                SELECT COUNT(*) FROM procurement_iqc_quality_consideration_parts part
                JOIN procurement_inspection_events event ON event.id=part.inspection_event_id
                JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id
                LEFT JOIN stock_value_events value ON value.source_doc_type='PROCUREMENT_QUALITY'
                  AND value.source_event_id=part.id AND value.source_item_id=part.id
                WHERE inspection.receipt_id IN (
                """+placeholders(stage)+"""
                ) AND (value.id IS NULL OR value.source_doc_id<>event.id OR value.qty_base<>part.base_qty)
                """,Integer.class,stage.byReceipt().keySet().toArray()),
                "Every PASS/FAIL funding slice retains its original quality-event cost source and quantity");
        assertEquals(0,db.queryForObject("""
                WITH selected AS (
                    SELECT DISTINCT part.consideration_part_id FROM procurement_iqc_quality_consideration_parts part
                    JOIN procurement_inspection_events event ON event.id=part.inspection_event_id
                    JOIN procurement_inspection_items inspection ON inspection.id=event.inspection_item_id
                    WHERE inspection.receipt_id IN (
                """+placeholders(stage)+"""
                ))
                SELECT COUNT(*) FROM selected
                JOIN stock_value_acquisition_sources acquisition ON acquisition.evidence_id=selected.consideration_part_id
                JOIN stock_value_events acquired ON acquired.id=acquisition.event_id
                LEFT JOIN LATERAL (
                    SELECT SUM(value.known_value_local) amount,SUM(value.qty_base) qty
                    FROM procurement_iqc_quality_consideration_parts part
                    JOIN stock_value_events value ON value.source_doc_type='PROCUREMENT_QUALITY'
                      AND value.source_event_id=part.id AND value.source_item_id=part.id
                    WHERE part.consideration_part_id=selected.consideration_part_id
                ) quality ON TRUE
                WHERE quality.amount IS DISTINCT FROM acquired.known_value_local OR quality.qty IS DISTINCT FROM acquired.qty_base
                """,Integer.class,stage.byReceipt().keySet().toArray()),
                "Fully decided funding keeps the exact acquired quantity and recorded money across PASS/FAIL");
    }

    private void assertPhysicalQualityFacts(Stage stage,BigDecimal expected){
        Object[] ids=stage.byReceipt().keySet().toArray();String slots=placeholders(stage);
        assertEquals(100,db.queryForObject("SELECT COUNT(*) FROM procurement_iqc_stock_in_batch_items item JOIN procurement_iqc_stock_in_batches batch ON batch.id=item.batch_id JOIN stock_movements movement ON movement.id=item.stock_movement_id WHERE batch.receipt_id IN ("+slots+")",Integer.class,ids));
        assertEquals(0,expected.compareTo(db.queryForObject("SELECT SUM(warehouse_stocked_base_qty) FROM procurement_inspection_items WHERE receipt_id IN ("+slots+")",BigDecimal.class,ids)));
        assertEquals(0,expected.compareTo(db.queryForObject("SELECT SUM(movement.qty*movement.direction) FROM procurement_iqc_stock_in_batch_items item JOIN procurement_iqc_stock_in_batches batch ON batch.id=item.batch_id JOIN stock_movements movement ON movement.id=item.stock_movement_id WHERE batch.receipt_id IN ("+slots+")",BigDecimal.class,ids)));
        assertEquals(0,expected.compareTo(db.queryForObject("""
                SELECT SUM(balance.qty) FROM stock_balances balance WHERE EXISTS(
                    SELECT 1 FROM procurement_inspection_items inspection
                    WHERE inspection.receipt_id IN (
                """+slots+") AND inspection.goods_id=balance.goods_id AND inspection.color_id IS NOT DISTINCT FROM balance.color_id AND inspection.pre_stocked_warehouse_id=balance.warehouse_id)",BigDecimal.class,ids)));
        assertQualityValueSources(stage);
    }

    private Map<String,String> performanceFacts(){
        Map<String,String> result=new LinkedHashMap<>();
        for(String table:List.of("procurement_inspection_items","procurement_inspection_events",
                "procurement_iqc_stock_in_batches","procurement_iqc_stock_in_batch_items",
                "procurement_iqc_quality_consideration_parts","procurement_iqc_stock_consideration_parts",
                "stock_movements","stock_balances","stock_value_pools","stock_value_events","stock_value_nodes",
                "stock_value_edges","stock_value_postings","stock_value_position_transfers")){
            result.put(table,db.queryForObject("SELECT md5(COALESCE(string_agg(to_jsonb(fact)::text,',' ORDER BY fact.id),'')) FROM "+table+" fact",String.class));
        }
        return result;
    }

    private int resolvedItemCount(Stage stage){
        return db.queryForObject("SELECT count(*) FROM procurement_inspection_items WHERE receipt_id IN ("
                + placeholders(stage) + ") AND status='RESOLVED'",Integer.class,stage.byReceipt().keySet().toArray());
    }

    private long refreshes(Stage stage){
        Object spy=org.springframework.test.util.AopTestUtils.getUltimateTargetObject(analyses);
        return org.mockito.Mockito.mockingDetails(spy).getInvocations().stream().filter(invocation ->
                invocation.getMethod().getName().equals("refreshLocked") && invocation.getArguments().length==1
                        && stage.analysisId().equals(invocation.getArgument(0))).count();
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
