package com.uten.imp.features.master.goods;

import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.LockModeType;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.HashSet;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsAttachmentAccessPolicyTest {
    @Test void sharedMasterModeRetainsExistingReadAndEditPermissions() {
        var h = new Harness();
        assertDoesNotThrow(() -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        h.permissions.remove("goods:edit");
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
        h.permissions.remove("goods:view");
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
    }

    @Test void scopedMasterKeepsReadOnlyDelegationAndHidesUnrelatedGoods() {
        var h = new Harness();
        ReflectionTestUtils.setField(h.goods, "goodsOwnerScopeEnabled", true);
        when(h.owners.evaluate("goods", "goods:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(h.owner), Set.of()));
        assertDoesNotThrow(() -> h.policy.requireCanView(h.id, h.user()));
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanManage(h.id, h.user()));
        h.record.setOwnerEmployeeId(UUID.randomUUID());
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
        h.record.setOwnerEmployeeId(null);
        assertDoesNotThrow(() -> h.policy.requireCanManage(h.id, h.user()));
    }

    @Test void confirmAndDeleteRecheckChangedOrDeletedGoodsAfterRowLock() {
        var h = new Harness();
        doAnswer(ignored -> { h.record.setDeleted(true); return null; })
                .when(h.em).refresh(h.record, LockModeType.PESSIMISTIC_WRITE);
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanManageForUpdate(h.id, h.user()));
        verify(h.em).find(Goods.class, h.id, LockModeType.PESSIMISTIC_WRITE);
    }

    @Test void unsavedMissingAndDeletedGoodsCannotHoldFiles() {
        var h = new Harness();
        denied(ErrorCode.VALIDATION_FAILED, () -> h.policy.requireCanManage(null, h.user()));
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(UUID.randomUUID(), h.user()));
        h.record.setDeleted(true);
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanView(h.id, h.user()));
    }

    @Test void detailCapabilityUsesTheSameWritableScopeWithoutGrantingFunctionalActions() {
        var h = new Harness();
        ReflectionTestUtils.setField(h.goods, "goodsOwnerScopeEnabled", true);
        when(h.owners.evaluate("goods", "goods:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(h.owner), Set.of()));
        var delegated = h.goods.detail(h.id);
        assertFalse(delegated.isWritable());
        assertEquals(h.id, delegated.getId());
        denied(ErrorCode.NOT_FOUND, () -> h.policy.requireCanManage(h.id, h.user()));
        when(h.owners.evaluate("goods", "goods:view:all"))
                .thenReturn(new OwnerVisibility.OwnerScope(false, Set.of(h.owner), Set.of(h.owner)));
        assertTrue(h.goods.detail(h.id).isWritable());
        h.permissions.remove("goods:edit");
        denied(ErrorCode.FORBIDDEN, () -> h.policy.requireCanManage(h.id, h.user()));
        h.record.setOwnerEmployeeId(null);
        assertTrue(h.goods.detail(h.id).isWritable());
    }

    private static void denied(ErrorCode code, Runnable operation) {
        assertEquals(code, assertThrows(ApiException.class, operation::run).getCode());
    }

    private static class Harness {
        final UUID id = UUID.randomUUID(), owner = UUID.randomUUID();
        final Set<String> permissions = new HashSet<>(Set.of("goods:view", "goods:edit"));
        final EntityManager em = mock(EntityManager.class);
        final GoodsRepository repository = mock(GoodsRepository.class);
        final OwnerVisibility owners = mock(OwnerVisibility.class);
        final Goods record = new Goods();
        final GoodsService goods = new GoodsService(repository,
                mock(MaterialCategoryRepository.class), mock(ColorRepository.class),
                mock(UnitRepository.class), mock(MouldRepository.class), mock(TxSessionVars.class),
                em, mock(CategoryDrivenCodeService.class), owners, mock(SecurityContextCurrentUser.class),
                mock(GoodsCostMasker.class), mock(GoodsMasterRelationshipResolver.class));
        final GoodsAttachmentAccessPolicy policy = new GoodsAttachmentAccessPolicy(em, goods);
        Harness() {
            record.setId(id); record.setOwnerEmployeeId(owner);
            when(em.find(Goods.class, id)).thenReturn(record);
            when(em.find(Goods.class, id, LockModeType.PESSIMISTIC_WRITE)).thenReturn(record);
            when(repository.findById(id)).thenReturn(Optional.of(record));
            Query stock = mock(Query.class);
            when(stock.setParameter(anyString(), any())).thenReturn(stock);
            when(stock.getResultList()).thenReturn(List.of());
            when(em.createNativeQuery(anyString())).thenReturn(stock);
            assertEquals("GOODS", policy.ownerType());
        }
        AuthUser user() { return new AuthUser(owner, owner, "owner", Set.of(), Set.copyOf(permissions), false, true, false); }
    }
}
