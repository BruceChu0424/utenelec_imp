package com.uten.imp.businesschain;

import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.warehouse.inbound.ProcurementInspectionService;
import com.uten.imp.features.warehouse.inbound.ProcurementIqcStockInContracts.*;
import com.uten.imp.features.warehouse.inbound.dto.InspectionDispositionRequest;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.LinkedHashMap;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.MaterialAnalysisContracts.*;
import static org.junit.jupiter.api.Assertions.*;

/** Real service preparation. SQL is restricted to coherent master data and readback. */
final class WarehouseIqcScaleFixture {
    static final BigDecimal RECEIPT_QTY = new BigDecimal("1.2500");
    private final FullChainEndToEndTest masters;
    private final JdbcTemplate jdbc;
    private final MaterialAnalysisService analysis;
    private final SubcontractReceiptService subcontractReceipts;
    private final SubcontractMaterialIssueService issues;
    private final ProcurementInspectionService quality;

    WarehouseIqcScaleFixture(AutowireCapableBeanFactory beans, JdbcTemplate jdbc) {
        masters = new FullChainEndToEndTest();
        beans.autowireBean(masters);
        this.jdbc = jdbc;
        analysis = beans.getBean(MaterialAnalysisService.class);
        subcontractReceipts = beans.getBean(SubcontractReceiptService.class);
        issues = beans.getBean(SubcontractMaterialIssueService.class);
        quality = beans.getBean(ProcurementInspectionService.class);
    }

    record Receipt(String type, UUID id, UUID inspectionId, UUID warehouseId, UUID goodsId) {}
    record Scenario(FullChainEndToEndTest.World world, UUID analysisId, UUID confirmer,
                    List<UUID> leaves, List<Receipt> receipts, BigDecimal requiredEach,
                    List<UUID> purchaseGoods, List<UUID> subcontractGoods) {
        Scenario(FullChainEndToEndTest.World world, UUID analysisId, UUID confirmer,
                 List<UUID> leaves, List<Receipt> receipts, BigDecimal requiredEach) {
            this(world,analysisId,confirmer,leaves,receipts,requiredEach,
                    List.of(world.goodsD()),List.of(world.goodsE()));
        }
    }

    Scenario prepare(int count, String tag) {
        if (count < 2 || count > 20 || count % 2 != 0) throw new IllegalArgumentException("Use an even batch of 2..20 receipts");
        var w = masters.seedWorld(tag);
        UUID first = leaf(w, tag + "-a"), second = leaf(w, tag + "-b");
        var sourceWorld = withWarehouse(w, first);
        BigDecimal required = RECEIPT_QTY.multiply(BigDecimal.valueOf(count / 2));

        // A real OTHER_IN establishes company-owned unfinished pieces at 10/unit;
        // the subcontract issue consumes all of them before any return is measured.
        ReflectionTestUtils.invokeMethod(masters, "putDirectTargetStock", sourceWorld, w.goodsE(), required.toPlainString());
        var subcontract = masters.submitLeafSubcontractForFinance(sourceWorld, required);
        masters.loginAs(subcontract.reviewerUserId());
        masters.approvePendingFinance("SUBCONTRACT", subcontract.orderId());
        masters.loginAs(w.superAdminUserId());
        UUID subcontractItem = jdbc.queryForObject("SELECT id FROM subcontract_order_items WHERE order_id=? AND is_deleted=FALSE", UUID.class, subcontract.orderId());
        UUID issue = jdbc.queryForObject("""
                SELECT h.id FROM subcontract_material_issues h
                JOIN subcontract_material_issue_items i ON i.issue_id=h.id
                WHERE i.order_item_id=? AND h.status=0 AND h.is_deleted=FALSE AND i.is_deleted=FALSE
                """, UUID.class, subcontractItem);
        var draft = issues.detail(issue);
        var outgoing = new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueSaveRequest();
        outgoing.setBillDate(BusinessTime.today()); outgoing.setSupplierId(w.supplierId()); outgoing.setWarehouseId(first);
        var issuedLine = new com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemLine();
        issuedLine.setGoodsId(w.goodsE()); issuedLine.setUnitId(w.unitId()); issuedLine.setUnitRate(BigDecimal.ONE);
        issuedLine.setQty(required); issuedLine.setOrderItemId(subcontractItem); issuedLine.setParentGoodsId(w.goodsE());
        issuedLine.setPlanItemId(draft.getItems().getFirst().getPlanItemId()); outgoing.setItems(List.of(issuedLine));
        issues.update(issue, outgoing); issues.approve(issue);

        UUID finished = UUID.randomUUID();
        masters.insertGoods(finished, "IQC-F-"+tag, "IQC scale finished", "自制", w.unitId(), w.unitLegacy());
        masters.insertBom(finished, w.goodsD(), "1"); masters.insertBom(finished, w.goodsE(), "1");
        jdbc.update("UPDATE goods SET default_supplier_id=? WHERE id IN (?,?)", w.supplierId(), w.goodsD(), w.goodsE());
        var initial = analysis.preview(new PreviewRequest(null, null, null, w.warehouseId(), "iqc-scale-preview-"+tag,
                List.of(new PreviewItem("OTHER",null,finished,null,w.unitId(),"IQC-"+tag,"Synthetic batch stock-in",BusinessTime.today(),required))));
        UUID purchaseItem = ReflectionTestUtils.invokeMethod(masters, "approvePurchaseForAnalysis", sourceWorld, initial, w.goodsD());
        assertNotNull(purchaseItem);
        List<Receipt> receipts = new ArrayList<>();
        for (int i=0;i<count;i++) {
            UUID actual = (i/2)%2==0 ? first : second;
            var receivingWorld = withWarehouse(w, actual);
            String type = i%2==0 ? "PURCHASE" : "SUBCONTRACT";
            UUID goods = i%2==0 ? w.goodsD() : w.goodsE();
            UUID receipt;
            if (type.equals("PURCHASE")) {
                receipt = ReflectionTestUtils.invokeMethod(masters, "receiveIntoQuarantine", receivingWorld,
                        goods, purchaseItem, RECEIPT_QTY.toPlainString());
            } else {
                receipt = receiveSubcontract(receivingWorld, subcontractItem);
            }
            assertNotNull(receipt);
            UUID inspection = jdbc.queryForObject("SELECT id FROM procurement_inspection_items WHERE receipt_type=? AND receipt_id=?", UUID.class, type, receipt);
            receipts.add(new Receipt(type, receipt, inspection, actual, goods));
        }
        UUID confirmer = ReflectionTestUtils.invokeMethod(masters, "createIqcWarehouseConfirmer", w, "iqc-scale-confirm-"+tag);
        assertNotNull(confirmer);
        return new Scenario(w, initial.analysisId(), confirmer, List.of(first, second), List.copyOf(receipts), required);
    }

