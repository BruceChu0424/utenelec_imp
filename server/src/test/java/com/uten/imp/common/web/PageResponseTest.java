package com.uten.imp.common.web;

import org.junit.jupiter.api.Test;
import org.springframework.data.domain.PageImpl;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class PageResponseTest {
    @Test
    void reportsTheBoundedPageActuallyQueried() {
        // 2026-11-08 上限随 CompleteReadBatchPlan 到 200：两整页再多一行，页数语义不变。
        long total = 2L * Pageables.MAX_PAGE_SIZE + 1;
        var pageable = Pageables.of(0, 100_000);
        var result = new PageImpl<>(List.of("record"), pageable, total);
        var response = new PageResponse<>(List.of("mapped record"), result);

        assertThat(response.getItems()).containsExactly("mapped record");
        assertThat(response.getPage()).isEqualTo(1);
        assertThat(response.getSize()).isEqualTo(Pageables.MAX_PAGE_SIZE);
        assertThat(response.getTotal()).isEqualTo(total);
        assertThat(response.getTotalPages()).isEqualTo(3);
    }

    @Test
    void emptyLaterPagesKeepTheirActualIndexAndSize() {
        var pageable = Pageables.of(4, 10);
        var result = new PageImpl<String>(List.of(), pageable, 21);
        var response = new PageResponse<>(List.of(), result);

        assertThat(response.getItems()).isEmpty();
        assertThat(response.getPage()).isEqualTo(4);
        assertThat(response.getSize()).isEqualTo(10);
        assertThat(response.getTotalPages()).isEqualTo(3);
    }
}
