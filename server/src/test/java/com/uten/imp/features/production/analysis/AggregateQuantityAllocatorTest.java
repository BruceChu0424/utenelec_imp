package com.uten.imp.features.production.analysis;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.math.BigDecimal;
import java.time.Duration;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Random;
import java.util.UUID;

import static com.uten.imp.features.production.analysis.AggregateQuantityAllocator.*;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.junit.jupiter.api.Assertions.assertTimeout;

class AggregateQuantityAllocatorTest {
    private static final UUID A = new UUID(0, 1), B = new UUID(0, 2), C = new UUID(0, 3);
    private static final LocalDate TODAY = LocalDate.of(2026, 9, 25);
    private static BigDecimal qty(String value) { return new BigDecimal(value); }
    private static SourceCapacity source(UUID id, String remaining) { return new SourceCapacity(id, 1, TODAY, qty(remaining)); }

    @Test void threeProductsReceiveProportionalPartsOfOneMaterialOrder() {
        Result result = allocate(qty("1500"), List.of(source(A,"1000"),source(B,"1000"),source(C,"1000")),false);
        assertThat(result.allocations()).extracting(Allocation::qty)
                .containsExactly(qty("500.0000"),qty("500.0000"),qty("500.0000"));
        assertThat(result.publicExtraQty()).isEqualByComparingTo("0");
    }

    @Test void alreadyArrangedSourcesGetNoNewDemandAndExtraStaysExplicitlyPublic() {
        Result result = allocate(qty("250"), List.of(source(A,"0"),source(B,"100"),source(C,"100")),true);
        assertThat(result.allocations()).extracting(Allocation::sourceId).containsExactly(B,C);
        assertThat(result.allocations()).extracting(Allocation::qty).containsExactly(qty("100.0000"),qty("100.0000"));
        assertThat(result.publicExtraQty()).isEqualByComparingTo("50");
        assertThatThrownBy(() -> allocate(qty("250"),List.of(source(B,"100"),source(C,"100")),false)).isInstanceOf(ApiException.class);
    }

    @Test void priorityAndThenDueDateHavePrecedenceOverProportions() {
        Result result = allocate(qty("125"),List.of(new SourceCapacity(A,2,TODAY.minusDays(2),qty("100")),
                new SourceCapacity(B,1,TODAY,qty("100")),new SourceCapacity(C,1,null,qty("100"))),false);
        assertThat(result.allocations()).containsExactly(new Allocation(B,qty("100.0000")),new Allocation(C,qty("25.0000")));
    }

    @Test void equalPriorityAndDateUseWeightsAndStableResidualTicks() {
        Result result = allocate(qty("1"),List.of(source(C,"1"),source(A,"1"),source(B,"1")),false);
        assertThat(result.allocations()).containsExactly(new Allocation(A,qty("0.3334")),
                new Allocation(B,qty("0.3333")),new Allocation(C,qty("0.3333")));
        assertThat(allocate(qty("0.0001"),List.of(source(A,"0"),source(B,"1"),source(C,"1")),false).allocations())
                .containsExactly(new Allocation(B,qty("0.0001")));
    }

    @Test void UUIDOrderDoesNotChangeAtTheSignedLongBoundary() {
        UUID low = UUID.fromString("7fffffff-ffff-ffff-ffff-ffffffffffff");
        UUID high = UUID.fromString("80000000-0000-0000-0000-000000000000");
        assertThat(allocate(qty("0.0001"),List.of(source(high,"1"),source(low,"1")),false).allocations())
                .containsExactly(new Allocation(low,qty("0.0001")));
    }

    @Test void zeroPreviewAndEquivalentDecimalScalesDoNotInventOrders() {
        assertThat(allocate(qty("0.000000"),List.of(),false).allocations()).isEmpty();
        assertThat(allocate(qty("1.000000"),List.of(source(A,"1.000000")),false).allocations())
                .containsExactly(new Allocation(A,qty("1.0000")));
        assertThatThrownBy(() -> allocate(qty("1"),List.of(),true)).isInstanceOf(ApiException.class);
    }

    @Test void invalidIdentitiesOrQuantitiesAreRejectedBeforeAnyAllocation() {
        for (String invalid : List.of("-1","0.00001","100000000000000","1E100")) {
            assertThatThrownBy(() -> allocate(qty(invalid),List.of(source(A,"1")),true)).isInstanceOf(ApiException.class);
            assertThatThrownBy(() -> allocate(qty("1"),List.of(source(A,invalid)),true)).isInstanceOf(ApiException.class);
        }
        assertThatThrownBy(() -> allocate(null,List.of(source(A,"1")),false)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> allocate(qty("1"),null,false)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> allocate(qty("1"),List.of(source(A,"1"),source(A,"2")),false)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> allocate(qty("1"),List.of(new SourceCapacity(null,1,TODAY,qty("2"))),false)).isInstanceOf(ApiException.class);
        assertThatThrownBy(() -> allocate(qty("1"),Collections.singletonList(null),false)).isInstanceOf(ApiException.class);
    }

    @Test void repeatedRandomAllocationConservesQuantityAndNeverExceedsAnySource() {
        Random random = new Random(119);
        for (int sample=0; sample<250; sample++) {
            List<SourceCapacity> sources = new ArrayList<>();
            BigDecimal sum = BigDecimal.ZERO;
            for(int i=0;i<25;i++) {
                BigDecimal cap = BigDecimal.valueOf(random.nextInt(100_000),4);
                sources.add(new SourceCapacity(new UUID(0,i+1),random.nextInt(3),TODAY.plusDays(random.nextInt(2)),cap));
                sum=sum.add(cap);
            }
            BigDecimal total=sum.multiply(qty("0.731")).setScale(4,java.math.RoundingMode.DOWN);
            Result expected = allocate(total,sources,false);
            Collections.shuffle(sources,random);
            assertThat(allocate(total,sources,false)).isEqualTo(expected);
            assertThat(expected.allocations().stream().map(Allocation::qty).reduce(expected.publicExtraQty(),BigDecimal::add)).isEqualByComparingTo(total);
            for(Allocation allocation:expected.allocations()) {
                BigDecimal cap=sources.stream().filter(s->s.sourceId().equals(allocation.sourceId())).findFirst().orElseThrow().remainingQty();
                assertThat(allocation.qty()).isPositive().isLessThanOrEqualTo(cap);
            }
        }
    }

    @Test void largeQuantitiesHaveSourceBoundedWorkRatherThanOneLoopPerQuantityTick() {
        List<SourceCapacity> sources = new ArrayList<>();
        for(int i=0;i<10_000;i++) sources.add(source(new UUID(0,i+1),"9999999999.9999"));
        Result result = assertTimeout(Duration.ofSeconds(5), () -> allocate(qty("99999999999999.9999"),sources,true));
        assertThat(result.allocations()).hasSize(10_000);
        assertThat(result.publicExtraQty()).isEqualByComparingTo("0.9999");
        assertThat(result.allocations().stream().map(Allocation::qty).reduce(result.publicExtraQty(),BigDecimal::add))
                .isEqualByComparingTo("99999999999999.9999");
    }
}
