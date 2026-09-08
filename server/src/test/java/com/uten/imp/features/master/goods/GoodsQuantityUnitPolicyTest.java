package com.uten.imp.features.master.goods;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.unit.Unit;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.Optional;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsQuantityUnitPolicyTest {
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void directServiceRequestCannotBypassLockedUnitOrTouchOtherFields() {
        var goods = new Goods();
        goods.setQuantityUnitLocked(true);
        goods.setName("原货品");
        goods.setUnit(new Unit());
        var request = new GoodsSaveRequest();
        request.setName("不应写入");
        request.setUnitId(new Unit().getId());
        var repo = mock(GoodsRepository.class);
        when(repo.findById(goods.getId())).thenReturn(Optional.of(goods));
        var relationships = mock(GoodsMasterRelationshipResolver.class);
        var service = new GoodsService(repo, mock(MaterialCategoryRepository.class), mock(ColorRepository.class),
                mock(UnitRepository.class), mock(MouldRepository.class), mock(TxSessionVars.class),
                mock(EntityManager.class), mock(CategoryDrivenCodeService.class), mock(OwnerVisibility.class),
                mock(SecurityContextCurrentUser.class), mock(GoodsCostMasker.class), relationships);
        SecurityContextHolder.getContext().setAuthentication(
                new TestingAuthenticationToken("editor", "", "goods:edit"));
        assertThatThrownBy(() -> service.update(goods.getId(), request)).isInstanceOf(ApiException.class)
                .hasMessageContaining("基本单位不能再改");
        assertThat(goods.getName()).isEqualTo("原货品");
        verify(repo, never()).save(any());
        verifyNoInteractions(relationships);
    }

    @Test void unusedUnitMayChangeAndSameUnitOrOmittedFieldPreservesUsedGoods() {
        var goods = new Goods();
        var unit = new Unit();
        goods.setUnit(unit);
        var request = new GoodsSaveRequest();
        request.setUnitId(new Unit().getId());
        assertThatCode(() -> GoodsQuantityUnitPolicy.requireUnchangedIfUsed(goods, request)).doesNotThrowAnyException();
        goods.setQuantityUnitLocked(true);
        request.setUnitId(unit.getId());
        assertThatCode(() -> GoodsQuantityUnitPolicy.requireUnchangedIfUsed(goods, request)).doesNotThrowAnyException();
        assertThatCode(() -> GoodsQuantityUnitPolicy.requireUnchangedIfUsed(goods, new GoodsSaveRequest()))
                .doesNotThrowAnyException();
        request.setUnitId(null);
        assertThatThrownBy(() -> GoodsQuantityUnitPolicy.requireUnchangedIfUsed(goods, request))
                .isInstanceOf(ApiException.class);
    }

    @Test void unresolvedUsedLegacyCannotBeGuessedOrHaveItsDisplaySnapshotCleared() {
        var goods = new Goods();
        goods.setQuantityUnitLocked(true);
        goods.setUnitLegacyId(12);
        var request = new GoodsSaveRequest();
        request.setUnitId(new Unit().getId());
        assertThatThrownBy(() -> GoodsQuantityUnitPolicy.requireUnchangedIfUsed(goods, request))
                .hasMessageContaining("历史基本单位尚未核对");
        request.setUnitId(null);
        assertThatThrownBy(() -> GoodsQuantityUnitPolicy.requireUnchangedIfUsed(goods, request))
                .hasMessageContaining("历史基本单位尚未核对");
        assertThat(goods.getUnitLegacyId()).isEqualTo(12);
        assertThatCode(() -> GoodsQuantityUnitPolicy.requireUnchangedIfUsed(goods, new GoodsSaveRequest()))
                .doesNotThrowAnyException();
    }
}
