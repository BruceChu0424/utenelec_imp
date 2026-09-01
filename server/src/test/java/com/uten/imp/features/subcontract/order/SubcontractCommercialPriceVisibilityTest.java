package com.uten.imp.features.subcontract.order;

import com.uten.imp.common.integrity.ProductionSupplySourceGuard;
import com.uten.imp.common.util.EmployeeNameResolver;
import com.uten.imp.features.finance.procurement.ProcurementApprovalProjectionQuery;
import com.uten.imp.security.CommercialPriceVisibility;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssue;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueItem;
import com.uten.imp.features.subcontract.material_issue.SubcontractMaterialIssueService;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueDetail;
import com.uten.imp.features.subcontract.material_issue.dto.MaterialIssueItemDto;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturn;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnItem;
import com.uten.imp.features.subcontract.material_return.SubcontractMaterialReturnService;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnDetail;
import com.uten.imp.features.subcontract.material_return.dto.MaterialReturnItemDto;
import com.uten.imp.features.subcontract.order.dto.OrderDetail;
import com.uten.imp.features.subcontract.order.dto.OrderItemDto;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.OrderProgress;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.ReceiptDoc;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.ReturnDoc;
import com.uten.imp.features.subcontract.order.dto.OrderProgressContracts.WasteDoc;
import com.uten.imp.features.subcontract.ret.SubcontractReturn;
import com.uten.imp.features.subcontract.ret.SubcontractReturnItem;
import com.uten.imp.features.subcontract.ret.SubcontractReturnService;
import com.uten.imp.features.subcontract.ret.dto.ReturnDetail;
import com.uten.imp.features.subcontract.ret.dto.ReturnItemDto;
import com.uten.imp.features.subcontract.waste.SubcontractWaste;
import com.uten.imp.features.subcontract.waste.SubcontractWasteItem;
import com.uten.imp.features.subcontract.waste.SubcontractWasteService;
import com.uten.imp.features.subcontract.waste.dto.WasteDetail;
import com.uten.imp.features.subcontract.waste.dto.WasteItemDto;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.lenient;

@ExtendWith(MockitoExtension.class)
class SubcontractCommercialPriceVisibilityTest {

    @Mock private CommercialPriceVisibility commercialPriceVisibility;
    @Mock private ProductionSupplySourceGuard productionSourceGuard;
    @Mock private ProcurementApprovalProjectionQuery approvalProjection;
    @Mock private EmployeeNameResolver nameResolver;

    @InjectMocks private SubcontractOrderService orderService;
    @InjectMocks private SubcontractReturnService returnService;
    @InjectMocks private SubcontractMaterialIssueService materialIssueService;
    @InjectMocks private SubcontractMaterialReturnService materialReturnService;
    @InjectMocks private SubcontractWasteService wasteService;

    @BeforeEach
    void denyCommercialPricePermission() {
        lenient().when(commercialPriceVisibility.canViewSubcontractOrder()).thenReturn(false);
        lenient().when(commercialPriceVisibility.canViewSubcontractReturn()).thenReturn(false);
        lenient().when(commercialPriceVisibility.canViewSubcontractWasteSuggestion())
                .thenReturn(false);
        lenient().when(commercialPriceVisibility.canViewSubcontractMaterialCost())
                .thenReturn(false);
        for (Object service : List.of(orderService, returnService, materialIssueService,
                materialReturnService, wasteService)) {
            ReflectionTestUtils.setField(
                    service, "commercialPriceVisibility", commercialPriceVisibility);
        }
    }

