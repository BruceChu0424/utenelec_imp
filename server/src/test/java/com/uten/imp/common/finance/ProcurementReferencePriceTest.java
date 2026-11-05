package com.uten.imp.common.finance;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.purchase.order.PurchaseOrderItem;
import com.uten.imp.features.subcontract.order.SubcontractOrderItem;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import java.math.BigDecimal;
import java.util.Map;
import java.util.List;
import java.util.UUID;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;
import static org.mockito.ArgumentMatchers.*;

class ProcurementReferencePriceTest {
    private static final String PURPOSE = "money.reference-unit-price";

    @ParameterizedTest
    @CsvSource({"4,HALF_UP,0.1667", "4,DOWN,0.1666", "10,HALF_UP,0.1666666667", "10,DOWN,0.1666666666",
            "24,HALF_UP,0.166666666666666666666667", "24,DOWN,0.166666666666666666666666"})
    void explicitChoiceIsFrozenAndAnotherReviewersChoiceCannotReplaceIt(int scale, String rounding, String expected)
            throws Exception {
        ProcurementReferencePrice.Adoption adopted;
        try (var ignored = BusinessPrecisionContext.use(Map.of(PURPOSE, new BusinessPrecisionContext.Choice(scale, rounding)))) {
            adopted = ProcurementReferencePrice.adopt(BigDecimal.ONE, new BigDecimal("6"));
        }
        assertThat(adopted.price()).isEqualByComparingTo(expected);
        var current = Map.of(PURPOSE, new BusinessPrecisionContext.Choice(0, "DOWN"));
        try (var ignored = BusinessPrecisionContext.use(current)) {
            assertThat(ProcurementReferencePrice.proofPrice(BigDecimal.ONE, new BigDecimal("6"), adopted.policy()))
                    .isEqualByComparingTo(expected);
            assertThat(ProcurementReferencePrice.baseAmount(new BigDecimal("6"), adopted.price(), BigDecimal.ONE, adopted.policy()))
                    .isEqualByComparingTo("1");
            assertThat(BusinessPrecisionContext.choices()).isEqualTo(current);
            assertThat(BusinessPrecisionContext.usedChoices()).isEmpty();
        }
    }

    @Test void historicalNullProofKeepsTheOriginalTenPlaceDownContract() throws Exception {
        try (var ignored = BusinessPrecisionContext.use(Map.of(PURPOSE, new BusinessPrecisionContext.Choice(4, "HALF_UP")))) {
            assertThat(ProcurementReferencePrice.proofPrice(BigDecimal.ONE, new BigDecimal("6"), null))
                    .isEqualByComparingTo("0.1666666666");
            assertThat(ProcurementReferencePrice.baseAmount(new BigDecimal("6"), new BigDecimal("0.1666666666"), BigDecimal.ONE, null))
                    .isEqualByComparingTo("1");
        }
    }

    @Test void newRepeatingPriceStillRequiresAnExplicitChoice() throws Exception {
        try (var ignored = BusinessPrecisionContext.use(Map.of())) {
            assertThatThrownBy(() -> ProcurementReferencePrice.adopt(BigDecimal.ONE, new BigDecimal("3")))
                    .isInstanceOf(BusinessPrecisionRequiredException.class);
        }
    }

    @Test void exactPriceNeedsNoRoundingAndTheAgreedTotalRetainsAllItsDigits() throws Exception {
        try (var ignored = BusinessPrecisionContext.use(Map.of())) {
            BigDecimal total = new BigDecimal("2.000000000000000000000002");
            var adopted = ProcurementReferencePrice.adopt(total, new BigDecimal("2"));
            assertThat(adopted.price()).isEqualByComparingTo("1.000000000000000000000001");
            assertThat(ProcurementReferencePrice.baseAmount(new BigDecimal("2"), adopted.price(), total, adopted.policy()))
                    .isEqualByComparingTo(total);
        }
    }

