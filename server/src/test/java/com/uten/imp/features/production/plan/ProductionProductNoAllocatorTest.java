package com.uten.imp.features.production.plan;

import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class ProductionProductNoAllocatorTest {

    @Test
    void delegatesAtomicAuthorityToDatabaseAndSkipsAnExplicitRequestNumber() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        UUID planId = UUID.randomUUID();
        when(jdbc.queryForObject(
                "SELECT fn_allocate_production_product_no(?)", String.class, planId))
                .thenReturn("SJ20260814000001-001")
                .thenReturn("SJ20260814000001-002");
        ProductionProductNoAllocator allocator = new ProductionProductNoAllocator(jdbc);

        String result = allocator.allocate(
                planId, Set.of("SJ20260814000001-001"));

        assertThat(result).isEqualTo("SJ20260814000001-002");
        verify(jdbc, times(2)).queryForObject(
                "SELECT fn_allocate_production_product_no(?)", String.class, planId);
    }

    @Test
    void requestExplicitNumbersAreExcludedBeforeDatabaseClaim() {
        JdbcTemplate jdbc = mock(JdbcTemplate.class);
        UUID planId = UUID.randomUUID();
        when(jdbc.queryForObject(
                "SELECT fn_allocate_production_product_no(?)", String.class, planId))
                .thenReturn("sj20260814000002-002");
        ProductionProductNoAllocator allocator = new ProductionProductNoAllocator(jdbc);

        String result = allocator.allocate(
                planId, Set.of("SJ20260814000002-001"));

        assertThat(result).isEqualTo("SJ20260814000002-002");
        verify(jdbc).queryForObject(
                "SELECT fn_allocate_production_product_no(?)", String.class, planId);
    }
}
