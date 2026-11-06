package com.uten.imp.businesschain;

import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.finance.procurement.ProcurementApprovalContracts.BatchDecisionItem;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.ReflectionTestUtils;

import javax.sql.DataSource;
import java.math.BigDecimal;
import java.util.*;

import static org.assertj.core.api.Assertions.*;

/** Only actual public owner commands create approvals, issues, IQC and return movements.
 * Anonymous master/BOM inputs use the existing fixture; no status1, case, physical or value-row insert. */
final class HistoricalSubcontractCommandFixture {
    record Original(String family,UUID document,UUID item,UUID actor,UUID physicalFact,BigDecimal physicalQuantity,
                    String headerBeforeUpgrade,String itemBeforeUpgrade,String physicalBeforeUpgrade) { }
    record Originals(Original receipt,Original materialReturn) { }
    private HistoricalSubcontractCommandFixture() { }

    static Originals seed1032(DataSource source,String url,String username,String password)throws Exception {
        String guards=HistoricalSubcontract1032Context.guardDefinitions(new JdbcTemplate(source));
        try(var context=HistoricalSubcontract1032Context.open(source,url,username,password);
            var selected=BusinessPrecisionContext.use(Map.of("stock.value.interval",new BusinessPrecisionContext.Choice(12,"HALF_UP"),
                    "money.cumulative-share",new BusinessPrecisionContext.Choice(24,"DOWN")))) {
            var db=context.getBean(JdbcTemplate.class);var fixture=new FullChainEndToEndTest();context.getAutowireCapableBeanFactory().autowireBean(fixture);
            var world=fixture.seedWorld("original1032-subcontract-"+UUID.randomUUID());fixture.loginAs(world.superAdminUserId());
            UUID material=fixture.addSubcontractDirectMaterial(world,world.goodsE(),"1");
            fixture.receiveSubcontractMaterial(world,material,"100");
            UUID alternate=UUID.randomUUID();db.update("INSERT INTO units(id,code,name,status) VALUES(?,?,?,'使用')",alternate,"ORIGINAL1032-"+alternate,"匿名原换算单位");
            var orders=context.getBean(SubcontractOrderService.class);
            var request=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
            request.setBillDate(BusinessTime.today());request.setSupplierId(world.supplierId());request.setWarehouseId(world.warehouseId());
            request.setCurrencyId(db.queryForObject("SELECT id FROM currencies WHERE is_base_currency AND NOT is_deleted",UUID.class));
            request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);
            request.setSettlementMethodId(db.queryForObject("SELECT id FROM settlement_methods WHERE status='使用' AND NOT is_deleted ORDER BY code LIMIT 1",UUID.class));
            var line=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();line.setGoodsId(world.goodsE());line.setUnitId(alternate);
            line.setUnitRate(new BigDecimal("1.00005"));line.setQty(new BigDecimal("20"));line.setPrice(BigDecimal.TEN);request.setItems(List.of(line));
            UUID order=orders.create(request).getId();assertThat(db.queryForObject("SELECT status FROM subcontract_orders WHERE id=?",Integer.class,order)).isZero();
            UUID orderItem=db.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=?",UUID.class,order);
            UUID reviewer=fixture.createUserWithPerms(world,"original1032-finance-"+UUID.randomUUID(),"finance_order_approval:view","finance_order_approval:approve");
            UUID reviewerEmployee=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,reviewer);
            assertThat(reviewerEmployee).isNotEqualTo(world.employeeId());
            fixture.loginAs(world.superAdminUserId());var finance=context.getBean(ProcurementFinanceApprovalService.class);finance.submit("SUBCONTRACT",order);
            var pending=db.queryForMap("SELECT id,version FROM procurement_order_approval_cases WHERE order_type='SUBCONTRACT' AND order_id=? AND status='PENDING'",order);
            UUID approval=(UUID)pending.get("id");fixture.loginAs(reviewer);
            UUID claim=context.getBean(TaskClaimService.class).claim("PROCUREMENT_FINANCE_APPROVE",approval.toString()).claimId();
            finance.approveBatch(List.of(new BatchDecisionItem(approval,((Number)pending.get("version")).longValue(),claim)),"匿名原版本真实独立财务批准",BigDecimal.ONE);
            assertThat(db.queryForObject("SELECT status FROM procurement_order_approval_cases WHERE id=?",String.class,approval)).isEqualTo("APPROVED");
            assertThat(db.queryForObject("SELECT decided_by_employee_id FROM procurement_order_approval_cases WHERE id=?",UUID.class,approval)).isEqualTo(reviewerEmployee);
            assertThat(db.queryForObject("SELECT approver_id FROM subcontract_orders WHERE id=?",UUID.class,order)).isEqualTo(reviewerEmployee);
            assertThat(db.queryForObject("SELECT status FROM subcontract_orders WHERE id=?",Integer.class,order)).isEqualTo(1);
            fixture.loginAs(world.superAdminUserId());
            List<UUID> issues=fixture.drawAndIssueSubcontract(orderItem,new BigDecimal("20"),"original1032-draw-"+UUID.randomUUID());
            assertThat(issues).hasSize(1);UUID issue=issues.getFirst();
            UUID issueItem=db.queryForObject("SELECT id FROM subcontract_material_issue_items WHERE issue_id=? AND NOT is_deleted",UUID.class,issue);
            assertThat(db.queryForObject("SELECT unit_rate FROM subcontract_material_issue_items WHERE id=?",BigDecimal.class,issueItem)).isEqualByComparingTo("1");
            assertThat(db.queryForObject("SELECT count(*) FROM stock_movements WHERE source_doc_type='SUBCONTRACT_MATERIAL_ISSUE' AND source_doc_id=? AND source_item_id=? AND movement_type=15 AND direction=-1",Integer.class,issue,issueItem)).isEqualTo(1);

