package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.application.port.PreplanAnalysisPegPort;
import com.uten.imp.application.port.ProductionInspectionStockInPort;
import com.uten.imp.application.port.ProductionSubcontractSupplyTransitionPort;
import com.uten.imp.application.port.ProductionSupplyTransitionPort;
import com.uten.imp.application.port.SubcontractShortDeliveryPort;
import com.uten.imp.application.port.WarehouseUse;
import com.uten.imp.common.concurrency.ProcurementMutationLocks;
import com.uten.imp.common.finance.ProcurementReceiptConsiderationService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.warehouse.WarehouseScopeService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.stock.StockService;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.RETURNS_SELF;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * ADR-098 × ADR-090(2026-10-05)：委外回厂「先入库后质检」碰上待判定的回厂短交——
 * 品质结论照常记下, 只是自动转为可用库存先扣住(不再整笔 409); 闸的说法按入库路线区分;
 * 判定 / 到齐后由 {@link SubcontractHeldPreStockReleaseService} 逐张补做。
 * 真库全链见 businesschain/SubcontractPreStockShortDeliveryEndToEndTest。
 */
class ProcurementIqcPreStockShortDeliveryHoldTest {

    private static final UUID RECEIPT = UUID.randomUUID();
    private static final UUID SHELF = UUID.randomUUID();
    private static final String NORMAL = "…判定完成前这批先不入库, 货先留在待入库不要上架。";
    private static final String PRE_STOCKED = "…货已上架, 等委外判定短交后才能转为可用库存; 判定完成系统自动转入, 仓库不用再点确认入库。";

    @Test
    void heldSubcontractReceiptKeepsTheQualityDecisionAndDefersTheConversion() {
        Fixture f = new Fixture();
        when(f.shortDelivery.stockInHoldReason(RECEIPT)).thenReturn(NORMAL);
        UUID pass1 = UUID.randomUUID(), pass2 = UUID.randomUUID();

        var outcome = f.service.confirmPreStockedReleases("SUBCONTRACT", RECEIPT, List.of(
                new ProcurementIqcStockInService.PreStockedRelease(pass1, UUID.randomUUID(), SHELF, "A-01"),
                new ProcurementIqcStockInService.PreStockedRelease(pass2, UUID.randomUUID(), SHELF, "A-02")));

        assertThat(outcome.heldPassEventIds()).containsExactly(pass1, pass2);
        assertThat(outcome.batches()).as("被扣住时不建自动转正批次").isEmpty();
        assertThat(outcome.fallbackPassEventIds()).as("也不改投「待仓库确认入库」, 货已经在库位上").isEmpty();
        verifyNoInteractions(f.locks, f.stock, f.warehouses, f.production);
        assertThat(f.sql).as("被扣住时不读放行切片、不写任何东西").isEmpty();
    }

    @Test
    void purchaseReceiptsNeverAskTheSubcontractHold() {
        Fixture f = new Fixture();
        doThrow(new ApiException(ErrorCode.CONFLICT, "仓库已停用"))
                .when(f.warehouses).require(eq(SHELF), anyString(), eq(WarehouseUse.GOOD_IN));
        UUID pass = UUID.randomUUID();

        var outcome = f.service.confirmPreStockedReleases("PURCHASE", RECEIPT, List.of(
                new ProcurementIqcStockInService.PreStockedRelease(pass, UUID.randomUUID(), SHELF, "A-01")));

        assertThat(outcome.heldPassEventIds()).isEmpty();
        assertThat(outcome.fallbackPassEventIds()).containsExactly(pass);
        verify(f.shortDelivery, never()).stockInHoldReason(any());
    }

    @Test
    void releasedSubcontractReceiptGoesOnToTheNormalConversion() {
        Fixture f = new Fixture();
        when(f.shortDelivery.stockInHoldReason(RECEIPT)).thenReturn(null);
        doThrow(new ApiException(ErrorCode.CONFLICT, "仓库已停用"))
                .when(f.warehouses).require(eq(SHELF), anyString(), eq(WarehouseUse.GOOD_IN));
        UUID pass = UUID.randomUUID();

        var outcome = f.service.confirmPreStockedReleases("SUBCONTRACT", RECEIPT, List.of(
                new ProcurementIqcStockInService.PreStockedRelease(pass, UUID.randomUUID(), SHELF, "A-01")));

        assertThat(outcome.heldPassEventIds()).as("闸已放行就照常走转正(这里上架仓失效, 按原规则退回仓库确认)").isEmpty();
        assertThat(outcome.fallbackPassEventIds()).containsExactly(pass);
    }

