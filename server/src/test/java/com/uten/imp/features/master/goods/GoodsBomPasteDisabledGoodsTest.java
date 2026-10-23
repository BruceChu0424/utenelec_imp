package com.uten.imp.features.master.goods;

import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.BomItemSaveRequest;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
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
import java.util.Collection;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * 停用组件在复制、替换、导入中都不能重新进入当前 BOM。
 * 已删除与迁移占位货品连数据库触发器都拒绝写入，粘贴继续整体拒绝并逐行说明。
 */
class GoodsBomPasteDisabledGoodsTest {

    private final GoodsRepository goodsRepo = mock(GoodsRepository.class);
    private final GoodsBomItemRepository bomRepo = mock(GoodsBomItemRepository.class);
    private final MasterObjectAccess access = mock(MasterObjectAccess.class);
    private final EntityManager em = mock(EntityManager.class);
    private final GoodsBomService bom = new GoodsBomService(
            goodsRepo, bomRepo, mock(ColorRepository.class), mock(UnitRepository.class),
            mock(TxSessionVars.class), mock(SecurityContextCurrentUser.class),
            mock(MasterReferenceValidationPort.class), mock(GoodsMasterRelationshipResolver.class),
            mock(BusinessEventPublisher.class), access);
    private final GoodsBomPasteService paste = new GoodsBomPasteService(
            bom, goodsRepo, bomRepo, mock(MasterReferenceValidationPort.class), access,
            mock(TxSessionVars.class), em);

    private final Goods target = goods("P-9");
    private final Goods source = goods("SOURCE-9");
    private final Goods disabledComponent = goods("UT3118");
    private final Goods activeComponent = goods("6MT001");
    private GoodsBomItem sourceRow;

