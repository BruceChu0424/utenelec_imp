package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.*;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;
import java.util.*;
import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsImportRestoreOwnerScopeTest {
    @Test void readOnlySharedOwnershipCannotBeUsedToRestoreAnotherOwnersDeletedGoods() {
        var repository=mock(GoodsRepository.class);var visibility=mock(OwnerVisibility.class);
        var goods=new Goods();goods.setDeleted(true);goods.setOwnerEmployeeId(UUID.randomUUID());
        when(repository.findById(goods.getId())).thenReturn(Optional.of(goods));
        var service=service(repository,visibility);
        when(visibility.evaluate("goods","goods:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(goods.getOwnerEmployeeId()),Set.of()));
        assertThrows(ApiException.class,()->service.requireRestoreImportedWriteAccess(goods.getId()));
        assertThrows(ApiException.class,()->service.restoreImported(goods.getId(),new GoodsSaveRequest()));
        assertTrue(goods.isDeleted());verify(repository,never()).save(any());
        when(visibility.evaluate("goods","goods:view:all")).thenReturn(new OwnerVisibility.OwnerScope(false,Set.of(goods.getOwnerEmployeeId()),Set.of(goods.getOwnerEmployeeId())));
        assertDoesNotThrow(()->service.requireRestoreImportedWriteAccess(goods.getId()));
    }
    private static GoodsService service(GoodsRepository repository,OwnerVisibility visibility) {
        var service=new GoodsService(repository,mock(MaterialCategoryRepository.class),mock(ColorRepository.class),mock(UnitRepository.class),mock(MouldRepository.class),mock(TxSessionVars.class),mock(EntityManager.class),mock(CategoryDrivenCodeService.class),visibility,mock(SecurityContextCurrentUser.class),mock(GoodsCostMasker.class),mock(GoodsMasterRelationshipResolver.class));
        ReflectionTestUtils.setField(service,"goodsOwnerScopeEnabled",true);
        return service;
    }
}
