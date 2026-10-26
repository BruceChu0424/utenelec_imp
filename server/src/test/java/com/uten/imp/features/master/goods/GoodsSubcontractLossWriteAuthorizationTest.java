package com.uten.imp.features.master.goods;

import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.color.ColorRepository;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.features.master.materialcategory.MaterialCategory;
import com.uten.imp.features.master.materialcategory.MaterialCategoryRepository;
import com.uten.imp.features.master.mould.MouldRepository;
import com.uten.imp.features.master.unit.UnitRepository;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.OwnerVisibility;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsSubcontractLossWriteAuthorizationTest {
    private final GoodsRepository repository=mock(GoodsRepository.class);
    private final MaterialCategoryRepository categories=mock(MaterialCategoryRepository.class);
    private final CategoryDrivenCodeService codes=mock(CategoryDrivenCodeService.class);
    private final MaterialCategory category=new MaterialCategory();

    @AfterEach void clear() {SecurityContextHolder.clearContext();}

    @Test void fullCreationCannotWriteThePolicyWithoutTheNativeCostGrant() {
        var service=service(false);var request=request();request.setSubcontractAllowedLossPct(new BigDecimal("15"));
        assertThrows(ApiException.class,()->service.create(request));verify(repository,never()).save(any());verifyNoInteractions(codes);
    }
    @Test void fullUpdateCannotChangeThePolicyBeforeAnyEntityMutation() {
        var service=service(false);var existing=existing();var request=request();request.setSubcontractAllowedLossPct(new BigDecimal("25"));
        assertThrows(ApiException.class,()->service.update(existing.getId(),request));
        assertEquals("old name",existing.getName());assertEquals(new BigDecimal("15"),existing.getSubcontractAllowedLossPct());verify(repository,never()).save(any());
    }
    @Test void explicitlyClearingThePolicyIsAlsoAProtectedChange() {
        var service=service(false);var existing=existing();var request=request();request.setSubcontractAllowedLossPct(null);
        assertThrows(ApiException.class,()->service.update(existing.getId(),request));assertEquals(new BigDecimal("15"),existing.getSubcontractAllowedLossPct());
    }
    @Test void anOmittedPolicyPreservesItWhileOtherFieldsRemainEditable() {
        var service=service(false);var existing=existing();service.update(existing.getId(),request());
        assertEquals("updated name",existing.getName());assertEquals(new BigDecimal("15"),existing.getSubcontractAllowedLossPct());verify(repository).save(existing);
    }
    @Test void anUnchangedVisibleValueMayBeEchoedWithoutTheCostGrant() {
        var service=service(false);var existing=existing();var request=request();request.setSubcontractAllowedLossPct(new BigDecimal("15.0000"));
        service.update(existing.getId(),request);assertEquals("updated name",existing.getName());verify(repository).save(existing);
    }
    @Test void purchaseAndCostGrantsAllowTheSameFullFormToChangeAndClearThePolicy() {
        var service=service(true);var existing=existing();var request=request();request.setSubcontractAllowedLossPct(new BigDecimal("25"));
        service.update(existing.getId(),request);assertEquals(new BigDecimal("25"),existing.getSubcontractAllowedLossPct());
        var clear=request();clear.setSubcontractAllowedLossPct(null);service.update(existing.getId(),clear);assertNull(existing.getSubcontractAllowedLossPct());
    }
    @Test void readOnlyPolicyVisibilityStillDoesNotRequireCostAccess() {
        var service=service(false);var existing=existing();assertEquals(new BigDecimal("15"),service.detail(existing.getId()).getSubcontractAllowedLossPct());
    }
    @Test void omittedStatusAndMaskedPricesPreserveTheExistingDisabledGoods() {
        var service=service(false);var existing=existing();existing.setStatus("禁用");existing.setPrice(BigDecimal.TEN);existing.setDiscount(BigDecimal.ONE);
        var request=new GoodsSaveRequest();request.setCategoryId(category.getId());request.setName("updated name");
        service.update(existing.getId(),request);
        assertEquals("禁用",existing.getStatus());assertEquals(BigDecimal.TEN,existing.getPrice());assertEquals(BigDecimal.ONE,existing.getDiscount());
    }
    @Test void explicitNullStatusCannotClearThePersistedState() {
        var service=service(false);var existing=existing();var request=request();request.setStatus(null);
        assertThrows(ApiException.class,()->service.update(existing.getId(),request));assertEquals("使用",existing.getStatus());verify(repository,never()).save(any());
    }
    @Test void aSalesOnlyEditDoesNotNormalizeUntouchedHistoricalBaseTextOrEnglishProvenance() {
        var service=service(false);var existing=existing();
        existing.setSeries(" 系列 ");existing.setStockPlace(" A-01 ");existing.setPaper(" 历史备注 ");existing.setRearInsertCode(" 旧镶件 ");
        existing.setNameEn(" Learned English ");existing.setNameEnSource("LEARNED");
        var request=new GoodsSaveRequest();request.setCategoryId(category.getId());request.setCode(existing.getCode());request.setName(existing.getName());
        request.setSeries(existing.getSeries());request.setStockPlace(existing.getStockPlace());request.setPaper(existing.getPaper());request.setRearInsertCode(existing.getRearInsertCode());request.setNameEn(existing.getNameEn());request.setCNumber("客户型号");
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("sales",null,List.of(new org.springframework.security.core.authority.SimpleGrantedAuthority("goods:sales:edit"))));
        service.update(existing.getId(),request);
        assertEquals(" 系列 ",existing.getSeries());assertEquals(" A-01 ",existing.getStockPlace());assertEquals(" 历史备注 ",existing.getPaper());assertEquals(" 旧镶件 ",existing.getRearInsertCode());
        assertEquals(" Learned English ",existing.getNameEn());assertEquals("LEARNED",existing.getNameEnSource());assertEquals("客户型号",existing.getCNumber());
    }

    private GoodsService service(boolean cost) {
        Set<String> permissions=cost?Set.of("goods:view","goods:edit","goods:create","goods:cost:view","goods:purchase:edit"):Set.of("goods:view","goods:edit","goods:create");
        var actor=new AuthUser(UUID.randomUUID(),UUID.randomUUID(),"editor",permissions,false,true,false);
        var current=mock(SecurityContextCurrentUser.class);when(current.get()).thenReturn(Optional.of(actor));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor,null,actor.getAuthorities()));
        var masker=mock(GoodsCostMasker.class);when(masker.canView()).thenReturn(cost);
        var em=mock(EntityManager.class);var query=mock(Query.class);when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(),any())).thenReturn(query);when(query.getResultList()).thenReturn(List.of());
        when(categories.findById(category.getId())).thenReturn(Optional.of(category));
        when(codes.allocateForUpdate(any(),any(),any(),any(),any())).thenAnswer(call->call.getArgument(4,CategoryCodeAllocation.class));
        when(repository.save(any(Goods.class))).thenAnswer(call->call.getArgument(0));
        return new GoodsService(repository,categories,mock(ColorRepository.class),mock(UnitRepository.class),mock(MouldRepository.class),mock(TxSessionVars.class),em,codes,
            mock(OwnerVisibility.class),current,masker,mock(GoodsMasterRelationshipResolver.class));
    }
    private Goods existing() {
        var goods=new Goods();goods.setCode("LOSS-TEST");goods.setCodeSequence(1L);goods.setName("old name");goods.setStatus("使用");goods.setCategory(category);goods.setSubcontractAllowedLossPct(new BigDecimal("15"));
        when(repository.findById(goods.getId())).thenReturn(Optional.of(goods));return goods;
    }
    private GoodsSaveRequest request() {var request=new GoodsSaveRequest();request.setCategoryId(category.getId());request.setName("updated name");request.setStatus("使用");return request;}
}
