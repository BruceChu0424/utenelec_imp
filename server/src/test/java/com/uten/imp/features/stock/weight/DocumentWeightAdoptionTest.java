package com.uten.imp.features.stock.weight;

import com.uten.imp.application.port.BusinessNumericInputEvidencePort;
import com.uten.imp.common.finance.BusinessPrecisionContext;
import com.uten.imp.common.finance.BusinessPrecisionRequiredException;
import java.math.BigDecimal;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class DocumentWeightAdoptionTest {
    @Test void nativeWeightPreservesZeroUnknownAndEveryFiniteDigit(){
        assertThat(DocumentWeightAdoption.adopt(null)).isNull();
        assertThat(DocumentWeightAdoption.adopt(BigDecimal.ZERO)).isEqualByComparingTo("0");
        assertThat(DocumentWeightAdoption.adopt(new BigDecimal(".123456789012345678901234"))).isEqualByComparingTo(".123456789012345678901234");
    }
    @Test void rawOriginalAndOnlyActuallyUsedPolicyAreKeptInTheSamePrivateCapture()throws Exception {
        BigDecimal raw=new BigDecimal(".1234567890123456789012345");
        assertThatThrownBy(()->DocumentWeightAdoption.adopt(raw)).isInstanceOf(BusinessPrecisionRequiredException.class);
        var evidence=mock(BusinessNumericInputEvidencePort.class);
        try(var context=BusinessPrecisionContext.use(Map.of("weight.kg-field",new BusinessPrecisionContext.Choice(24,"HALF_UP")))){
            var adopted=DocumentWeightAdoption.adopt(raw);
            DocumentWeightAdoption.capture(evidence,"PURCHASE_RECEIPT",UUID.randomUUID(),UUID.randomUUID(),raw,adopted);
        }
        var value=ArgumentCaptor.forClass(BusinessNumericInputEvidencePort.Capture.class);verify(evidence).record(value.capture());
        assertThat(value.getValue().original()).isSameAs(raw);assertThat(value.getValue().recorded()).isEqualByComparingTo(".123456789012345678901235");
        assertThat(value.getValue().usedPolicy()).containsEntry("weight.kg-field",new BusinessPrecisionContext.Choice(24,"HALF_UP"));
        assertThat(value.getValue().originalUnit().code()).isEqualTo("KG");
    }
    @Test void aPositiveWeightCannotBecomeZeroAndRawCapacityIsDistinctFromNative()throws Exception {
        try(var context=BusinessPrecisionContext.use(Map.of("weight.kg-field",new BusinessPrecisionContext.Choice(24,"DOWN")))){
            assertThatThrownBy(()->DocumentWeightAdoption.adopt(new BigDecimal("1e-25"))).isInstanceOfSatisfying(BusinessPrecisionRequiredException.class,e->assertThat(e.details()).containsEntry("selectionRejected",true));
        }
        assertThatThrownBy(()->DocumentWeightAdoption.adopt(new BigDecimal("1e-49"))).isInstanceOf(RuntimeException.class).isNotInstanceOf(BusinessPrecisionRequiredException.class);
    }
}