            // V798 freezes material issue units at the real plan's rate1. Keep
            // the unrelated unknown historical1.00005 record as a rejection case.
            var returns=context.getBean(SubcontractMaterialReturnService.class);
            var returned=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnSaveRequest();
            returned.setBillDate(BusinessTime.today());returned.setSupplierId(world.supplierId());returned.setWarehouseId(world.warehouseId());
            var returnedLine=new com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemLine();
            returnedLine.setGoodsId(material);returnedLine.setUnitId(world.unitId());returnedLine.setUnitRate(BigDecimal.ONE);returnedLine.setQty(BigDecimal.ONE);
            returnedLine.setPrice(BigDecimal.TEN);returnedLine.setMaterialIssueItemId(issueItem);returnedLine.setOrderItemId(orderItem);returnedLine.setParentGoodsId(world.goodsE());
            returned.setItems(List.of(returnedLine));UUID returnId=returns.create(returned).getId();returns.approve(returnId);
            UUID returnItem=db.queryForObject("SELECT id FROM subcontract_material_return_items WHERE material_return_id=?",UUID.class,returnId);
            var physicalReturn=db.queryForMap("SELECT id,qty FROM stock_movements WHERE source_doc_type='SUBCONTRACT_MATERIAL_RETURN' AND source_doc_id=? AND source_item_id=? AND movement_type=16 AND direction=1",returnId,returnItem);
            assertThat((BigDecimal)physicalReturn.get("qty")).isEqualByComparingTo("1");

