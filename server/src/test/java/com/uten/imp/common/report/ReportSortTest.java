package com.uten.imp.common.report;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class ReportSortTest {
    @Test
    void onlyServerAliasesAndLiteralDirectionsBecomeSql() {
        var keys = List.of("goodsCode", "amount");
        assertThat(ReportSort.resolveOrderBy("amount", "DeSc", "id ASC", keys))
                .isEqualTo("\"amount\" DESC");
        assertThat(ReportSort.resolveOrderBy("goodsCode", "asc; SELECT pg_sleep(1)", "id ASC", keys))
                .isEqualTo("\"goodsCode\" ASC");
        for (String request : List.of("amount\" DESC; SELECT pg_sleep(1)--", "amount DESC", "unknown")) {
            assertThat(ReportSort.resolveOrderBy(request, "desc", "id ASC", keys)).isEqualTo("id ASC");
        }
    }

    @Test
    void absentControlsKeepTheReportsOwnStableDefault() {
        assertThat(ReportSort.resolveOrderBy(null, null, "bill_date DESC, id", List.of("amount")))
                .isEqualTo("bill_date DESC, id");
        assertThat(ReportSort.resolveOrderBy("amount", "desc", "id", null)).isEqualTo("id");
    }
}
