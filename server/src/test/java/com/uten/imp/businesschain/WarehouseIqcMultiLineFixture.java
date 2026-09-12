package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.finance.procurement.ProcurementFinanceApprovalService;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.purchase.order.PurchaseOrderService;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.stock.StockDocService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.order.SubcontractOrderService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.*;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;
import static com.uten.imp.businesschain.WarehouseIqcScaleFixture.RECEIPT_QTY;

/** Each receipt contains distinct current order-item/SKU sources, never repeated rows to inflate scale. */
final class WarehouseIqcMultiLineFixture {
    private final FullChainEndToEndTest masters;
    private final AutowireCapableBeanFactory beans;
    private final JdbcTemplate jdbc;
    WarehouseIqcMultiLineFixture(AutowireCapableBeanFactory beans,JdbcTemplate jdbc) {
        this.beans=beans;this.jdbc=jdbc;masters=new FullChainEndToEndTest();beans.autowireBean(masters);
    }

    WarehouseIqcScaleFixture.Scenario prepare(int receipts,int lines,String tag) {
        if(receipts<2||receipts>20||receipts%2!=0||lines<2||lines>100||receipts*lines>300)
            throw new IllegalArgumentException("Use a legal even receipt count and no more than 300 real lines");
        var w=masters.seedWorld(tag);
        UUID first=leaf(w,tag+"-a"),second=leaf(w,tag+"-b");
        List<UUID> buys=new ArrayList<>(List.of(w.goodsD()));
        List<UUID> subs=new ArrayList<>(List.of(w.goodsE()));
        for(int i=1;i<lines;i++) {
            UUID buy=UUID.randomUUID(),sub=UUID.randomUUID();
            masters.insertGoods(buy,"IQP-"+tag+"-"+i,"Distinct purchased scale SKU "+i,"采购",w.unitId(),w.unitLegacy());
            masters.insertGoods(sub,"IQS-"+tag+"-"+i,"Distinct subcontract scale SKU "+i,"委外",w.unitId(),w.unitLegacy());
            buys.add(buy);subs.add(sub);
        }
        BigDecimal required=RECEIPT_QTY.multiply(BigDecimal.valueOf(receipts/2));
        masters.loginAs(w.superAdminUserId());
        UUID settlement=ReflectionTestUtils.invokeMethod(masters,"activeSettlementMethodId");
        UUID reviewer=ReflectionTestUtils.invokeMethod(masters,"createApprover",w);
        assertNotNull(settlement);assertNotNull(reviewer);
        for(UUID goods:buys)jdbc.update("UPDATE goods SET default_supplier_id=? WHERE id=?",w.supplierId(),goods);
        for(UUID goods:subs)jdbc.update("UPDATE goods SET default_supplier_id=? WHERE id=?",w.supplierId(),goods);
        openAndIssueSubcontract(w,first,subs,required,settlement,reviewer);
        Map<UUID,UUID> subItems=orderItems("subcontract",w.supplierId());
        assertEquals(lines,subItems.size());

        UUID finished=UUID.randomUUID();
        masters.insertGoods(finished,"IQF-"+tag,"Multi SKU IQC scale finished","自制",w.unitId(),w.unitLegacy());
        for(UUID goods:buys)masters.insertBom(finished,goods,"1");
        for(UUID goods:subs)masters.insertBom(finished,goods,"1");
        var analysis=beans.getBean(MaterialAnalysisService.class);
        var view=analysis.preview(new PreviewRequest(null,null,null,w.warehouseId(),"iqc-large-preview-"+tag,
                List.of(new PreviewItem("OTHER",null,finished,null,w.unitId(),"IQC-LARGE-"+tag,"Distinct SKU batch verification",BusinessTime.today(),required))));
        var buyRows=view.flatMaterials().stream().filter(row->buys.contains(row.goodsId())&&row.actionable()).toList();
        assertEquals(lines,buyRows.size());
        var routed=analysis.saveRoutes(view.analysisId(),new RouteRequest(view.version(),view.fingerprint(),"iqc-large-route-"+tag,
                buyRows.stream().map(row->new RouteDecision(row.materialLineId(),row.actionGroupKey(),"BUY",null)).toList()));
        beans.getBean(MaterialAnalysisCommandService.class).notifySupply(view.analysisId(),new NotifyRequest(routed.version(),routed.fingerprint(),
                "iqc-large-notify-"+tag,"BUY",buyRows.stream().map(MaterialView::materialLineId).toList(),List.of(),null));
        approvePurchase(w,first,view.analysisId(),buys,required,settlement,reviewer);
        Map<UUID,UUID> buyItems=orderItems("purchase",w.supplierId());
        assertEquals(lines,buyItems.size());

        List<WarehouseIqcScaleFixture.Receipt> sources=new ArrayList<>();
        for(int i=0;i<receipts;i++) {
            UUID actual=(i/2)%2==0?first:second;
            String type=i%2==0?"PURCHASE":"SUBCONTRACT";
            UUID receipt=type.equals("PURCHASE")?receivePurchase(w,actual,buys,buyItems,settlement)
                    :receiveSubcontract(w,actual,subs,subItems,settlement);
            var inspections=jdbc.queryForList("SELECT id,goods_id FROM procurement_inspection_items WHERE receipt_type=? AND receipt_id=? ORDER BY id",type,receipt);
            assertEquals(lines,inspections.size());
            Set<UUID> distinct=new HashSet<>();
            for(var row:inspections) {
                UUID goods=(UUID)row.get("goods_id");assertTrue(distinct.add(goods));
                sources.add(new WarehouseIqcScaleFixture.Receipt(type,receipt,(UUID)row.get("id"),actual,goods));
            }
        }
        UUID confirmer=ReflectionTestUtils.invokeMethod(masters,"createIqcWarehouseConfirmer",w,"iqc-large-confirm-"+tag);
        return new WarehouseIqcScaleFixture.Scenario(w,view.analysisId(),confirmer,List.of(first,second),List.copyOf(sources),required,List.copyOf(buys),List.copyOf(subs));
    }

