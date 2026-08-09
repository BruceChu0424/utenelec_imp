package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class GoodsBomControlFieldsTest {

    private final GoodsRepository goodsRepo = mock(GoodsRepository.class);
    private final GoodsBomItemRepository bomRepo = mock(GoodsBomItemRepository.class);
    private final GoodsBomService service = new GoodsBomService(
            goodsRepo,
            bomRepo,
            mock(ColorRepository.class),
            mock(UnitRepository.class),
            mock(TxSessionVars.class),
            mock(MasterReferenceValidationPort.class),
            mock(GoodsMasterRelationshipResolver.class),
            mock(BusinessEventPublisher.class));

    private Goods parent;
    private Goods component;

    @BeforeEach
    void setUp() {
        parent = goods("P-1", "成品");
        component = goods("C-1", "包装组件");
        when(goodsRepo.findById(parent.getId())).thenReturn(Optional.of(parent));
        when(goodsRepo.findById(component.getId())).thenReturn(Optional.of(component));
        when(bomRepo.findByGoods_IdAndComponent_IdAndDeletedFalse(
                parent.getId(), component.getId())).thenReturn(Optional.empty());
        when(bomRepo.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(any()))
                .thenReturn(List.of());
        when(bomRepo.save(any())).thenAnswer(invocation -> invocation.getArgument(0));
        when(goodsRepo.save(any())).thenAnswer(invocation -> invocation.getArgument(0));
    }

    @Test
    void createDefaultsPreserveHistoricalStartPerUnitHardGate() {
        BomItemSaveRequest request = request();

        var view = service.create(parent.getId(), request);

        assertEquals("START", view.getControlStage());
        assertEquals("PER_UNIT", view.getConsumptionBasis());
        assertEquals(BigDecimal.ONE, view.getBasisOutputQty());
        assertTrue(view.isAllowPartialPackage());
        assertTrue(view.isHardGate());
    }

    @Test
    void createNormalizesAndReturnsPackagingControls() {
        BomItemSaveRequest request = request();
        request.setControlStage(" finish ");
        request.setConsumptionBasis("per_package");
        request.setBasisOutputQty(new BigDecimal("100"));
        request.setAllowPartialPackage(false);
        request.setHardGate(false);

        var view = service.create(parent.getId(), request);

        assertEquals("FINISH", view.getControlStage());
        assertEquals("PER_PACKAGE", view.getConsumptionBasis());
        assertEquals(new BigDecimal("100"), view.getBasisOutputQty());
        assertFalse(view.isAllowPartialPackage());
        assertFalse(view.isHardGate());
    }

    @Test
    void shippingAndReferenceStagesRejectHardGateFailClosed() {
        for (String stage : List.of("SHIP", "REFERENCE")) {
            BomItemSaveRequest request = request();
            request.setControlStage(stage);
            request.setHardGate(true);

            ApiException error = assertThrows(ApiException.class,
                    () -> service.create(parent.getId(), request));

            assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
            assertTrue(error.getMessage().contains("不能设为缺料硬门槛"));
        }
    }

    @Test
    void shippingReferenceRequiresClientToExplicitlyClearHistoricalHardDefault() {
        BomItemSaveRequest omittedGate = request();
        omittedGate.setControlStage("SHIP");
        ApiException error = assertThrows(ApiException.class,
                () -> service.create(parent.getId(), omittedGate));
        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());

        BomItemSaveRequest warningOnly = request();
        warningOnly.setControlStage("SHIP");
        warningOnly.setHardGate(false);

        var view = service.create(parent.getId(), warningOnly);

        assertEquals("SHIP", view.getControlStage());
        assertFalse(view.isHardGate());
    }

    @Test
    void updateFromLegacyClientPreservesExistingControlValues() {
        GoodsBomItem row = new GoodsBomItem();
        row.setGoods(parent);
        row.setComponent(component);
        row.setQty(BigDecimal.ONE);
        row.setControlStage("SHIP");
        row.setConsumptionBasis("PER_PACKAGE");
        row.setBasisOutputQty(new BigDecimal("24"));
        row.setAllowPartialPackage(false);
        row.setHardGate(false);
        when(bomRepo.findById(row.getId())).thenReturn(Optional.of(row));

        BomItemSaveRequest request = request();
        request.setQty(new BigDecimal("2"));

        var view = service.update(parent.getId(), row.getId(), request);

        assertEquals("SHIP", view.getControlStage());
        assertEquals("PER_PACKAGE", view.getConsumptionBasis());
        assertEquals(new BigDecimal("24"), view.getBasisOutputQty());
        assertFalse(view.isAllowPartialPackage());
        assertFalse(view.isHardGate());
    }

    @Test
    void invalidControlCodesAndNonPositiveBasisFailClosed() {
        BomItemSaveRequest badStage = request();
        badStage.setControlStage("AFTER_SALE");
        ApiException stageError = assertThrows(ApiException.class,
                () -> service.create(parent.getId(), badStage));
        assertEquals(ErrorCode.VALIDATION_FAILED, stageError.getCode());

        BomItemSaveRequest badBasis = request();
        badBasis.setConsumptionBasis("BY_WEIGHT");
        ApiException basisError = assertThrows(ApiException.class,
                () -> service.create(parent.getId(), badBasis));
        assertEquals(ErrorCode.VALIDATION_FAILED, basisError.getCode());

        BomItemSaveRequest blankStage = request();
        blankStage.setControlStage("   ");
        ApiException blankStageError = assertThrows(ApiException.class,
                () -> service.create(parent.getId(), blankStage));
        assertEquals(ErrorCode.VALIDATION_FAILED, blankStageError.getCode());

        BomItemSaveRequest zeroOutput = request();
        zeroOutput.setBasisOutputQty(BigDecimal.ZERO);
        ApiException outputError = assertThrows(ApiException.class,
                () -> service.create(parent.getId(), zeroOutput));
        assertEquals(ErrorCode.VALIDATION_FAILED, outputError.getCode());
    }

    private BomItemSaveRequest request() {
        BomItemSaveRequest request = new BomItemSaveRequest();
        request.setComponentGoodsId(component.getId());
        request.setQty(BigDecimal.ONE);
        return request;
    }

    private static Goods goods(String code, String name) {
        Goods goods = new Goods();
        goods.setCode(code);
        goods.setName(name);
        goods.setAutoCreated(false);
        return goods;
    }
}
