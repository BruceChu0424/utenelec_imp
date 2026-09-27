package com.uten.imp.features.production.analysis;

import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import static org.assertj.core.api.Assertions.assertThat;

class AggregateMaterialSourceReleaseTest {
    @Test void wholeParentTransferReleasesPreviouslyPreparedChildrenEvenWhenTheirOwnGapWasZero() {
        assertThat(released("1000","0","1","PER_UNIT","1",true)).isEqualByComparingTo("1000");
    }
    @Test void partialParentKeepsAWholePackageStillRequiredByItsOriginalRemainder() {
        assertThat(released("1000","500","100","FIXED_BATCH","1000",false)).isZero();
    }
    @Test void onlyTheActuallyFreedPackagesCanFollowTheTransferredParent() {
        assertThat(released("1500","1000","100","FIXED_BATCH","1000",false)).isEqualByComparingTo("100");
        assertThat(released("1000","500","100","PER_PACKAGE","1000",true)).isEqualByComparingTo("50");
    }
    private BigDecimal released(String before,String after,String qty,String basis,String output,boolean partial) {
        return AggregateMaterialOrderWriteService.releasedChildQuantity(new BigDecimal(before),new BigDecimal(after),new BigDecimal(qty),basis,new BigDecimal(output),partial);
    }
}
