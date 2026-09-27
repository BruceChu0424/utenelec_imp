package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

class AggregatePrivateIntentReaderTest {
    private final UUID batch=UUID.randomUUID(),a=UUID.randomUUID(),b=UUID.randomUUID(),target=UUID.randomUUID();
    private AggregatePrivateIntentReader.Share share(UUID original,String qty,String effective) {
        return new AggregatePrivateIntentReader.Share(batch,target,original,new BigDecimal(qty),new BigDecimal("500"),new BigDecimal(effective));
    }
    @Test void onlyAsPrivateOrderCoversAAndDoesNotInventSupplyForB() {
        var result=AggregatePrivateIntentReader.project(List.of(share(a,"500","500"),share(b,"0","500")));
        assertThat(result.byTarget().get(target).get(a)).isEqualByComparingTo("500");
        assertThat(result.byTarget().get(target).get(b)).isZero();
    }
    @Test void reductionAndCancellationConserveOnlyLivePrivateSupply() {
        var result=AggregatePrivateIntentReader.project(List.of(share(a,"300","250"),share(b,"200","250")));
        assertThat(result.byTarget().get(target).get(a)).isEqualByComparingTo("150");
        assertThat(result.byTarget().get(target).get(b)).isEqualByComparingTo("100");
        var cancelled=AggregatePrivateIntentReader.project(List.of(share(a,"500","0")));
        assertThat(cancelled.byTarget().get(target).get(a)).isZero();
    }
    @Test void separateTargetsCannotBorrowEachOthersPrivateOrderProof() {
        UUID other=UUID.randomUUID();
        var result=AggregatePrivateIntentReader.project(List.of(share(a,"500","500"),
                new AggregatePrivateIntentReader.Share(batch,other,b,BigDecimal.ONE,BigDecimal.ONE,BigDecimal.ONE)));
        assertThat(result.byTarget().get(target)).containsOnlyKeys(a);
        assertThat(result.byTarget().get(other)).containsOnlyKeys(b);
        assertThatThrownBy(()->AggregatePrivateIntentReader.project(List.of(share(a,"400","500")))).isInstanceOf(ApiException.class);
    }
}