    @Test
    void orderAndFinishedGoodsReturnMaskHeadersLinesAndListTotals() {
        SubcontractOrder order = new SubcontractOrder();
        order.setId(UUID.randomUUID());
        order.setMakerId(UUID.randomUUID());
        order.setStatus((short) 0);
        order.setCurrencyId(UUID.randomUUID());
        order.setExchangeRate(new BigDecimal("7.2"));
        order.setTaxRate(new BigDecimal("13"));
        order.setSettlementMethodId(UUID.randomUUID());
        order.setTotalOriginal(new BigDecimal("10"));
        order.setTotalLocal(new BigDecimal("72"));
        SubcontractOrderItem orderEntityItem = commercialOrderItem("3");
        OrderItemDto orderItem = ReflectionTestUtils.invokeMethod(
                orderService, "toItemDto", orderEntityItem);
        OrderDetail orderDetail = ReflectionTestUtils.invokeMethod(
                orderService, "toDetail", order, List.of(orderItem));

        assertTrue(orderDetail.isPriceMasked());
        assertNull(orderDetail.getCurrencyId());
        assertNull(orderDetail.getExchangeRate());
        assertNull(orderDetail.getTaxRate());
        assertNull(orderDetail.getSettlementMethodId());
        assertNull(orderDetail.getTotalLocal());
        assertNull(orderDetail.getItems().getFirst().getPrice());
        assertEquals(new BigDecimal("3"), orderDetail.getItems().getFirst().getQty());

        SubcontractReturn finishedReturn = new SubcontractReturn();
        finishedReturn.setMakerId(UUID.randomUUID());
        finishedReturn.setCurrencyId(UUID.randomUUID());
        finishedReturn.setExchangeRate(new BigDecimal("7.2"));
        finishedReturn.setTaxRate(new BigDecimal("13"));
        finishedReturn.setSettlementMethodId(UUID.randomUUID());
        finishedReturn.setSettlementStyleLegacy(6);
        finishedReturn.setTotalOriginal(new BigDecimal("20"));
        finishedReturn.setTotalLocal(new BigDecimal("144"));
        SubcontractReturnItem returnEntityItem = new SubcontractReturnItem();
        setCommercialLine(returnEntityItem, "2");
        ReturnItemDto returnItem = ReflectionTestUtils.invokeMethod(
                returnService, "toItemDto", returnEntityItem);
        ReturnDetail returnDetail = ReflectionTestUtils.invokeMethod(
                returnService, "toDetail", finishedReturn, List.of(returnItem));

        assertTrue(returnDetail.isPriceMasked());
        assertNull(returnDetail.getCurrencyId());
        assertNull(returnDetail.getSettlementMethodId());
        assertNull(returnDetail.getTotalLocal());
        assertNull(returnDetail.getItems().getFirst().getPrice());
        assertEquals(new BigDecimal("2"), returnDetail.getItems().getFirst().getQty());
    }

    @Test
    void materialIssueReturnAndWasteKeepQuantitiesAndWeightButMaskMoney() {
        SubcontractMaterialIssue issue = new SubcontractMaterialIssue();
        issue.setMakerId(UUID.randomUUID());
        issue.setTotalOriginal(new BigDecimal("30"));
        issue.setTotalLocal(new BigDecimal("216"));
        SubcontractMaterialIssueItem issueEntityItem = new SubcontractMaterialIssueItem();
        setCommercialLine(issueEntityItem, "4");
        issueEntityItem.setWeight(new BigDecimal("8"));
        MaterialIssueItemDto issueItem = ReflectionTestUtils.invokeMethod(
                materialIssueService, "toItemDto", issueEntityItem);
        MaterialIssueDetail issueDetail = ReflectionTestUtils.invokeMethod(
                materialIssueService, "toDetail", issue, List.of(issueItem));
        assertTrue(issueDetail.isPriceMasked());
        assertNull(issueDetail.getTotalLocal());
        assertNull(issueDetail.getItems().getFirst().getPrice());
        assertEquals(new BigDecimal("4"), issueDetail.getItems().getFirst().getQty());
        assertEquals(new BigDecimal("8"), issueDetail.getItems().getFirst().getWeight());

        SubcontractMaterialReturn materialReturn = new SubcontractMaterialReturn();
        materialReturn.setMakerId(UUID.randomUUID());
        materialReturn.setTotalOriginal(new BigDecimal("10"));
        materialReturn.setTotalLocal(new BigDecimal("72"));
        SubcontractMaterialReturnItem materialReturnEntityItem = new SubcontractMaterialReturnItem();
        setCommercialLine(materialReturnEntityItem, "1");
        MaterialReturnItemDto materialReturnItem = ReflectionTestUtils.invokeMethod(
                materialReturnService, "toItemDto", materialReturnEntityItem);
        MaterialReturnDetail materialReturnDetail = ReflectionTestUtils.invokeMethod(
                materialReturnService, "toDetail", materialReturn, List.of(materialReturnItem));
        assertTrue(materialReturnDetail.isPriceMasked());
        assertNull(materialReturnDetail.getTotalLocal());
        assertNull(materialReturnDetail.getItems().getFirst().getPrice());
        assertEquals(new BigDecimal("1"), materialReturnDetail.getItems().getFirst().getQty());

        SubcontractWaste waste = new SubcontractWaste();
        waste.setMakerId(UUID.randomUUID());
        waste.setTotalWeight(new BigDecimal("9"));
        waste.setTotalOriginal(new BigDecimal("40"));
        waste.setTotalLocal(new BigDecimal("288"));
        waste.setDeductAmount(new BigDecimal("50"));
        SubcontractWasteItem wasteEntityItem = new SubcontractWasteItem();
        setCommercialLine(wasteEntityItem, "5");
        wasteEntityItem.setWeight(new BigDecimal("9"));
        WasteItemDto wasteItem = ReflectionTestUtils.invokeMethod(
                wasteService, "toItemDto", wasteEntityItem);
        WasteDetail wasteDetail = ReflectionTestUtils.invokeMethod(
                wasteService, "toDetail", waste, List.of(wasteItem));
        assertTrue(wasteDetail.isPriceMasked());
        assertNull(wasteDetail.getTotalLocal());
        assertNull(wasteDetail.getDeductAmount());
        assertNull(wasteDetail.getItems().getFirst().getPrice());
        assertEquals(new BigDecimal("5"), wasteDetail.getItems().getFirst().getQty());
        assertEquals(new BigDecimal("9"), wasteDetail.getTotalWeight());
    }

