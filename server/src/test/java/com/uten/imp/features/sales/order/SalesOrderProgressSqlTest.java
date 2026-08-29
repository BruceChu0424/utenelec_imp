package com.uten.imp.features.sales.order;

import com.uten.imp.security.DocumentAccessPolicy.NativeReadScope;
import org.junit.jupiter.api.Test;

import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;

class SalesOrderProgressSqlTest {

    @Test
    void seeAllScopeIsSeparatedFromTheGroupedQueryClause() {
        String sql = SalesOrderService.progressGroupedSql(
                new NativeReadScope("1=1", null, Set.of()));

        assertThat(sql)
                .contains("AND 1=1\nGROUP BY")
                .doesNotContain("1=1GROUP BY");
    }
}
