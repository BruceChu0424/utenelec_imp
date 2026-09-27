package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class AggregateAdoptionIntentReaderTest {
    private final UUID a=UUID.fromString("00000000-0000-0000-0000-000000000001"),
            b=UUID.fromString("00000000-0000-0000-0000-000000000002"),target=UUID.randomUUID(),claim=UUID.randomUUID();
    private AggregateAdoptionIntentReader.Intent intent(UUID original,String qty,String live) {
        return new AggregateAdoptionIntentReader.Intent(original,target,"MAKE_PUBLIC",claim,new BigDecimal(qty),new BigDecimal("500"),new BigDecimal(live));
    }
    @Test void adoptingOnlyForADoesNotSpreadItsClaimAcrossOtherBomOrigins() {
        var result=AggregateAdoptionIntentReader.project(List.of(intent(a,"500","500")));
        assertThat(result.byOriginal()).containsOnlyKeys(a);
        assertThat(result.byOriginal().get(a)).isEqualByComparingTo("500");
        assertThat(result.coveredByTarget().get(target)).isEqualByComparingTo("500");
    }
    @Test void partialCancellationPreservesRecordedOriginalSharesAndRoundingConservation() {
        var result=AggregateAdoptionIntentReader.project(List.of(intent(a,"300","0.0001"),intent(b,"200","0.0001")));
        assertThat(result.byOriginal().values().stream().reduce(BigDecimal.ZERO,BigDecimal::add)).isEqualByComparingTo("0.0001");
        assertThat(result.byOriginal().get(a)).isEqualByComparingTo("0.0001");
        assertThat(result.coveredByTarget().get(target)).isEqualByComparingTo("0.0001");
        var cancelled=AggregateAdoptionIntentReader.project(List.of(intent(a,"300","0"),intent(b,"200","0")));
        assertThat(cancelled.byOriginal().values()).allMatch(qty->qty.signum()==0);
    }
    @Test void missingOrDuplicatedClaimProofCannotInventAnAdoptionQuantity() {
        assertThatThrownBy(()->AggregateAdoptionIntentReader.project(List.of(intent(a,"300","500")))).isInstanceOf(ApiException.class);
        assertThatThrownBy(()->AggregateAdoptionIntentReader.project(List.of(intent(a,"500","500"),intent(b,"500","500")))).isInstanceOf(ApiException.class);
    }
}
