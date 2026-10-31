package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.features.master.supplier.Supplier;
import com.uten.imp.features.master.supplier.SupplierRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

/**
 * ADR-197：行上既有供应商（含已停用）在复制粘贴、改量保存中原样保留——
 * 停用供应商不清理既有 BOM 引用，写入不能被它阻断；只有换成另一个供应商
 * 才按「使用」新选口径校验，报错点名供应商，不再让员工误读成货品停用。
 */
class GoodsBomSupplierReferenceTest {

    private final SupplierRepository supplierRepo = mock(SupplierRepository.class);
    private final GoodsMasterRelationshipResolver relationships = new GoodsMasterRelationshipResolver(
            mock(UnitRepository.class), mock(ColorRepository.class),
            mock(com.uten.imp.features.master.mould.MouldRepository.class),
            mock(com.uten.imp.features.master.client.ClientRepository.class),
            supplierRepo, mock(com.uten.imp.features.master.warehouse.WarehouseRepository.class),
            mock(com.uten.imp.features.master.warehouse.WarehouseMasterRules.class),
            mock(com.uten.imp.features.org.department.DepartmentRepository.class),
            mock(MasterReferenceValidationPort.class));

    private final GoodsRepository goodsRepo = mock(GoodsRepository.class);
    private final GoodsBomItemRepository bomRepo = mock(GoodsBomItemRepository.class);
    private final MasterObjectAccess access = mock(MasterObjectAccess.class);
    private final EntityManager em = mock(EntityManager.class);
    private final GoodsBomService bom = new GoodsBomService(
            goodsRepo, bomRepo, mock(ColorRepository.class), mock(UnitRepository.class),
            mock(TxSessionVars.class), mock(SecurityContextCurrentUser.class),
            mock(MasterReferenceValidationPort.class), relationships,
            mock(BusinessEventPublisher.class), access);
    private final GoodsBomPasteService paste = new GoodsBomPasteService(
            bom, goodsRepo, bomRepo, mock(MasterReferenceValidationPort.class), access,
            mock(TxSessionVars.class), em);

    private final Goods target = goods("P-7");
    private final Goods source = goods("SRC-7");
    private final Goods component = goods("V51025");
    private final Supplier disabled = new Supplier();
    private GoodsBomItem sourceRow;

    @BeforeEach
    void setUp() {
        disabled.setId(UUID.randomUUID());
        disabled.setCode("GY000022");
        disabled.setName("利辉");
        disabled.setStatus("禁用");
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                "tester", null, List.of(new SimpleGrantedAuthority("goods:bom:create"))));
        when(access.visibleGoodsOwner()).thenReturn(owner -> true);
        when(goodsRepo.findAllById(anyCollection()))
                .thenReturn(List.of(target, source, component));
        when(bomRepo.findOperationalEdges(anyCollection())).thenReturn(List.of());
        when(bomRepo.materialCost(any())).thenReturn(BigDecimal.ZERO);
        sourceRow = new GoodsBomItem();
        sourceRow.setGoods(source);
        bom.apply(line("1"), sourceRow, component);
        sourceRow.setDefaultSupplier(disabled);
        when(bomRepo.findLiveItemParents(anyCollection()))
                .thenReturn(List.<Object[]>of(new Object[]{sourceRow.getId(), source.getId()}));
        when(bomRepo.findAllById(anyCollection())).thenReturn(List.of(sourceRow));
    }

    @AfterEach
    void clearAuthentication() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void copiedRowKeepsTheDisabledSupplierOfItsVerifiedSourceEdge() {
        var item = line("1");
        item.setCopiedFromBomItemId(sourceRow.getId());
        item.setDefaultSupplierId(disabled.getId());

        var result = paste.paste(request(item));
        assertEquals(1, result.added());
        var row = ArgumentCaptor.forClass(GoodsBomItem.class);
        verify(em).persist(row.capture());
        assertSame(disabled, row.getValue().getDefaultSupplier());
        verifyNoInteractions(supplierRepo);
    }

    @Test
    void selectingADisabledSupplierForANewRowIsRejectedWithTheNamedReason() {
        var item = line("1");
        item.setDefaultSupplierId(disabled.getId());
        when(supplierRepo.findById(disabled.getId())).thenReturn(Optional.of(disabled));

        ApiException error = org.junit.jupiter.api.Assertions.assertThrows(
                ApiException.class, () -> paste.paste(request(item)));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        String message = error.getFieldErrors().getFirst().message();
        assertTrue(message.contains("利辉"), message);
        assertTrue(message.contains("不能新选"), message);
        verify(em, times(0)).persist(any(GoodsBomItem.class));
    }

    @Test
    void editingARowRoundTripsItsDisabledSupplierUntouched() {
        GoodsBomItem row = new GoodsBomItem();
        row.setGoods(target);
        row.setComponent(component);
        row.setDefaultSupplier(disabled);
        var req = line("2");
        req.setDefaultSupplierId(disabled.getId());

        bom.apply(req, row, component);

        assertSame(disabled, row.getDefaultSupplier());
        verifyNoInteractions(supplierRepo);
    }

    @Test
    void changingTheSupplierGoesThroughTheStrictNewSelectionCheck() {
        GoodsBomItem row = new GoodsBomItem();
        row.setGoods(target);
        row.setComponent(component);
        row.setDefaultSupplier(disabled);
        UUID otherId = UUID.randomUUID();
        var req = line("2");
        req.setDefaultSupplierId(otherId);
        Supplier other = new Supplier();
        other.setId(otherId);
        other.setCode("GY000001");
        other.setName("洪武");
        other.setStatus("禁用");
        when(supplierRepo.findById(otherId)).thenReturn(Optional.of(other));

        ApiException error = org.junit.jupiter.api.Assertions.assertThrows(
                ApiException.class, () -> bom.apply(req, row, component));

        assertTrue(error.getMessage().contains("洪武"), error.getMessage());
    }

    private BomPasteRequest request(BomItemSaveRequest... lines) {
        return new BomPasteRequest(BomPasteRequest.Mode.APPEND,
                List.of(new BomPasteRequest.Target(target.getId(), null)), List.of(lines));
    }

    private BomItemSaveRequest line(String qty) {
        BomItemSaveRequest line = new BomItemSaveRequest();
        line.setComponentGoodsId(component.getId());
        line.setQty(new BigDecimal(qty));
        return line;
    }

    private static Goods goods(String code) {
        Goods goods = new Goods();
        goods.setCode(code);
        goods.setName("货品" + code);
        return goods;
    }
}
