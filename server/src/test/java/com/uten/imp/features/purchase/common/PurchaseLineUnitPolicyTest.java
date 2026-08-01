package com.uten.imp.features.purchase.common;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class PurchaseLineUnitPolicyTest {

    private EntityManager em;
    private Query goodsQuery;
    private Query unitQuery;
    private PurchaseLineUnitPolicy policy;

    @BeforeEach
    void setUp() {
        em = mock(EntityManager.class);
        goodsQuery = mock(Query.class);
        unitQuery = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenAnswer(invocation -> {
            String sql = invocation.getArgument(0);
            return sql.contains("FROM goods") ? goodsQuery : unitQuery;
        });
        when(goodsQuery.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(goodsQuery);
        when(unitQuery.setParameter(anyString(), org.mockito.ArgumentMatchers.any()))
                .thenReturn(unitQuery);
        policy = new PurchaseLineUnitPolicy(em);
    }

    @Test
    void missingUnitUsesResolvableGoodsBaseUnitAtRateOne() {
        UUID baseUnitId = UUID.randomUUID();
        stubGoods(baseUnitId, false, false);

        PurchaseLineUnitPolicy.ResolvedUnit resolved =
                policy.normalizeAndValidate(
                        UUID.randomUUID(), null, null, 3);

        assertEquals(baseUnitId, resolved.unitId());
        assertEquals(0, BigDecimal.ONE.compareTo(resolved.unitRate()));
        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(em).createNativeQuery(sql.capture());
        assertTrue(sql.getValue().contains("u.id = g.unit_id"));
        assertTrue(!sql.getValue().contains("u.legacy_id = g.unit_legacy_id"));
    }

    @Test
    void missingUnitWithNonOneRateIsRejectedAsAmbiguous() {
        stubGoods(UUID.randomUUID(), false, false);

        ApiException error = assertThrows(
                ApiException.class,
                () -> policy.normalizeAndValidate(
                        UUID.randomUUID(), null, new BigDecimal("12"), 2));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertEquals("第 2 行单位缺失且换算率不为 1，无法判定采购单位", error.getMessage());
    }

    @Test
    void missingOrDeletedGoodsBaseUnitIsRejected() {
        stubGoods(null, false, true);

        ApiException error = assertThrows(
                ApiException.class,
                () -> policy.normalizeAndValidate(
                        UUID.randomUUID(), null, null, 1));

        assertEquals(ErrorCode.CONFLICT, error.getCode());
        assertEquals("第 1 行货品不存在、已删除或未维护有效基本单位", error.getMessage());
    }

    @Test
    void explicitBaseUnitDefaultsNullRateToOne() {
        UUID baseUnitId = UUID.randomUUID();
        stubGoods(baseUnitId, false, false);

        PurchaseLineUnitPolicy.ResolvedUnit resolved =
                policy.normalizeAndValidate(
                        UUID.randomUUID(), baseUnitId, null, 1);

        assertEquals(baseUnitId, resolved.unitId());
        assertEquals(0, BigDecimal.ONE.compareTo(resolved.unitRate()));
    }

    @Test
    void explicitBaseUnitRejectsRateOtherThanOne() {
        UUID baseUnitId = UUID.randomUUID();
        stubGoods(baseUnitId, false, false);

        ApiException error = assertThrows(
                ApiException.class,
                () -> policy.normalizeAndValidate(
                        UUID.randomUUID(), baseUnitId, new BigDecimal("2"), 4));

        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
        assertEquals("第 4 行使用货品基本单位时换算率必须为 1", error.getMessage());
    }

    @Test
    void validExplicitNonBaseUnitAndRateArePreserved() {
        UUID baseUnitId = UUID.randomUUID();
        UUID purchaseUnitId = UUID.randomUUID();
        BigDecimal rate = new BigDecimal("24.500000");
        stubGoods(baseUnitId, false, false);
        when(unitQuery.getSingleResult()).thenReturn(1L);

        PurchaseLineUnitPolicy.ResolvedUnit resolved =
                policy.normalizeAndValidate(
                        UUID.randomUUID(), purchaseUnitId, rate, 5);

        assertEquals(purchaseUnitId, resolved.unitId());
        assertEquals(rate, resolved.unitRate());
    }

    @Test
    void nonBaseUnitRequiresAnActiveMasterAndStorablePositiveRate() {
        UUID baseUnitId = UUID.randomUUID();
        UUID purchaseUnitId = UUID.randomUUID();
        stubGoods(baseUnitId, false, false);
        when(unitQuery.getSingleResult()).thenReturn(1L);

        ApiException missingRate = assertThrows(
                ApiException.class,
                () -> policy.normalizeAndValidate(
                        UUID.randomUUID(), purchaseUnitId, null, 6));
        assertEquals(ErrorCode.VALIDATION_FAILED, missingRate.getCode());

        ApiException roundedToZeroRate = assertThrows(
                ApiException.class,
                () -> policy.normalizeAndValidate(
                        UUID.randomUUID(), purchaseUnitId, new BigDecimal("0.0000001"), 6));
        assertEquals(ErrorCode.VALIDATION_FAILED, roundedToZeroRate.getCode());

        when(unitQuery.getSingleResult()).thenReturn(0L);
        ApiException deletedUnit = assertThrows(
                ApiException.class,
                () -> policy.normalizeAndValidate(
                        UUID.randomUUID(), purchaseUnitId, BigDecimal.ONE, 6));
        assertEquals(ErrorCode.CONFLICT, deletedUnit.getCode());
    }

    private void stubGoods(
            UUID baseUnitId,
            boolean goodsDeleted,
            boolean baseUnitDeleted) {
        when(goodsQuery.getResultList()).thenReturn(List.<Object[]>of(new Object[]{
                goodsDeleted,
                baseUnitId,
                baseUnitDeleted
        }));
    }
}