    @Test
    void progressRedactionClosesReceiptReturnWasteAndApAmountBypass() {
        ReceiptDoc receipt = new ReceiptDoc(UUID.randomUUID(), "SR-1", (short) 1,
                LocalDate.now(), "仓库", "审核人", new BigDecimal("3"),
                new BigDecimal("30"), "RESOLVED", "STOCKED",
                new BigDecimal("3"), new BigDecimal("3"), BigDecimal.ZERO, null);
        ReturnDoc finishedReturn = new ReturnDoc(UUID.randomUUID(), "SW-1", (short) 1,
                LocalDate.now(), new BigDecimal("1"), new BigDecimal("10"));
        WasteDoc waste = new WasteDoc(UUID.randomUUID(), "SL-1", (short) 1,
                LocalDate.now(), new BigDecimal("2"), new BigDecimal("5"), true);
        OrderProgress raw = new OrderProgress(UUID.randomUUID(), "SO-1", (short) 1,
                "APPROVED", null, true, "OPEN", null,
                List.of(), List.of(), List.of(receipt), List.of(finishedReturn), List.of(waste),
                List.of(), new BigDecimal("20"), new BigDecimal("5"), false);

        OrderProgress masked = SubcontractOrderProgressService.maskCommercialPrices(raw);

        assertTrue(masked.priceMasked());
        assertNull(masked.receipts().getFirst().totalLocal());
        assertNull(masked.returns().getFirst().totalLocal());
        assertNull(masked.wastes().getFirst().deductAmount());
        assertNull(masked.apPostedTotal());
        assertNull(masked.wasteDeductTotal());
        assertEquals(new BigDecimal("3"), masked.receipts().getFirst().totalQty());
        assertEquals("STOCKED", masked.receipts().getFirst().warehouseStockInStatus());
        assertEquals(new BigDecimal("3"),
                masked.receipts().getFirst().warehouseStockedBaseQty());
        assertEquals(new BigDecimal("2"), masked.wastes().getFirst().totalQty());
    }

    private static SubcontractOrderItem commercialOrderItem(String qty) {
        SubcontractOrderItem item = new SubcontractOrderItem();
        setCommercialLine(item, qty);
        return item;
    }

    private static void setCommercialLine(Object item, String qty) {
        ReflectionTestUtils.setField(item, "qty", new BigDecimal(qty));
        ReflectionTestUtils.setField(item, "price", new BigDecimal("10"));
        ReflectionTestUtils.setField(item, "amountOriginal", new BigDecimal("20"));
        ReflectionTestUtils.setField(item, "amountLocal", new BigDecimal("144"));
    }
}