            var receipts=context.getBean(SubcontractReceiptService.class);
            var receipt=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();receipt.setBillDate(BusinessTime.today());
            receipt.setSupplierId(world.supplierId());receipt.setWarehouseId(world.warehouseId());receipt.setExchangeRate(BigDecimal.ONE);
            var receiptLine=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();receiptLine.setGoodsId(world.goodsE());receiptLine.setUnitId(alternate);
            receiptLine.setUnitRate(new BigDecimal("1.00005"));receiptLine.setQty(BigDecimal.ONE);receiptLine.setPrice(BigDecimal.TEN);receiptLine.setOrderItemId(orderItem);
            receipt.setItems(List.of(receiptLine));UUID receiptId=receipts.create(receipt).getId();receipts.approve(receiptId);
            UUID receiptItem=db.queryForObject("SELECT id FROM subcontract_receipt_items WHERE receipt_id=?",UUID.class,receiptId);
            UUID inspection=db.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type='SUBCONTRACT' AND receipt_id=? AND receipt_item_id=?",UUID.class,receiptId,receiptItem);
            context.getBean(ProcurementInspectionService.class).dispose("SUBCONTRACT",receiptId,inspection,new InspectionDispositionRequest("PASS",null,"匿名真实旧版质检放行","original1032-pass-"+inspection));
            UUID keeper=ReflectionTestUtils.invokeMethod(fixture,"createIqcWarehouseConfirmer",world,"original1032-warehouse-"+receiptId);fixture.loginAs(keeper);
            var stock=ReflectionTestUtils.<ProcurementIqcStockInContracts.ConfirmRequest>invokeMethod(fixture,"latestIqcStockInRequest","SUBCONTRACT",receiptId,inspection,new BigDecimal("1.00005"),"original1032-stock-"+inspection,"ORIGINAL1032-BIN");
            var stockOwner=context.getBean(ProcurementIqcStockInService.class);
            var stored=stockOwner.confirm("SUBCONTRACT",receiptId,stock);
            assertThat(stockOwner.confirm("SUBCONTRACT",receiptId,stock).batchId()).isEqualTo(stored.batchId());
            fixture.loginAs(world.superAdminUserId());ReflectionTestUtils.invokeMethod(fixture,"drainCosts",world);
            assertThat(db.queryForObject("SELECT received_base_qty FROM procurement_inspection_items WHERE id=?",BigDecimal.class,inspection)).isEqualByComparingTo("1.00005");
            assertThat(db.queryForObject("SELECT count(*) FROM procurement_iqc_stock_in_batch_items WHERE inspection_item_id=?",Integer.class,inspection)).isEqualTo(1);
            assertThat(db.queryForObject("SELECT count(*) FROM subcontract_receipt_material_consumptions WHERE receipt_item_id=? AND reversal_of IS NULL",Integer.class,receiptItem)).isPositive();
            assertThat(db.queryForObject("SELECT count(*) FROM stock_value_production_cost_objects WHERE execution_segment_id=? AND source_kind='SUBCONTRACT_RECEIPT_ITEM'",Integer.class,receiptItem)).isEqualTo(1);
            HistoricalSubcontract1032Context.requireOriginalCatalog(db);
            assertThat(HistoricalSubcontract1032Context.guardDefinitions(db)).isEqualTo(guards);
            return new Originals(original(db,"subcontractReceipt","subcontract_receipts","subcontract_receipt_items",receiptId,receiptItem,world.superAdminUserId(),inspection,new BigDecimal("1.00005")),
                    original(db,"subcontractMaterialReturn","subcontract_material_returns","subcontract_material_return_items",returnId,returnItem,world.superAdminUserId(),(UUID)physicalReturn.get("id"),(BigDecimal)physicalReturn.get("qty")));
        } finally {SecurityContextHolder.clearContext();}
    }
    private static Original original(JdbcTemplate db,String family,String header,String table,UUID document,UUID item,UUID actor,UUID physical,BigDecimal quantity) {
        String physicalTable=family.equals("subcontractReceipt")?"procurement_inspection_items":"stock_movements";
        return new Original(family,document,item,actor,physical,quantity,
                db.queryForObject("SELECT to_jsonb(value)::text FROM "+header+" value WHERE id=?",String.class,document),
                db.queryForObject("SELECT to_jsonb(value)::text FROM "+table+" value WHERE id=?",String.class,item),
                db.queryForObject("SELECT to_jsonb(value)::text FROM "+physicalTable+" value WHERE id=?",String.class,physical));
    }
}
