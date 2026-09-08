package com.uten.imp.features.sales.order;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;

import java.time.OffsetDateTime;
import java.util.ArrayList;

import static org.assertj.core.api.Assertions.assertThat;

class SalesOrderRevisionServiceTest {
    private final ObjectMapper mapper = new ObjectMapper();

    @Test
    void reviewShowsChangedHeaderAndAddedRemovedAndRevisedLinesWithoutLosingValues() throws Exception {
        var before = mapper.readTree("""
                {"订单信息":{"交货日期":"2026-09-10","备注":"旧备注"},
                 "产品明细":{"a":{"行号":1,"货品":"A","数量":10},
                               "b":{"行号":2,"货品":"B","数量":5}}}
                """);
        var after = mapper.readTree("""
                {"订单信息":{"交货日期":"2026-09-20","备注":"旧备注"},
                 "产品明细":{"a":{"行号":1,"货品":"A","数量":12},
                               "c":{"行号":3,"货品":"C","数量":7}}}
                """);
        var changes = new ArrayList<SalesOrderRevisionService.FieldChange>();
        SalesOrderRevisionService.collectChanges("", before, after,
                "销售员", OffsetDateTime.now(), changes);
        assertThat(changes).hasSize(4);
        assertThat(changes).anySatisfy(change -> {
            assertThat(change.field()).isEqualTo("订单信息 / 交货日期");
            assertThat(change.beforeValue()).isEqualTo("2026-09-10");
            assertThat(change.afterValue()).isEqualTo("2026-09-20");
        });
        assertThat(changes).anySatisfy(change -> {
            assertThat(change.field()).contains("第 2 行 B");
            assertThat(change.beforeValue()).contains("数量: 5");
            assertThat(change.afterValue()).isEqualTo("未设置");
        });
        assertThat(changes).noneMatch(change -> change.field().contains("备注"));
    }
}
