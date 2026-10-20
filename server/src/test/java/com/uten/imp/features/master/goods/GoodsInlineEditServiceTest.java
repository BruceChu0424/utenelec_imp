package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.goods.dto.GoodsSaveRequest;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import jakarta.persistence.EntityManager;
import jakarta.validation.Validation;
import jakarta.validation.ValidatorFactory;
import org.hibernate.query.NativeQuery;
import org.junit.jupiter.api.*;
import org.mockito.ArgumentCaptor;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.math.BigDecimal;
import java.util.*;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class GoodsInlineEditServiceTest {
    final UUID id = UUID.randomUUID();
    final ObjectMapper mapper = new ObjectMapper();
    GoodsService goods;
    GoodsInlineEditService service;
    GoodsDetail detail;
    EntityManager em;
    ValidatorFactory validators;

    @BeforeEach @SuppressWarnings("unchecked") void setUp() throws Exception {
        goods = mock(GoodsService.class);
        var repository = mock(GoodsRepository.class);
        when(repository.findById(id)).thenReturn(Optional.of(new Goods()));
        em = mock(EntityManager.class);
        NativeQuery<Object> lock = mock(NativeQuery.class);
        when(em.createNativeQuery(anyString())).thenReturn(lock);
        when(lock.setParameter(anyString(), any())).thenReturn(lock);
        when(lock.getResultList()).thenReturn(List.of(id));
        var current = mock(SecurityContextCurrentUser.class);
        var user = new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "goods-inline",
                Set.of("goods:view", "goods:edit", "goods:price:edit"), false, true, false);
        when(current.get()).thenReturn(Optional.of(user));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(user, "", user.getAuthorities()));
        validators = Validation.buildDefaultValidatorFactory();
        service = new GoodsInlineEditService(goods, repository, em, mock(TxSessionVars.class), current, mapper, validators.getValidator());
        // Fixture construction remains independent of the growing all-args DTO.
        var constructor = GoodsDetail.class.getConstructors()[0];
        Object[] arguments = Arrays.stream(constructor.getParameterTypes()).map(type -> {
            if (type == boolean.class) return Boolean.FALSE;
            if (type == int.class) return Integer.valueOf(0);
            return null;
        }).toArray();
        detail = (GoodsDetail) constructor.newInstance(arguments);
        detail.setId(id); detail.setCategoryId(UUID.randomUUID()); detail.setCode("HP001");
        detail.setName("original"); detail.setStatus("使用"); detail.setSourceType("采购");
        detail.setVersion(7L); detail.setWritable(true);
        detail.setPrice(new BigDecimal("99999999999999.9999"));
        detail.setSourceE(new BigDecimal("12345678901234.1234"));
        detail.setMWeight(new BigDecimal("1.2345"));
        detail.setNameEn("Learned name"); detail.setNameEnSource("LEARNED");
        when(goods.detail(id)).thenReturn(detail);
    }

    @AfterEach void tearDown() { SecurityContextHolder.clearContext(); validators.close(); }

    @Test void namePatchPreservesExactDecimalsAndOmitsUntouchedReferencesAndProvenance() {
        service.patch(id, Map.of("version", mapper.valueToTree(7)), Map.of("name", mapper.valueToTree("changed")));
        var request = ArgumentCaptor.forClass(GoodsSaveRequest.class);
        verify(goods).update(eq(id), request.capture());
        var saved = request.getValue();
        assertEquals("changed", saved.getName()); assertEquals("HP001", saved.getCode());
        assertEquals(detail.getPrice(), saved.getPrice()); assertEquals(detail.getSourceE(), saved.getSourceE());
        assertEquals(detail.getMWeight(), saved.getMWeight()); assertEquals(7L, saved.getVersion());
        assertFalse(saved.hasNameEn()); assertFalse(saved.hasUnitReference());
        assertFalse(saved.hasColorReference()); assertFalse(saved.hasMouldReference());
        assertFalse(saved.hasOwningWarehouseReference());
        verify(em).clear();
    }

    @Test void exactDecimalStringIsAcceptedWithoutClientDoubleRoundTrip() {
        service.patch(id, Map.of("version", mapper.valueToTree(7)), Map.of("price", mapper.valueToTree("98765432109876.5432")));
        var request = ArgumentCaptor.forClass(GoodsSaveRequest.class);
        verify(goods).update(eq(id), request.capture());
        assertEquals(new BigDecimal("98765432109876.5432"), request.getValue().getPrice());
    }

    @Test void staleVersionDoesNotReachTheOriginalWriteCommand() {
        assertThrows(ApiException.class, () -> service.patch(id, Map.of("version", mapper.valueToTree(6)), Map.of("name", mapper.valueToTree("changed"))));
        verify(goods, never()).update(any(), any());
    }

    @Test void identifiersAndDerivedValuesAreRejectedBeforeAnyRead() {
        for (String field : List.of("code", "categoryId", "stockQty", "owningWorkshopId", "version", "sourceE")) {
            assertThrows(ApiException.class, () -> service.patch(id, Map.of("version", mapper.valueToTree(7)), Map.of(field, mapper.valueToTree("x"))));
        }
        verifyNoInteractions(goods); verifyNoInteractions(em);
    }

    @Test void explicitReferenceClearRetainsItsPresenceFlagAndUnchangedUnitIsAbsent() {
        service.patch(id, Map.of("version", mapper.valueToTree(7)), Map.of("mouldId", mapper.getNodeFactory().nullNode()));
        var request = ArgumentCaptor.forClass(GoodsSaveRequest.class);
        verify(goods).update(eq(id), request.capture());
        assertTrue(request.getValue().hasMouldReference()); assertNull(request.getValue().getMouldId());
        assertFalse(request.getValue().hasUnitReference());
    }
}