    @Test
    void holdWordingFollowsTheStockInRoute() {
        Fixture f = new Fixture();
        when(f.shortDelivery.stockInHoldReason(RECEIPT)).thenReturn(NORMAL);
        when(f.shortDelivery.preStockedHoldReason(RECEIPT)).thenReturn(PRE_STOCKED);

        assertThat(f.service.stockInHoldMessage("SUBCONTRACT", RECEIPT, false)).isEqualTo(NORMAL);
        assertThat(f.service.stockInHoldMessage("SUBCONTRACT", RECEIPT, true)).isEqualTo(PRE_STOCKED);
        assertThat(f.service.stockInHoldMessage("PURCHASE", RECEIPT, true)).isNull();
        assertThat(f.service.subcontractStockInHeld("SUBCONTRACT", RECEIPT)).isTrue();
        assertThat(f.service.subcontractStockInHeld("PURCHASE", RECEIPT)).isFalse();

        when(f.shortDelivery.stockInHoldReason(RECEIPT)).thenReturn(null);
        assertThat(f.service.stockInHoldMessage("SUBCONTRACT", RECEIPT, true)).isNull();
        assertThat(f.service.subcontractStockInHeld("SUBCONTRACT", RECEIPT)).isFalse();
    }

    @Test
    void releaseServiceConvertsEveryHeldReceiptOfTheOrderItemsOnce() {
        EntityManager em = mock(EntityManager.class);
        Query held = mock(Query.class, RETURNS_SELF);
        UUID receiptA = UUID.fromString("00000000-0000-0000-0000-00000000000a");
        UUID receiptB = UUID.fromString("00000000-0000-0000-0000-00000000000b");
        List<Object[]> rows = new ArrayList<>();
        rows.add(new Object[]{receiptB, UUID.randomUUID(), UUID.randomUUID(), SHELF, "B-01"});
        rows.add(new Object[]{receiptA, UUID.randomUUID(), UUID.randomUUID(), SHELF, "A-01"});
        rows.add(new Object[]{receiptA, UUID.randomUUID(), UUID.randomUUID(), SHELF, "A-02"});
        when(held.getResultList()).thenReturn(rows);
        when(em.createNativeQuery(anyString())).thenReturn(held);
        ProcurementInspectionService inspections = mock(ProcurementInspectionService.class);
        when(inspections.releaseHeldPreStock("SUBCONTRACT", receiptA)).thenReturn(2);
        when(inspections.releaseHeldPreStock("SUBCONTRACT", receiptB)).thenReturn(0);

        int released = new SubcontractHeldPreStockReleaseService(em, inspections)
                .releaseHeldPreStock(List.of(UUID.randomUUID()));

        assertThat(released).isEqualTo(2);
        var order = org.mockito.Mockito.inOrder(inspections);
        order.verify(inspections).releaseHeldPreStock("SUBCONTRACT", receiptA);
        order.verify(inspections).releaseHeldPreStock("SUBCONTRACT", receiptB);
    }

    @Test
    void releaseServiceWithoutOrderItemsReadsNothing() {
        EntityManager em = mock(EntityManager.class);
        ProcurementInspectionService inspections = mock(ProcurementInspectionService.class);

        assertThat(new SubcontractHeldPreStockReleaseService(em, inspections).releaseHeldPreStock(List.of()))
                .isZero();
        verifyNoInteractions(em, inspections);
    }

    private static final class Fixture {
        final EntityManager em = mock(EntityManager.class);
        final StockService stock = mock(StockService.class);
        final ProductionInspectionStockInPort production = mock(ProductionInspectionStockInPort.class);
        final ProcurementMutationLocks locks = mock(ProcurementMutationLocks.class);
        final WarehouseScopeService warehouses = mock(WarehouseScopeService.class);
        final SubcontractShortDeliveryPort shortDelivery = mock(SubcontractShortDeliveryPort.class);
        final List<String> sql = new ArrayList<>();
        final ProcurementIqcStockInService service;

        Fixture() {
            SecurityContextCurrentUser user = mock(SecurityContextCurrentUser.class);
            when(user.requireId()).thenReturn(UUID.randomUUID());
            when(user.requireEmployeeId()).thenReturn(UUID.randomUUID());
            service = new ProcurementIqcStockInService(em, stock, user, mock(TxSessionVars.class),
                    mock(ProductionSupplyTransitionPort.class), mock(ProductionSubcontractSupplyTransitionPort.class),
                    production, mock(PreplanAnalysisPegPort.class), mock(ChainNoticeService.class), locks,
                    mock(ProcurementReceiptConsiderationService.class));
            ReflectionTestUtils.setField(service, "warehouseScopes", warehouses);
            ReflectionTestUtils.setField(service, "shortDelivery", shortDelivery);
            when(em.createNativeQuery(anyString())).thenAnswer(call -> {
                sql.add(call.getArgument(0));
                return mock(Query.class, RETURNS_SELF);
            });
        }
    }
}