    BatchConfirmRequest passAll(Scenario scenario) {
        masters.loginAs(scenario.world().superAdminUserId());
        var headers = new LinkedHashMap<String,Receipt>();
        var items = new LinkedHashMap<String,List<ConfirmItem>>();
        for (Receipt receipt : scenario.receipts()) {
            quality.dispose(receipt.type(), receipt.id(), receipt.inspectionId(),
                    new InspectionDispositionRequest("PASS",RECEIPT_QTY,"Synthetic quality approval","iqc-pass-"+receipt.id()));
            UUID pass = jdbc.queryForObject("SELECT id FROM procurement_inspection_events WHERE inspection_item_id=? AND action='PASS'", UUID.class, receipt.inspectionId());
            String key=receipt.type()+"|"+receipt.id();
            headers.putIfAbsent(key,receipt);
            items.computeIfAbsent(key,ignored->new ArrayList<>())
                    .add(new ConfirmItem(pass,RECEIPT_QTY,RECEIPT_QTY,"IQC-A01"));
        }
        List<BatchConfirmEntry> entries = new ArrayList<>();
        headers.forEach((key,receipt)->entries.add(new BatchConfirmEntry(receipt.type(),receipt.id(),
                "iqc-store-"+receipt.id(),List.copyOf(items.get(key)))));
        masters.loginAs(scenario.confirmer());
        return new BatchConfirmRequest(List.copyOf(entries));
    }

    private UUID receiveSubcontract(FullChainEndToEndTest.World w, UUID orderItem) {
        var request = new com.uten.imp.features.subcontract.receipt.dto.ReceiptSaveRequest();
        request.setBillDate(BusinessTime.today()); request.setSupplierId(w.supplierId()); request.setWarehouseId(w.warehouseId());
        request.setCurrencyId(w.currencyId()); request.setExchangeRate(BigDecimal.ONE); request.setTaxRate(BigDecimal.ZERO);
        request.setSettlementMethodId(jdbc.queryForObject("SELECT h.settlement_method_id FROM subcontract_orders h JOIN subcontract_order_items i ON i.order_id=h.id WHERE i.id=?",UUID.class,orderItem));
        var line = new com.uten.imp.features.subcontract.receipt.dto.ReceiptItemLine();
        line.setOrderItemId(orderItem); line.setGoodsId(w.goodsE()); line.setUnitId(w.unitId()); line.setUnitRate(BigDecimal.ONE);
        line.setQty(RECEIPT_QTY); line.setPrice(new BigDecimal("50"));
        line.setAmountOriginal(RECEIPT_QTY.multiply(line.getPrice())); line.setAmountLocal(line.getAmountOriginal()); request.setItems(List.of(line));
        UUID receipt = subcontractReceipts.create(request).getId(); subcontractReceipts.approve(receipt); return receipt;
    }

    private UUID leaf(FullChainEndToEndTest.World w, String tag) {
        UUID id = UUID.randomUUID();
        jdbc.update("INSERT INTO warehouses(id,parent_id,code,name,status,is_accountable) VALUES(?,?,?,?,'使用',TRUE)",id,w.warehouseId(),"IQC-W-"+tag,"IQC physical leaf");
        return id;
    }

    static FullChainEndToEndTest.World withWarehouse(FullChainEndToEndTest.World w, UUID warehouse) {
        return new FullChainEndToEndTest.World(w.departmentId(),w.employeeId(),w.superAdminUserId(),
                w.goodsA(),w.goodsB(),w.goodsC(),w.goodsD(),w.goodsE(),w.clientId(),w.supplierId(),warehouse,
                w.unitId(),w.currencyId(),w.colorId(),w.unitLegacy());
    }
}
