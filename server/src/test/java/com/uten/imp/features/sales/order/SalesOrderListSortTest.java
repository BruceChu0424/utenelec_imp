package com.uten.imp.features.sales.order;

import com.uten.imp.common.history.RetainedRecordReader;
import com.uten.imp.features.sales.SalesDocumentAccessPolicy;
import com.uten.imp.features.sales.order.dto.OrderQueryFilter;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.test.util.ReflectionTestUtils;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.CALLS_REAL_METHODS;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class SalesOrderListSortTest {
    @Test
    @SuppressWarnings("unchecked")
    void deliveryDateHeaderReachesTheRepositoryBeforePaginationInBothDirections() {
        var repository = mock(SalesOrderRepository.class);
        var service = mock(SalesOrderService.class, CALLS_REAL_METHODS);
        ReflectionTestUtils.setField(service, "orderRepo", repository);
        ReflectionTestUtils.setField(service, "accessPolicy", mock(SalesDocumentAccessPolicy.class));
        service.setRetainedRecords(mock(RetainedRecordReader.class));
        List<Pageable> requested = new ArrayList<>();
        when(repository.findAll(any(Specification.class), any(Pageable.class))).thenAnswer(call -> {
            Pageable page = call.getArgument(1);
            requested.add(page);
            return Page.empty(page);
        });
        var filter = new OrderQueryFilter("source word", null, (short) 1, null, null, null, null, null);

        service.list(filter, 2, 40, "deliverDate", "asc");
        service.list(filter, 2, 40, "deliverDate", "desc");

        assertThat(requested).hasSize(2);
        assertThat(requested.get(0).getSort().toList())
                .containsExactly(Sort.Order.asc("deliverDate"), Sort.Order.asc("id"));
        assertThat(requested.get(1).getSort().toList())
                .containsExactly(Sort.Order.desc("deliverDate"), Sort.Order.desc("id"));
        assertThat(requested).allSatisfy(page -> {
            assertThat(page.getPageNumber()).isEqualTo(1);
            assertThat(page.getPageSize()).isEqualTo(40);
        });
    }
}