    @BeforeEach
    void setUp() {
        disabledComponent.setStatus("禁用");
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                "tester", null, List.of(new SimpleGrantedAuthority("goods:bom:create"))));
        when(access.visibleGoodsOwner()).thenReturn(owner -> true);
        when(goodsRepo.findAllById(anyCollection()))
                .thenReturn(List.of(target, source, disabledComponent, activeComponent));
        when(bomRepo.findOperationalEdges(anyCollection())).thenReturn(List.of());
        when(bomRepo.materialCost(any())).thenReturn(BigDecimal.ZERO);
        sourceRow = new GoodsBomItem();
        sourceRow.setGoods(source);
        bom.apply(line(disabledComponent, "0.11"), sourceRow, disabledComponent);
        when(bomRepo.findLiveItemParents(anyCollection()))
                .thenReturn(List.<Object[]>of(new Object[]{sourceRow.getId(), source.getId()}));
        when(bomRepo.findAllById(anyCollection())).thenReturn(List.of(sourceRow));
    }

    @AfterEach
    void clearAuthentication() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void disabledComponentInCopiedSnapshotIsRejectedAtomically() {
        assertRejected(copiedLine("0.11"), "已停用");
    }

    @Test void disabledComponentWithoutAnExistingSourceCannotBeAdded() {
        assertRejected(line(disabledComponent,"0.11"), "已停用");
    }

    @Test void inventedSourceIdentityCannotAuthorizeDisabledAddition() {
        var item=copiedLine("0.11");item.setCopiedFromBomItemId(java.util.UUID.randomUUID());
        assertRejected(item,"已停用");
    }

    @Test void deletedSourceEdgeCannotAuthorizeDisabledAddition() {
        sourceRow.setDeleted(true);
        assertRejected(copiedLine("0.11"),"已停用");
    }

    @Test void sourceForAnotherComponentCannotAuthorizeDisabledAddition() {
        sourceRow.setComponent(activeComponent);
        assertRejected(copiedLine("0.11"),"已停用");
    }

    @Test void invisibleSourceParentCannotAuthorizeDisabledAddition() {
        var owner=java.util.UUID.randomUUID();source.setOwnerEmployeeId(owner);
        when(access.visibleGoodsOwner()).thenReturn(value->!owner.equals(value));
        assertRejected(copiedLine("0.11"),"已停用");
    }

    @Test void aCopiedDisabledComponentCannotBeChangedWhileBeingAdded() {
        assertRejected(copiedLine("0.12"),"已停用");
    }

    @Test void copiedHistoricalNullPriceIsNotReplacedWithTheCurrentComponentPrice() {
        disabledComponent.setStatus("使用");
        sourceRow.setPrice(null);sourceRow.setTotal(null);disabledComponent.setPrice(new BigDecimal("25"));
        paste.paste(request(copiedLine("0.11")));
        var row=ArgumentCaptor.forClass(GoodsBomItem.class);verify(em).persist(row.capture());
        org.junit.jupiter.api.Assertions.assertNull(row.getValue().getPrice());
        org.junit.jupiter.api.Assertions.assertNull(row.getValue().getTotal());
    }

    @Test void replaceCannotRetainAnExistingDisabledComponent() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(
                "tester", null, List.of(new SimpleGrantedAuthority("goods:bom:create"),
                new SimpleGrantedAuthority("goods:bom:delete"))));
        when(bomRepo.findOperationalEdges(anyCollection())).thenReturn(List.<Object[]>of(
                new Object[]{sourceRow.getId(), target.getId(), disabledComponent.getId(), 1}));
        var replace = new BomPasteRequest(BomPasteRequest.Mode.REPLACE,
                List.of(new BomPasteRequest.Target(target.getId(), null)), List.of(copiedLine("0.11")));

        ApiException error = org.junit.jupiter.api.Assertions.assertThrows(ApiException.class,
                () -> paste.paste(replace));

        assertTrue(error.getFieldErrors().stream().anyMatch(field -> field.message().contains("已停用")));
        verify(em, times(0)).persist(any(GoodsBomItem.class));
        verify(em, times(0)).createNativeQuery(any(String.class));
    }

    @Test void importedRowsCannotReintroduceADisabledComponent() {
        ApiException error = org.junit.jupiter.api.Assertions.assertThrows(ApiException.class,
                () -> paste.pasteImported(request(line(disabledComponent, "0.11")),
                        java.util.Set.of("qty"), java.util.Map.of()));

        assertTrue(error.getFieldErrors().stream().anyMatch(field -> field.message().contains("已停用")));
        verify(em, times(0)).persist(any(GoodsBomItem.class));
    }

    private void assertRejected(BomItemSaveRequest item,String reason) {
        ApiException error=org.junit.jupiter.api.Assertions.assertThrows(ApiException.class,
                ()->paste.paste(request(item,line(activeComponent,"1"))));
        assertTrue(error.getFieldErrors().stream().anyMatch(field->field.message().contains(reason)));
        verify(em,times(0)).persist(any(GoodsBomItem.class));
    }

    private BomItemSaveRequest copiedLine(String qty) {
        var item=line(disabledComponent,qty);item.setCopiedFromBomItemId(sourceRow.getId());return item;
    }

    @Test
    void disabledTargetReceivesPastedRows() {
        target.setStatus("禁用");

        var result = paste.paste(request(line(activeComponent, "1")));

        assertEquals(1, result.added());
        verify(em, times(1)).persist(any(GoodsBomItem.class));
    }

    @Test
    void deletedComponentIsRefusedWithLineProblem() {
        activeComponent.setDeleted(true);

        ApiException error = org.junit.jupiter.api.Assertions.assertThrows(ApiException.class,
                () -> paste.paste(request(line(activeComponent, "1"))));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertTrue(error.getFieldErrors().getFirst().message().contains("已删除或仅为迁移占位"));
        verify(em, times(0)).persist(any(GoodsBomItem.class));
    }

    @Test
    void stubComponentIsRefusedWithLineProblem() {
        disabledComponent.setAutoCreated(true);

        ApiException error = org.junit.jupiter.api.Assertions.assertThrows(ApiException.class,
                () -> paste.paste(request(line(disabledComponent, "0.11"))));

        assertTrue(error.getFieldErrors().getFirst().message().contains("已删除或仅为迁移占位"));
        verify(em, times(0)).persist(any(GoodsBomItem.class));
    }

    private BomPasteRequest request(BomItemSaveRequest... lines) {
        return new BomPasteRequest(BomPasteRequest.Mode.APPEND,
                List.of(new BomPasteRequest.Target(target.getId(), null)), List.of(lines));
    }

    private static BomItemSaveRequest line(Goods component, String qty) {
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