    @Test void aDifferentValidRoundingIsNotAProofForTheStoredPrice() throws Exception {
        ProcurementReferencePrice.Adoption down;
        try (var ignored = BusinessPrecisionContext.use(Map.of(PURPOSE, new BusinessPrecisionContext.Choice(4, "DOWN")))) {
            down = ProcurementReferencePrice.adopt(BigDecimal.ONE, new BigDecimal("6"));
        }
        assertThatThrownBy(() -> ProcurementReferencePrice.baseAmount(new BigDecimal("6"), new BigDecimal("0.1667"), BigDecimal.ONE, down.policy()))
                .isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> ProcurementReferencePrice.proofPrice(BigDecimal.ONE, new BigDecimal("6"), Map.of("version", 2, "choices", Map.of())))
                .isInstanceOf(ApiException.class);
    }

    @Test void unitPriceModeDoesNotBorrowATotalPriceProof() {
        assertThat(ProcurementReferencePrice.baseAmount(new BigDecimal("2"), new BigDecimal("3.5"), null, null))
                .isEqualByComparingTo("7");
        assertThatThrownBy(() -> ProcurementReferencePrice.baseAmount(BigDecimal.ONE, BigDecimal.ONE, null,
                Map.of("version", 1, "choices", Map.of()))).isInstanceOf(ApiException.class);
    }

    @Test void internalPolicyIsNotAnEditableOrExportedEntityField() throws Exception {
        var purchase = new PurchaseOrderItem();
        var subcontract = new SubcontractOrderItem();
        var proof = Map.<String, Object>of("version", 1, "choices", Map.of());
        purchase.setReferencePricePrecisionPolicy(proof);
        subcontract.setReferencePricePrecisionPolicy(proof);
        var json = new ObjectMapper();
        assertThat(json.valueToTree(purchase).has("referencePricePrecisionPolicy")).isFalse();
        assertThat(json.valueToTree(subcontract).has("referencePricePrecisionPolicy")).isFalse();
        String client = "{\"referencePricePrecisionPolicy\":{\"version\":1,\"choices\":{}}}";
        assertThat(json.readValue(client, PurchaseOrderItem.class).getReferencePricePrecisionPolicy()).isNull();
        assertThat(json.readValue(client, SubcontractOrderItem.class).getReferencePricePrecisionPolicy()).isNull();
        assertThat(PurchaseOrderItem.class.getDeclaredField("referencePricePrecisionPolicy")
                .isAnnotationPresent(jakarta.persistence.Transient.class)).isTrue();
        assertThat(SubcontractOrderItem.class.getDeclaredField("referencePricePrecisionPolicy")
                .isAnnotationPresent(jakarta.persistence.Transient.class)).isTrue();
    }

    @Test void persistedProofIsLoadedOnceForTheTotalPricedRowsAndNeverTakenFromTheReviewSession() throws Exception {
        var priced = new PurchaseOrderItem(); priced.setId(UUID.randomUUID()); priced.setTotalAmountInput(BigDecimal.ONE);
        var ordinary = new PurchaseOrderItem(); ordinary.setId(UUID.randomUUID());
        EntityManager em = mock(EntityManager.class); Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query);
        when(query.setParameter(anyString(), any())).thenReturn(query);
        String stored = "{\"version\":1,\"choices\":{\"money.reference-unit-price\":{\"scale\":4,\"rounding\":\"DOWN\"}}}";
        when(query.getResultList()).thenReturn(java.util.Collections.singletonList(new Object[]{priced.getId(), stored}));
        ProcurementReferencePrice.loadPolicies(em, "PURCHASE", List.of(priced, ordinary));
        assertThat(ProcurementReferencePrice.proofPrice(BigDecimal.ONE, new BigDecimal("6"), priced.getReferencePricePrecisionPolicy()))
                .isEqualByComparingTo("0.1666");
        verify(query).setParameter("ids", java.util.Set.of(priced.getId()));
        verify(em).flush();
        assertThat(ordinary.getReferencePricePrecisionPolicy()).isNull();
    }

    @Test void missingPersistedRowsAreNotMisrepresentedAsHistoricalNullProofs() {
        var priced = new SubcontractOrderItem(); priced.setId(UUID.randomUUID()); priced.setTotalAmountInput(BigDecimal.ONE);
        EntityManager em = mock(EntityManager.class); Query query = mock(Query.class);
        when(em.createNativeQuery(anyString())).thenReturn(query); when(query.setParameter(anyString(), any())).thenReturn(query);
        when(query.getResultList()).thenReturn(List.of());
        assertThatThrownBy(() -> ProcurementReferencePrice.loadPolicies(em, "SUBCONTRACT", List.of(priced)))
                .isInstanceOf(ApiException.class);
    }
}
