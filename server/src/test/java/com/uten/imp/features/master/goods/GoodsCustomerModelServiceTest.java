package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.mastercode.CategoryCodeAllocation;
import com.uten.imp.common.mastercode.CategoryDrivenCodeService;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.color.Color;
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
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsCustomerModelServiceTest {
    private final ObjectMapper json = new ObjectMapper();
    private final GoodsRepository goods = mock(GoodsRepository.class);
    private final MaterialCategoryRepository categories = mock(MaterialCategoryRepository.class);
    private final CategoryDrivenCodeService codes = mock(CategoryDrivenCodeService.class);
    private final GoodsMasterRelationshipResolver relations = mock(GoodsMasterRelationshipResolver.class);
    private final SecurityContextCurrentUser current = mock(SecurityContextCurrentUser.class);
    private final MaterialCategory category = new MaterialCategory();
    private final Color color = new Color();
    private GoodsService service;

    @BeforeEach void setup() {
        var actor = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "editor", Set.of("goods:create", "goods:edit"), false, true, true);
        when(current.get()).thenReturn(Optional.of(actor));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(actor, null, actor.getAuthorities()));
        EntityManager em = mock(EntityManager.class);
        Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        service = new GoodsService(goods, categories, mock(ColorRepository.class), mock(UnitRepository.class),
                mock(MouldRepository.class), mock(TxSessionVars.class), em, codes,
                mock(OwnerVisibility.class), current, mock(GoodsCostMasker.class), relations);
        when(categories.findById(category.getId())).thenReturn(Optional.of(category));
        when(codes.allocate(any(), any(), any())).thenReturn(new CategoryCodeAllocation("HP1", 1, null, true));
        when(codes.allocateForUpdate(any(), any(), any(), any(), any())).thenReturn(new CategoryCodeAllocation("HP1", 1, null, true));
        color.setName("灰色");
        color.setLegacyId(7);
        when(relations.color(color.getId())).thenReturn(color);
    }

    @AfterEach void clear() { SecurityContextHolder.clearContext(); }

    @Test void createAcceptsExistingCustomerModelAndColorUuidAndReturnsBoth() throws Exception {
        var request = request("\"cNumber\":\"  CUSTOMER-X  \",\"colorId\":\"" + color.getId() + "\",");
        var detail = service.create(request);
        var saved = ArgumentCaptor.forClass(Goods.class);
        verify(goods).save(saved.capture());
        assertThat(saved.getValue().getCNumber()).isEqualTo("CUSTOMER-X");
        assertThat(saved.getValue().getColor()).isSameAs(color);
        assertThat(detail.getCNumber()).isEqualTo("CUSTOMER-X");
        assertThat(detail.getColorId()).isEqualTo(color.getId());
        var response = json.valueToTree(detail);
        assertThat(response.get("cNumber").asText()).isEqualTo("CUSTOMER-X");
        assertThat(response.has("cnumber")).isFalse();
    }

    @Test void oldClientsPreserveCustomerModelAndColorWhileExplicitBlankClearsOnlyCustomerModel() throws Exception {
        Goods existing = existing();
        assertThat(service.update(existing.getId(), request("")).getCNumber()).isEqualTo("OLD-MODEL");
        assertThat(existing.getColor()).isSameAs(color);
        service.update(existing.getId(), request("\"cNumber\":\"   \","));
        assertThat(existing.getCNumber()).isNull();
        assertThat(existing.getColor()).isSameAs(color);
        service.update(existing.getId(), request("\"cNumber\":\"NEW-MODEL\","));
        assertThat(existing.getCNumber()).isEqualTo("NEW-MODEL");
        service.update(existing.getId(), request("\"cNumber\":null,"));
        assertThat(existing.getCNumber()).isNull();
    }

    @Test void staleVersionRejectsCustomerModelAndColorChangeBeforeMutation() throws Exception {
        Goods existing = existing();
        existing.setVersion(3);
        var request = request("\"cNumber\":\"NEW-MODEL\",\"colorId\":null,\"version\":2,");
        assertThatThrownBy(() -> service.update(existing.getId(), request)).isInstanceOf(ApiException.class);
        assertThat(existing.getCNumber()).isEqualTo("OLD-MODEL");
        assertThat(existing.getColor()).isSameAs(color);
        verify(goods, never()).save(existing);
    }

    private GoodsSaveRequest request(String fields) throws Exception {
        return json.readValue("{" + fields + "\"categoryId\":\"" + category.getId() + "\",\"name\":\"测试货品\",\"status\":\"使用\"}", GoodsSaveRequest.class);
    }

    private Goods existing() {
        Goods value = new Goods();
        value.setCategory(category); value.setName("测试货品"); value.setStatus("使用");
        value.setCode("HP1"); value.setCodeSequence(1L); value.setCNumber("OLD-MODEL");
        value.setColor(color); value.setColorLegacyId(7);
        when(goods.findById(value.getId())).thenReturn(Optional.of(value));
        return value;
    }
}
