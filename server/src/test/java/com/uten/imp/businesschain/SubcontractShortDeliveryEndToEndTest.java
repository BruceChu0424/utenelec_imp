package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.operations.workbench.FulfillmentTaskRow;
import com.uten.imp.features.operations.workbench.FulfillmentWorkbenchQueryService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeItem;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.OrderQtyChangeRequest;
import com.uten.imp.features.subcontract.order.dto.OrderItemLine;
import com.uten.imp.features.subcontract.order.dto.OrderSaveRequest;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.CaseDetail;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryContracts.DecisionRequest;
import com.uten.imp.features.subcontract.short_delivery.SubcontractShortDeliveryService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest.ArrivalLine;
import com.uten.imp.features.warehouse.inbound.WarehouseArrivalRegistrationService;
import com.uten.imp.features.notice.outbox.BusinessOutboxProcessor;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * V636 / ADR-098 委外允许损耗与回厂短交(真库)：订货带允许损耗并回写主档记忆 → 财务批准 → 出仓 →
 * 第一批回厂低于下限(登记 409 → 仓库确认 → 案件 + 紧急通知) → 判定分批到货 → 第二批仍未到齐(不再通知) →
 * 接受损耗结案(自动损耗单 + 受控改量 + 记损耗率) → 供应商汇总视图。
 */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.policy-intelligence.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractShortDeliveryEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractOrderService orders;
    @Autowired ProcurementFinanceApprovalService financeApproval;
    @Autowired SubcontractMaterialIssueService materialIssues;
    @Autowired WarehouseArrivalRegistrationService arrivals;
    @Autowired SubcontractShortDeliveryService shortDeliveries;
    @Autowired FulfillmentWorkbenchQueryService workbench;
    @Autowired BusinessOutboxProcessor outbox;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementInspectionService inspections;
    @Autowired com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService iqcStockIn;
    FullChainEndToEndTest fixture;
    @BeforeEach void setup(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void logout(){org.springframework.security.core.context.SecurityContextHolder.clearContext();}

    @Test void shortDeliveryIsConfirmedByWarehouseDecidedBySubcontractAndSettledWithLossRatio() {
        var w=fixture.seedWorld("sc-short-delivery");fixture.loginAs(w.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture,"receiveOpeningInputsForA",w,"20"); // goodsE 现货 20，直下委外发目标件。

        // ① 订货 20 件、允许损耗 5%：保存即冻结到本行，并回写货品主档记忆；/last-terms 下次预填 5。
        UUID orderId=orders.create(orderRequest(w,"20","5")).getId();
        UUID itemId=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,orderId);
        rate("5",db.queryForObject("SELECT allowed_loss_pct FROM subcontract_order_items WHERE id=?",BigDecimal.class,itemId));
        rate("5",db.queryForObject("SELECT subcontract_allowed_loss_pct FROM goods WHERE id=?",BigDecimal.class,w.goodsE()));
        var memory=orders.masterDefaultTermsPerGoods(List.of(w.goodsE())).get(w.goodsE());
        assertNotNull(memory);rate("5",memory.allowedLossPct());assertEquals("GOODS_MASTER",memory.allowedLossPctSource());

        // ② 财务批准 → 目标件出仓草稿按计划审核(20 件到供应商处)。
        UUID reviewer=ReflectionTestUtils.invokeMethod(fixture,"createApprover",w);
        financeApproval.submit("SUBCONTRACT",orderId);
        fixture.loginAs(reviewer);fixture.approvePendingFinance("SUBCONTRACT",orderId);fixture.loginAs(w.superAdminUserId());
        UUID issueId=db.queryForObject("""
                SELECT issue.id FROM subcontract_material_issues issue
                JOIN subcontract_material_issue_items item ON item.issue_id=issue.id
                WHERE item.order_item_id=? AND issue.status=0 AND issue.is_deleted=FALSE
                """,UUID.class,itemId);
        materialIssues.approve(issueId);
        rate("20",db.queryForObject("SELECT SUM(at_supplier_qty) FROM subcontract_material_issue_items WHERE order_item_id=?",BigDecimal.class,itemId));

        // ③ 第一批回厂 12：下限 19、短交率 40% → 严重短交，未确认先 409 逐行说明；仓库确认后登记成功。
        ApiException blocked=assertThrows(ApiException.class,()->arrivals.register(arrival(w,itemId,"12",false,"sd-1")));
        assertEquals(ErrorCode.SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED,blocked.getCode());
        assertNotNull(blocked.getFieldErrors());assertEquals(1,blocked.getFieldErrors().size());
        assertEquals(itemId.toString(),blocked.getFieldErrors().getFirst().field());
        String line=blocked.getFieldErrors().getFirst().message();
        assertTrue(line.contains("订 20")&&line.contains("最少应到 19")&&line.contains("累计 12")&&line.contains("少 8")&&line.contains("属严重短交"),line);
        assertEquals(0,count("SELECT COUNT(*) FROM subcontract_short_delivery_cases WHERE order_item_id=?",itemId),"409 之前不得留下任何案件");
        assertEquals(0,count("SELECT COUNT(*) FROM subcontract_receipts r JOIN subcontract_receipt_items i ON i.receipt_id=r.id WHERE i.order_item_id=?",itemId),"409 之前不得建收货单");

        var first=arrivals.register(arrival(w,itemId,"12",true,"sd-1"));
        assertEquals("SUBMITTED_FOR_INSPECTION",first.outcome());
        Map<String,Object> c=caseRow(itemId);
        assertEquals("PENDING_OWNER",c.get("status"));assertEquals("SEVERE",c.get("severity"));
        rate("12",(BigDecimal)c.get("delivered_qty"));rate("8",(BigDecimal)c.get("shortfall_qty"));rate("40",(BigDecimal)c.get("shortfall_pct"));
        rate("19",(BigDecimal)c.get("floor_qty"));assertEquals(1,((Number)c.get("arrival_count")).intValue());
        assertEquals(w.superAdminUserId(),c.get("owner_user_id"));
        UUID caseId=(UUID)c.get("id");
        assertEquals(List.of("DETECTED"),events(caseId));
        drainOutbox();
        assertEquals(1,count("SELECT COUNT(*) FROM notices WHERE source_event='SUBCONTRACT_SHORT_DELIVERY_DETECTED' AND audience_user_id=?",w.superAdminUserId()),
                "订货单制单人收到一张紧急卡; 实际="+db.queryForList("SELECT title||'|'||priority||'|'||type||'|'||COALESCE(aggregate_id::text,'-')||'|'||COALESCE(resolved_reason,'-') FROM notices WHERE source_event='SUBCONTRACT_SHORT_DELIVERY_DETECTED' ORDER BY created_at",String.class)
                        +" outbox="+db.queryForList("SELECT event_type||'|'||status||'|'||COALESCE(dedupe_key,'-') FROM business_outbox WHERE event_type LIKE 'SUBCONTRACT_SHORT_DELIVERY_%' ORDER BY created_at",String.class));
        assertEquals("urgent",db.queryForObject("SELECT priority FROM notices WHERE source_event='SUBCONTRACT_SHORT_DELIVERY_DETECTED' AND audience_user_id=? ORDER BY created_at DESC LIMIT 1",String.class,w.superAdminUserId()));

        // 任务中心：进行中段里这张单状态=回厂短交待判定、异常=SHORT_DELIVERY，红徽章把它算进去。
        FulfillmentTaskRow row=workbenchRow(orderId);
        assertEquals("SHORT_DELIVERY",row.displayStage());assertEquals("SHORT_DELIVERY",row.exceptionCode());
        assertTrue(workbench.countPending("SUBCONTRACT")>=1);
        assertEquals(1,shortDeliveries.counts().pending());assertEquals(0,shortDeliveries.counts().waiting());

        // ③b 「先锁住, 先不入库」(用户口径 2026-09-22)：判定完成前这批货送检合格也不放行入库,
        //     订货单同时锁住不许人工改量; 订货单详情给出面向人的锁定说明。
        UUID keeper=ReflectionTestUtils.invokeMethod(fixture,"createIqcWarehouseConfirmer",w,"sc-short-keeper");
        UUID firstInspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,first.receiptId());
        inspections.dispose("SUBCONTRACT",first.receiptId(),firstInspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                "PASS",null,"回厂件检查合格","sc-short-pass-first"));
        UUID firstPass=db.queryForObject("SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'",UUID.class,firstInspection);
        BigDecimal firstPassed=db.queryForObject("SELECT base_qty FROM procurement_inspection_events WHERE id=?",BigDecimal.class,firstPass);
        fixture.loginAs(keeper);
        ApiException held=assertThrows(ApiException.class,()->iqcStockIn.confirm("SUBCONTRACT",first.receiptId(),stockIn("sc-short-stock-first",firstPass,firstPassed,w)));
        assertEquals(ErrorCode.CONFLICT,held.getCode());
        assertTrue(held.getMessage().contains("先不入库")&&held.getMessage().contains("委外判定"),held.getMessage());
        assertEquals(0,count("SELECT COUNT(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?",first.receiptId()),"被锁期间不得留下入库批次");
        fixture.loginAs(w.superAdminUserId());
        assertNotNull(shortDeliveries.stockInHoldReason(first.receiptId()),"待判定期间入库闸必须拦住");
        ApiException lockedQty=assertThrows(ApiException.class,()->orders.changeQty(orderId,
                new OrderQtyChangeRequest(List.of(new OrderQtyChangeItem(itemId,new BigDecimal("12"))))));
        assertEquals(ErrorCode.CONFLICT,lockedQty.getCode());
        assertTrue(lockedQty.getMessage().contains("判定完成前先锁住不改量"),lockedQty.getMessage());
        rate("20",db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?",BigDecimal.class,itemId));
        var lockedDetail=orders.detail(orderId).getShortDeliveryHold();
        assertNotNull(lockedDetail,"订货单详情要给出锁定说明");
        assertEquals(caseId,lockedDetail.caseId());assertEquals(1,lockedDetail.caseCount());
        assertFalse(lockedDetail.overdue());
        assertTrue(lockedDetail.summary().contains("先不入库")&&lockedDetail.summary().contains("不改量"),lockedDetail.summary());

        // ④ 判定分批到货：预计一周内到齐 → 分批等待中，卡片撤回。
        long version=((Number)c.get("version")).longValue();
        CaseDetail waiting=shortDeliveries.decide(caseId,new DecisionRequest("WAIT_MORE",BusinessTime.today().plusDays(7),"委外商答复下周补齐",version));
        assertEquals("WAITING_MORE",waiting.row().status());assertEquals(BusinessTime.today().plusDays(7),waiting.row().expectedCompleteBy());
        assertEquals(List.of("DETECTED","WAIT_MORE_DECIDED"),events(caseId));
        drainOutbox();
        assertEquals(1,count("SELECT COUNT(*) FROM notices WHERE source_event='SUBCONTRACT_SHORT_DELIVERY_DETECTED' AND audience_user_id=? AND resolved_at IS NOT NULL",w.superAdminUserId()),
                "判定后原卡片办结撤回");
        assertEquals("WAITING_MORE_BATCH",workbenchRow(orderId).displayStage());
        assertEquals(1,shortDeliveries.counts().waiting());assertEquals(0,shortDeliveries.counts().pending());

        // ④b 判定完成即解锁：先到的 12 件可以入库了(剩下的按分批继续等)；订货单详情不再提示锁定。
        assertNull(shortDeliveries.stockInHoldReason(first.receiptId()),"判定完成后入库闸放行");
        assertNull(orders.detail(orderId).getShortDeliveryHold(),"判定完成后详情不再提示锁定");
        fixture.loginAs(keeper);
        iqcStockIn.confirm("SUBCONTRACT",first.receiptId(),stockIn("sc-short-stock-first",firstPass,firstPassed,w));
        fixture.loginAs(w.superAdminUserId());
        assertEquals(1,count("SELECT COUNT(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?",first.receiptId()),"解锁后先到的 12 件正常入库");

        // ④c 两条边界(发布会话提的风险, 都真跑一遍而不是读代码确认)：
        //   1) 预计到齐日「就是今天」不算逾期、不锁；退到昨天才锁。比较一律用库里的 CURRENT_DATE,
        //      避免 JVM 与容器时区不一致让临界日判定漂一天。
        //   2) 已经成功的入库按同一幂等键重放, 即使此刻单子又被锁住, 也照常返回原批次不被改判成 409
        //      (幂等在 confirmCommands 里先短路, 根本走不到挂闸的 confirmOne)。
        db.update("UPDATE subcontract_short_delivery_cases SET expected_complete_by = CURRENT_DATE WHERE id = ?",caseId);
        assertNull(shortDeliveries.stockInHoldReason(first.receiptId()),"预计到齐日就是今天, 还没逾期, 不该锁");
        db.update("UPDATE subcontract_short_delivery_cases SET expected_complete_by = CURRENT_DATE - 1 WHERE id = ?",caseId);
        assertNotNull(shortDeliveries.stockInHoldReason(first.receiptId()),"分批到货过了预计到齐日, 要重新锁住");
        assertNotNull(orders.detail(orderId).getShortDeliveryHold(),"逾期重新锁住时详情也要提示");
        assertTrue(orders.detail(orderId).getShortDeliveryHold().overdue(),"这次锁定的原因是分批到货逾期");
        fixture.loginAs(keeper);
        var replayed=iqcStockIn.confirm("SUBCONTRACT",first.receiptId(),stockIn("sc-short-stock-first",firstPass,firstPassed,w));
        assertTrue(replayed.replayed(),"已成功的入库重放必须原样返回, 不能被闸门改判");
        assertEquals(1,count("SELECT COUNT(*) FROM procurement_iqc_stock_in_batches WHERE receipt_id=?",first.receiptId()),"重放不得多出批次");
        fixture.loginAs(w.superAdminUserId());
        db.update("UPDATE subcontract_short_delivery_cases SET expected_complete_by = ? WHERE id = ?",BusinessTime.today().plusDays(7),caseId);
        assertNull(shortDeliveries.stockInHoldReason(first.receiptId()),"改回未到期后重新放行");

        // ⑤ 第二批 5 件：累计 17 仍低于下限 19 → 仓库仍要确认(弹窗说明已判定分批)，但案件只刷新数字、不再通知。
        ApiException again=assertThrows(ApiException.class,()->arrivals.register(arrival(w,itemId,"5",false,"sd-2")));
        assertEquals(ErrorCode.SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED,again.getCode());
        assertTrue(again.getFieldErrors().getFirst().message().contains("委外已判定分批到货"),again.getFieldErrors().getFirst().message());
        var second=arrivals.register(arrival(w,itemId,"5",true,"sd-2"));
        c=caseRow(itemId);
        assertEquals("WAITING_MORE",c.get("status"));assertEquals("BELOW_FLOOR",c.get("severity"));
        rate("17",(BigDecimal)c.get("delivered_qty"));rate("3",(BigDecimal)c.get("shortfall_qty"));rate("15",(BigDecimal)c.get("shortfall_pct"));
        assertEquals(2,((Number)c.get("arrival_count")).intValue());
        assertEquals(List.of("DETECTED","WAIT_MORE_DECIDED","REDETECTED"),events(caseId));
        drainOutbox();
        assertEquals(1,count("SELECT COUNT(*) FROM notices WHERE source_event='SUBCONTRACT_SHORT_DELIVERY_DETECTED' AND audience_user_id=?",w.superAdminUserId()),
                "分批等待未过预计到齐日：再次到货不再打扰");

        // ⑥ 接受损耗结案：损耗单核销供应商处剩下的 3 件(允许 1 件 + 超耗 2 件) → 订货量改为 17 → 记 15% 损耗。
        long version2=((Number)c.get("version")).longValue();
        CaseDetail accepted=shortDeliveries.decide(caseId,new DecisionRequest("ACCEPT_LOSS",null,"委外商确认 3 件加工报废",version2));
        assertEquals("ACCEPTED_LOSS",accepted.row().status());
        rate("3",accepted.row().lossQty());rate("15",accepted.row().lossPct());
        assertNotNull(accepted.row().wasteId());assertNotNull(accepted.row().wasteBillNo());
        assertEquals(1,count("SELECT COUNT(*) FROM subcontract_wastes WHERE id=? AND status=1",accepted.row().wasteId()));
        rate("3",db.queryForObject("SELECT SUM(qty) FROM subcontract_waste_items WHERE waste_id=?",BigDecimal.class,accepted.row().wasteId()));
        rate("1",db.queryForObject("SELECT SUM(standard_qty) FROM subcontract_waste_items WHERE waste_id=?",BigDecimal.class,accepted.row().wasteId()));
        rate("3",db.queryForObject("SELECT SUM(wasted_qty) FROM subcontract_material_issue_items WHERE order_item_id=?",BigDecimal.class,itemId));
        rate("17",db.queryForObject("SELECT qty FROM subcontract_order_items WHERE id=?",BigDecimal.class,itemId));
        assertFalse(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?",Boolean.class,orderId),
                "结案不等于入库：17 件仍在质检, 订货单按既有口径(仓库实收净量≥订货量)要等 IQC 合格入库后才关闭");
        assertEquals("CLOSED",db.queryForObject("SELECT status FROM inbound_expectations WHERE order_type='SUBCONTRACT' AND order_id=?",String.class,orderId));
        assertEquals(1,count("SELECT COUNT(*) FROM procurement_order_qty_change_logs WHERE order_type='SUBCONTRACT' AND order_item_id=? AND old_qty=20 AND new_qty=17",itemId));
        assertNotNull(db.queryForObject("SELECT qty_change_log_id FROM subcontract_short_delivery_cases WHERE id=?",UUID.class,caseId));
        assertEquals(1,count("SELECT COUNT(*) FROM procurement_order_approval_cases WHERE order_type='SUBCONTRACT' AND order_id=? AND status='PENDING'",orderId),
                "受控改量自动开财务复核");
        assertEquals("OPEN",db.queryForObject("SELECT status FROM subcontract_loss_cases WHERE waste_id=?",String.class,accepted.row().wasteId()),
                "超出允许损耗的 2 件转财务责任判定");
        rate("20",db.queryForObject("SELECT ordered_qty FROM subcontract_short_delivery_cases WHERE id=?",BigDecimal.class,caseId));
        assertEquals(List.of("DETECTED","WAIT_MORE_DECIDED","REDETECTED","ACCEPT_LOSS_DECIDED"),events(caseId));
        assertEquals(0,shortDeliveries.counts().pending());assertEquals(0,shortDeliveries.counts().waiting());
        assertEquals("RECEIVED_PENDING_STOCK",workbenchRow(orderId).displayStage(),"回厂 17 ≥ 改后订货 17：状态列=已回厂待入库(结案不等于入库)");

        // ⑥b 第二张收货单 IQC 合格 5 件 → 仓库确认入库(第一张 12 件已在 ④b 解锁后入库)：
        //     实收净量 17 ≥ 改后订货量 17, 订货单按既有结案口径关闭。
        for(var receipt:List.of(second)){
            UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=?",UUID.class,receipt.receiptId());
            fixture.loginAs(w.superAdminUserId());
            inspections.dispose("SUBCONTRACT",receipt.receiptId(),inspection,new com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest(
                    "PASS",null,"回厂件检查合格","sc-short-pass-"+receipt.receiptBillNo()));
            UUID pass=db.queryForObject("SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'",UUID.class,inspection);
            BigDecimal passed=db.queryForObject("SELECT base_qty FROM procurement_inspection_events WHERE id=?",BigDecimal.class,pass);
            fixture.loginAs(keeper);
            iqcStockIn.confirm("SUBCONTRACT",receipt.receiptId(),new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest(
                    "sc-short-stock-"+receipt.receiptBillNo(),List.of(new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem(
                            pass,passed,passed,"SC-SHORT-01",w.warehouseId()))));
        }
        fixture.loginAs(w.superAdminUserId());
        assertTrue(db.queryForObject("SELECT is_closed FROM subcontract_orders WHERE id=?",Boolean.class,orderId),"17 件入库后订货单关闭");
        assertEquals("ACCEPTED_LOSS",db.queryForObject("SELECT status FROM subcontract_short_delivery_cases WHERE id=?",String.class,caseId),"入库不改变已结案案件");
        assertNull(workbenchRowOrNull(orderId),"订货单关闭后离开进行中(task_status=COMPLETED 归历史)");

        // ⑦ 供应商汇总：1 行结清、1 次接受损耗、订 20 损 3 → 15%。
        Map<String,Object> summary=db.queryForMap("SELECT * FROM v_subcontract_supplier_loss_summary WHERE supplier_id=?",w.supplierId());
        assertEquals(1L,((Number)summary.get("settled_line_count")).longValue());
        assertEquals(1L,((Number)summary.get("accepted_loss_count")).longValue());
        rate("20",(BigDecimal)summary.get("ordered_qty"));rate("3",(BigDecimal)summary.get("loss_qty"));rate("15",(BigDecimal)summary.get("loss_pct"));
        var service=shortDeliveries.supplierSummary(w.supplierId());
        rate("15",service.lossPct());assertEquals(1,service.byGoods().size());assertEquals(w.goodsE(),service.byGoods().getFirst().goodsId());
        assertEquals(1,service.recentCases().size());assertEquals(caseId,service.recentCases().getFirst().id());
        // 结案后判定页历史段能看到, 待判定/等待段没有。
        assertEquals(1,shortDeliveries.list("HISTORY",null,w.supplierId(),null,null,null,1,20).getTotal());
        assertEquals(0,shortDeliveries.list("PENDING",null,null,orderId,null,null,1,20).getTotal());
    }

    @Test void completeArrivalAndUnsetToleranceNeverAskTheWarehouseAndCloseWaitingCasesOnArrival() {
        var w=fixture.seedWorld("sc-short-complete");fixture.loginAs(w.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture,"receiveOpeningInputsForA",w,"10");
        // 未设允许损耗：短交只开中性案件, 登记不需要确认; 到齐后案件自然完成。
        UUID orderId=orders.create(orderRequest(w,"10",null)).getId();
        UUID itemId=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,orderId);
        assertNull(db.queryForObject("SELECT allowed_loss_pct FROM subcontract_order_items WHERE id=?",BigDecimal.class,itemId));
        UUID reviewer=ReflectionTestUtils.invokeMethod(fixture,"createApprover",w);
        financeApproval.submit("SUBCONTRACT",orderId);
        fixture.loginAs(reviewer);fixture.approvePendingFinance("SUBCONTRACT",orderId);fixture.loginAs(w.superAdminUserId());
        UUID issueId=db.queryForObject("""
                SELECT issue.id FROM subcontract_material_issues issue
                JOIN subcontract_material_issue_items item ON item.issue_id=issue.id
                WHERE item.order_item_id=? AND issue.status=0 AND issue.is_deleted=FALSE
                """,UUID.class,itemId);
        materialIssues.approve(issueId);

        assertEquals("SUBMITTED_FOR_INSPECTION",arrivals.register(arrival(w,itemId,"4",false,"sc-1")).outcome(),"未设允许损耗不弹窗");
        Map<String,Object> c=caseRow(itemId);
        assertEquals("PENDING_OWNER",c.get("status"));assertEquals("UNSET_TOLERANCE",c.get("severity"));
        drainOutbox();
        assertEquals(0,count("SELECT COUNT(*) FROM notices WHERE source_event='SUBCONTRACT_SHORT_DELIVERY_DETECTED' AND audience_user_id=?",w.superAdminUserId()),
                "中性案件不发紧急通知");
        // 中性案件：任务中心状态列「容差内待结案」不标红、不算异常；红徽章不计, 判定页计入容差内段。
        assertEquals("TOLERANT_SHORT",workbenchRow(orderId).displayStage());
        assertNull(workbenchRow(orderId).exceptionCode());
        assertEquals(0,shortDeliveries.counts().pending());assertEquals(1,shortDeliveries.counts().tolerant());
        assertEquals(1,shortDeliveries.list("TOLERANT",null,null,orderId,null,null,1,20).getTotal());

        assertEquals("SUBMITTED_FOR_INSPECTION",arrivals.register(arrival(w,itemId,"6",false,"sc-2")).outcome(),"到齐不弹窗");
        assertEquals("COMPLETED",db.queryForObject("SELECT status FROM subcontract_short_delivery_cases WHERE id=?",String.class,c.get("id")));
        assertNotNull(db.queryForObject("SELECT closed_at FROM subcontract_short_delivery_cases WHERE id=?",java.sql.Timestamp.class,c.get("id")));
        assertEquals(List.of("DETECTED","COMPLETED"),events((UUID)c.get("id")));
        assertEquals(0,count("SELECT COUNT(*) FROM subcontract_short_delivery_cases WHERE order_item_id=? AND status IN ('PENDING_OWNER','WAITING_MORE')",itemId));
        // 完整到货的行不进汇总损耗(损耗 0), 但算结清行。
        Map<String,Object> summary=db.queryForMap("SELECT * FROM v_subcontract_supplier_loss_summary WHERE supplier_id=?",w.supplierId());
        assertEquals(1L,((Number)summary.get("settled_line_count")).longValue());
        rate("0",(BigDecimal)summary.get("loss_pct"));
    }

    // ===================== helpers =====================

    private OrderSaveRequest orderRequest(FullChainEndToEndTest.World w,String qty,String allowedLossPct){
        var request=new OrderSaveRequest();
        request.setBillDate(BusinessTime.today());request.setDeliverDate(BusinessTime.today().plusDays(3));
        request.setSupplierId(w.supplierId());request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId());request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(ReflectionTestUtils.invokeMethod(fixture,"activeSettlementMethodId"));
        var line=new OrderItemLine();
        line.setGoodsId(w.goodsE());line.setUnitId(w.unitId());line.setUnitRate(BigDecimal.ONE);
        line.setQty(new BigDecimal(qty));line.setPrice(new BigDecimal("10"));
        if(allowedLossPct!=null)line.setAllowedLossPct(new BigDecimal(allowedLossPct));
        request.setItems(List.of(line));
        return request;
    }

    private WarehouseArrivalRegisterRequest arrival(FullChainEndToEndTest.World w,UUID itemId,String qty,boolean acknowledged,String key){
        return new WarehouseArrivalRegisterRequest(
                "short-delivery-"+key+"-"+itemId,"SUBCONTRACT",BusinessTime.today(),w.supplierId(),w.warehouseId(),
                null,w.employeeId(),null,
                List.of(new ArrivalLine(w.goodsE(),new BigDecimal(qty),itemId,null,w.unitId(),BigDecimal.ONE,null,null)),
                null,acknowledged?Boolean.TRUE:null);
    }

    private com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest stockIn(
            String key,UUID passEventId,BigDecimal qty,FullChainEndToEndTest.World w){
        return new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmRequest(
                key,List.of(new com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.ConfirmItem(
                        passEventId,qty,qty,"SC-SHORT-01",w.warehouseId())));
    }

    private Map<String,Object> caseRow(UUID itemId){
        return db.queryForMap("SELECT * FROM subcontract_short_delivery_cases WHERE order_item_id=? ORDER BY detected_at DESC LIMIT 1",itemId);
    }

    private List<String> events(UUID caseId){
        return db.queryForList("SELECT event_type FROM subcontract_short_delivery_case_events WHERE case_id=? ORDER BY created_at, id",String.class,caseId);
    }

    private FulfillmentTaskRow workbenchRow(UUID orderId){
        FulfillmentTaskRow row=workbenchRowOrNull(orderId);
        assertNotNull(row,"任务中心进行中段应有这张订货单");
        return row;
    }

    private FulfillmentTaskRow workbenchRowOrNull(UUID orderId){
        return workbench.query("SUBCONTRACT","IN_PROGRESS","",null,null,null,1,100).items().stream()
                .filter(r->orderId.equals(r.actionDocId())).findFirst().orElse(null);
    }

    /**
     * 把短交事件投递干净。
     *
     * <p>2026-09-21 修:原先"立刻连打 60 次 processNext"会偶发红(CI 与本机都复现过)。
     * 真因是 Spring 上下文里的后台 outbox 线程与本用例并发投递:它撞上履约来源冲突
     * (等锁期间来源集合变了,属设计内的瞬时冲突)后,失败记录器按 power(2, attempts) 秒
     * 把 available_at 推到将来,而 processNext 只取 available_at &lt;= now() 的事件——
     * 于是那 60 次一条也取不到,断言必红。这里改成:每轮先抹平退避再投递,按时间兜底等待;
     * 本线程投递时抛出的瞬时冲突不记 attempts,下一轮直接重投。
     */
    private void drainOutbox(){
        String pending="SELECT COUNT(*) FROM business_outbox "
                +"WHERE status<>1 AND event_type LIKE 'SUBCONTRACT_SHORT_DELIVERY_%'";
        long deadline=System.currentTimeMillis()+60_000;
        while(true){
            db.update("UPDATE business_outbox SET available_at=now() "
                    +"WHERE status=0 AND available_at>now()");
            try{
                for(int i=0;i<200&&outbox.processNext();i++){ /* 投到取不出为止 */ }
            }catch(RuntimeException transientDeliveryFailure){
                // 瞬时冲突:本线程没走失败记录器,attempts 未加,下一轮抹平退避后重投。
            }
            if(count(pending)==0) return;
            if(System.currentTimeMillis()>deadline) break;
            try{ Thread.sleep(50); }
            catch(InterruptedException interrupted){ Thread.currentThread().interrupt(); break; }
        }
        assertFalse(count(pending)>0,"短交事件必须全部投递完成");
    }

    private int count(String sql,Object... args){
        Integer n=db.queryForObject(sql,Integer.class,args);
        return n==null?0:n;
    }

    private static void rate(String expected,BigDecimal actual){
        assertNotNull(actual);
        assertEquals(0,new BigDecimal(expected).compareTo(actual),"expected "+expected+" but was "+actual);
    }
}
