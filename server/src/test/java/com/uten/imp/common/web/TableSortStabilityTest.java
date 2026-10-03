package com.uten.imp.common.web;

import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.data.domain.Sort;
import static org.assertj.core.api.Assertions.*;

class TableSortStabilityTest {
    @Test void tiedBusinessDatesAndUserSelectedAmountsHaveAUniqueFinalOrder() {
        var defaults=Sort.by(Sort.Direction.DESC,"billDate");
        assertThat(TableSort.resolve(null,null,defaults,Map.of()).toList())
                .containsExactly(Sort.Order.desc("billDate"),Sort.Order.desc("id"));
        assertThat(TableSort.resolve("total","asc",defaults,Map.of("total","totalLocal")).toList())
                .containsExactly(Sort.Order.asc("totalLocal"),Sort.Order.asc("id"));
    }
    @Test void unknownInputCannotBecomeAPropertyAndExistingIdIsNotDuplicated() {
        var defaults=Sort.by(Sort.Order.desc("billDate"),Sort.Order.asc("id"));
        assertThat(TableSort.resolve("secretField","desc",defaults,Map.of("date","billDate"))).isEqualTo(defaults);
        assertThat(TableSort.resolve("id","desc",defaults,Map.of("id","id")).toList()).containsExactly(Sort.Order.desc("id"));
    }
    @Test void intentionalCriteriaSortIsPreserved() {
        assertThat(TableSort.resolve(null,null,Sort.unsorted(),Map.of())).isEqualTo(Sort.unsorted());
    }
}
