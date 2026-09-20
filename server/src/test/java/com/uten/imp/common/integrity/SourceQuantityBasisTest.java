package com.uten.imp.common.integrity;

import com.uten.imp.common.web.ApiException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullSource;
import org.junit.jupiter.params.provider.ValueSource;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

class SourceQuantityBasisTest {
    @ParameterizedTest @NullSource @ValueSource(strings={"0","-1"})
    void neitherHistoricalNorNativeUnknownSourceRateCanBeDefaultedToOne(String rate) {
        var test=source(UUID.randomUUID(),rate==null?null:new BigDecimal(rate));
        assertThatThrownBy(()->test.service.validatePurchaseReceipt(test.supplier,
                List.of(LinkedDocumentIntegrityService.LinkedLine.orderSource(test.item,test.goods,null,test.unit,BigDecimal.ONE))))
                .isInstanceOf(ApiException.class).hasMessageContaining("尚未核验");
        assertThatThrownBy(()->test.service.validateSubcontractReceipt(test.supplier,
                List.of(LinkedDocumentIntegrityService.LinkedLine.orderSource(test.item,test.goods,null,test.unit,BigDecimal.ONE))))
                .isInstanceOf(ApiException.class).hasMessageContaining("尚未核验");
    }
    @Test void actualUnitIdentityIsRequiredEvenWhenRateIsOne() {
        var test=source(null,BigDecimal.ONE);
        assertThatThrownBy(()->test.service.validatePurchaseReceipt(test.supplier,
                List.of(LinkedDocumentIntegrityService.LinkedLine.orderSource(test.item,test.goods,null,null,BigDecimal.ONE))))
                .isInstanceOf(ApiException.class).hasMessageContaining("尚未核验");
    }
    @Test void provenSourceAllowsTheExistingNativeInputDefaultButRejectsDifferentUnitsAndRates() {
        var test=source(UUID.randomUUID(),BigDecimal.ONE);
        assertThatCode(()->test.service.validatePurchaseReceipt(test.supplier,
                List.of(LinkedDocumentIntegrityService.LinkedLine.orderSource(test.item,test.goods,null,test.unit,null)))).doesNotThrowAnyException();
        assertThatThrownBy(()->test.service.validatePurchaseReceipt(test.supplier,
                List.of(LinkedDocumentIntegrityService.LinkedLine.orderSource(test.item,test.goods,null,UUID.randomUUID(),BigDecimal.ONE))))
                .isInstanceOf(ApiException.class).hasMessageContaining("不一致");
        assertThatThrownBy(()->test.service.validatePurchaseReceipt(test.supplier,
                List.of(LinkedDocumentIntegrityService.LinkedLine.orderSource(test.item,test.goods,null,test.unit,new BigDecimal("2")))))
                .isInstanceOf(ApiException.class).hasMessageContaining("不一致");
    }
    private record Fixture(LinkedDocumentIntegrityService service,UUID supplier,UUID item,UUID goods,UUID unit) { }
    private static Fixture source(UUID unit,BigDecimal rate) {
        EntityManager em=mock(EntityManager.class);Query query=mock(Query.class);
        UUID supplier=UUID.randomUUID(),item=UUID.randomUUID(),goods=UUID.randomUUID();
        when(em.createNativeQuery(anyString())).thenReturn(query);when(query.setParameter(anyString(),any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.<Object[]>of(new Object[]{item,supplier,goods,null,unit,rate,(short)1,false}));
        return new Fixture(new LinkedDocumentIntegrityService(em),supplier,item,goods,unit);
    }
}