    private void openAndIssueSubcontract(FullChainEndToEndTest.World w,UUID warehouse,List<UUID> goods,
                                        BigDecimal qty,UUID settlement,UUID reviewer) {
        var stock=beans.getBean(StockDocService.class);
        var opening=new com.uten.imp.features.stock.dto.StockDocSaveRequest();
        opening.setDocType("OTHER_IN");opening.setBillDate(BusinessTime.today());opening.setWarehouseId(warehouse);
        opening.setItems(goods.stream().map(id->{var row=new com.uten.imp.features.stock.dto.StockDocItemLine();
            row.setGoodsId(id);row.setUnitId(w.unitId());row.setUnitRate(BigDecimal.ONE);row.setQty(qty);row.setPrice(BigDecimal.TEN);
            row.setAmountOriginal(qty.multiply(BigDecimal.TEN));row.setAmountLocal(row.getAmountOriginal());return row;}).toList());
        stock.approve(stock.create(opening).getId());
        var order=new com.uten.imp.features.subcontract.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today());order.setWarehouseId(warehouse);order.setSupplierId(w.supplierId());
        order.setCurrencyId(w.currencyId());order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(settlement);
        order.setItems(goods.stream().map(id->{var row=new com.uten.imp.features.subcontract.order.dto.OrderItemLine();
            row.setGoodsId(id);row.setUnitId(w.unitId());row.setUnitRate(BigDecimal.ONE);row.setQty(qty);row.setPrice(new BigDecimal("50"));
            row.setAmountOriginal(qty.multiply(row.getPrice()));row.setAmountLocal(row.getAmountOriginal());return row;}).toList());
        UUID orderId=beans.getBean(SubcontractOrderService.class).create(order).getId();
        beans.getBean(ProcurementFinanceApprovalService.class).submit("SUBCONTRACT",orderId);
        masters.loginAs(reviewer);masters.approvePendingFinance("SUBCONTRACT",orderId);masters.loginAs(w.superAdminUserId());
        var issueIds=jdbc.queryForList("SELECT DISTINCT h.id FROM subcontract_material_issues h JOIN subcontract_material_issue_items i ON i.issue_id=h.id JOIN subcontract_order_items oi ON oi.id=i.order_item_id WHERE oi.order_id=? AND h.status=0 AND NOT h.is_deleted AND NOT i.is_deleted",UUID.class,orderId);
        assertFalse(issueIds.isEmpty());
        var service=beans.getBean(SubcontractMaterialIssueService.class);
        for(UUID id:issueIds) {
            var draft=service.detail(id);var command=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest();
            command.setBillDate(BusinessTime.today());command.setSupplierId(w.supplierId());command.setWarehouseId(warehouse);
            command.setItems(draft.getItems().stream().map(item->{var row=new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine();
                row.setGoodsId(item.getGoodsId());row.setColorId(item.getColorId());row.setUnitId(w.unitId());row.setUnitRate(BigDecimal.ONE);row.setQty(qty);
                row.setOrderItemId(item.getOrderItemId());row.setPlanItemId(item.getPlanItemId());row.setParentGoodsId(item.getParentGoodsId());return row;}).toList());
            service.update(id,command);service.approve(id);
        }
    }

    private void approvePurchase(FullChainEndToEndTest.World w,UUID warehouse,UUID analysisId,List<UUID> goods,
                                 BigDecimal qty,UUID settlement,UUID reviewer) {
        var requested=jdbc.queryForList("""
                SELECT DISTINCT item.id,item.goods_id,item.qty FROM purchase_request_items item
                WHERE NOT item.is_deleted AND EXISTS(SELECT 1 FROM preplan_supply_actions action
                    WHERE action.analysis_id=? AND action.route='BUY' AND action.status='CREATED'
                      AND action.external_document_id=item.request_id)
                """,analysisId);
        assertEquals(goods.size(),requested.size());
        var order=new com.uten.imp.features.purchase.order.dto.OrderSaveRequest();
        order.setBillDate(BusinessTime.today());order.setWarehouseId(warehouse);order.setSupplierId(w.supplierId());
        order.setCurrencyId(w.currencyId());order.setExchangeRate(BigDecimal.ONE);order.setTaxRate(BigDecimal.ZERO);order.setSettlementMethodId(settlement);
        order.setItems(requested.stream().map(item->{
            assertEquals(0,qty.compareTo((BigDecimal)item.get("qty")));
            var row=new com.uten.imp.features.purchase.order.dto.OrderItemLine();row.setRequestItemId((UUID)item.get("id"));row.setGoodsId((UUID)item.get("goods_id"));
            row.setUnitId(w.unitId());row.setUnitRate(BigDecimal.ONE);row.setQty(qty);row.setPrice(new BigDecimal("50"));
            row.setAmountOriginal(qty.multiply(row.getPrice()));row.setAmountLocal(row.getAmountOriginal());return row;}).toList());
        var created=beans.getBean(PurchaseOrderService.class).createBatch(order);
        assertEquals(1,created.size());UUID id=created.getFirst().getId();
        beans.getBean(ProcurementFinanceApprovalService.class).submit("PURCHASE",id);
        masters.loginAs(reviewer);masters.approvePendingFinance("PURCHASE",id);masters.loginAs(w.superAdminUserId());
    }

    private UUID receivePurchase(FullChainEndToEndTest.World w,UUID warehouse,List<UUID> goods,Map<UUID,UUID> items,UUID settlement) {
        var request=new com.uten.imp.features.purchase.receipt.dto.ReceiptSaveRequest();
        request.setBillDate(BusinessTime.today());request.setWarehouseId(warehouse);request.setSupplierId(w.supplierId());request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);request.setSettlementMethodId(settlement);
        request.setItems(goods.stream().map(id->{var row=new com.uten.imp.features.purchase.receipt.dto.ReceiptItemLine();
            row.setGoodsId(id);row.setOrderItemId(items.get(id));row.setUnitId(w.unitId());row.setUnitRate(BigDecimal.ONE);row.setQty(RECEIPT_QTY);row.setPrice(new BigDecimal("50"));
            row.setAmountOriginal(RECEIPT_QTY.multiply(row.getPrice()));row.setAmountLocal(row.getAmountOriginal());return row;}).toList());
        var service=beans.getBean(PurchaseReceiptService.class);UUID id=service.create(request).getId();service.approve(id);return id;
    }
    private UUID receiveSubcontract(FullChainEndToEndTest.World w,UUID warehouse,List<UUID> goods,Map<UUID,UUID> items,UUID settlement) {
        var request=new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();
        request.setBillDate(BusinessTime.today());request.setWarehouseId(warehouse);request.setSupplierId(w.supplierId());request.setCurrencyId(w.currencyId());
        request.setExchangeRate(BigDecimal.ONE);request.setTaxRate(BigDecimal.ZERO);request.setSettlementMethodId(settlement);
        request.setItems(goods.stream().map(id->{var row=new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();
            row.setGoodsId(id);row.setOrderItemId(items.get(id));row.setUnitId(w.unitId());row.setUnitRate(BigDecimal.ONE);row.setQty(RECEIPT_QTY);row.setPrice(new BigDecimal("50"));
            row.setAmountOriginal(RECEIPT_QTY.multiply(row.getPrice()));row.setAmountLocal(row.getAmountOriginal());return row;}).toList());
        var service=beans.getBean(SubcontractReceiptService.class);UUID id=service.create(request).getId();service.approve(id);return id;
    }
    private Map<UUID,UUID> orderItems(String type,UUID supplier) {
        Map<UUID,UUID> result=new LinkedHashMap<>();
        jdbc.query("SELECT i.goods_id,i.id FROM "+type+"_order_items i JOIN "+type+"_orders h ON h.id=i.order_id WHERE h.supplier_id=? AND NOT h.is_deleted AND NOT i.is_deleted",rs->{assertNull(result.put(rs.getObject(1,UUID.class),rs.getObject(2,UUID.class)));},supplier);
        return result;
    }
    private UUID leaf(FullChainEndToEndTest.World w,String tag) {
        UUID id=UUID.randomUUID();jdbc.update("INSERT INTO warehouses(id,parent_id,code,name,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",id,w.warehouseId(),"IQC-L-"+tag,"IQC multi SKU leaf");return id;
    }
}
