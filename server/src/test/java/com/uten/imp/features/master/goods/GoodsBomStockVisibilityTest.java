package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.BusinessEventPublisher;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.lifecycle.MasterObjectAccess;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyCollection;
import static org.mockito.Mockito.*;

class GoodsBomStockVisibilityTest {
    final GoodsRepository goods=mock(GoodsRepository.class);
    final GoodsBomItemRepository rows=mock(GoodsBomItemRepository.class);
    final SecurityContextCurrentUser actor=mock(SecurityContextCurrentUser.class);
    final MasterObjectAccess access=mock(MasterObjectAccess.class);
    final GoodsBomService service=new GoodsBomService(goods,rows,mock(ColorRepository.class),mock(UnitRepository.class),
            mock(TxSessionVars.class),actor,mock(MasterReferenceValidationPort.class),
            mock(GoodsMasterRelationshipResolver.class),mock(BusinessEventPublisher.class),access);
    final Goods parent=new Goods(), first=new Goods(), second=new Goods();

    GoodsBomStockVisibilityTest() {
        parent.setCode("ROOT");first.setCode("FIRST");second.setCode("SECOND");first.setMaterial("PVC");
        when(goods.findById(parent.getId())).thenReturn(Optional.of(parent));
        when(access.visibleGoodsOwner()).thenReturn(owner->true);
        when(rows.findByGoods_IdAndDeletedFalseOrderBySortOrderAscIdAsc(parent.getId()))
                .thenReturn(List.of(edge(first),edge(second)));
        when(rows.findGoodsWithOperationalRows(anyCollection())).thenReturn(List.of());
        when(rows.findUsageRows(anyCollection())).thenReturn(List.of());
    }

    @Test void noStockPermissionDoesNotQueryOrSerializeInventory() throws Exception {
        when(actor.get()).thenReturn(Optional.empty());
        var result=service.list(parent.getId());
        assertEquals("PVC",result.getFirst().getComponentMaterial());
        assertTrue(result.stream().allMatch(row->row.getComponentStockQty()==null));
        assertFalse(new ObjectMapper().writeValueAsString(result).contains("componentStockQty"));
        var exported=service.exportPayload(parent.getId());
        assertTrue(exported.columns().stream().noneMatch(column->column.key().equals("stockQty")));
        assertTrue(exported.rows().stream().noneMatch(row->row.containsKey("stockQty")));
        verify(rows,never()).findComponentStockQuantities(anyCollection());
    }

    @Test void authorizedLayerReadsAllVisibleStockInOneQueryAndShowsMissingBalanceAsZero() {
        authorize();
        when(rows.findComponentStockQuantities(Set.of(first.getId(),second.getId())))
                .thenReturn(List.<Object[]>of(new Object[]{first.getId(),new BigDecimal("12.3456")}));
        var result=service.list(parent.getId());
        assertEquals(new BigDecimal("12.3456"),result.getFirst().getComponentStockQty());
        assertEquals(BigDecimal.ZERO,result.get(1).getComponentStockQty());
        verify(rows,times(1)).findComponentStockQuantities(Set.of(first.getId(),second.getId()));
    }

    @Test void hiddenComponentIsExcludedFromTheStockReadAndRemainsRedacted() {
        authorize();UUID hiddenOwner=UUID.randomUUID();second.setOwnerEmployeeId(hiddenOwner);
        when(access.visibleGoodsOwner()).thenReturn(owner->!hiddenOwner.equals(owner));
        when(rows.findComponentStockQuantities(Set.of(first.getId()))).thenReturn(List.of());
        var result=service.list(parent.getId());
        assertNull(result.get(1).getComponentStockQty());
        assertNull(result.get(1).getComponentCode());
        verify(rows).findComponentStockQuantities(Set.of(first.getId()));
    }

    @Test void auditingAnExistingHiddenComponentKeepsItsMasterFieldsAndStockRedacted() {
        authorize();UUID hiddenOwner=UUID.randomUUID();second.setOwnerEmployeeId(hiddenOwner);
        second.setMaterial("HIDDEN-PC");
        when(access.visibleGoodsOwner()).thenReturn(owner->!hiddenOwner.equals(owner));
        GoodsBomItem hidden=edge(second);
        when(rows.findById(hidden.getId())).thenReturn(Optional.of(hidden));
        var view=service.setAudited(parent.getId(),hidden.getId(),true,UUID.randomUUID());
        assertEquals(second.getId(),view.getComponentGoodsId());
        assertNotNull(view.getAuditedAt());
        assertNull(view.getComponentCode());
        assertNull(view.getComponentMaterial());
        assertNull(view.getComponentStockQty());
        verify(rows,never()).findComponentStockQuantities(anyCollection());
    }

    private void authorize() {
        AuthUser user=mock(AuthUser.class);when(user.getPermissions()).thenReturn(Set.of("stock:view"));
        when(actor.get()).thenReturn(Optional.of(user));
    }
    private GoodsBomItem edge(Goods component) {
        GoodsBomItem edge=new GoodsBomItem();edge.setGoods(parent);edge.setComponent(component);return edge;
    }
}
