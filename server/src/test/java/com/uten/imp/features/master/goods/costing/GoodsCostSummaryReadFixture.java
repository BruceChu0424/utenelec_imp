package com.uten.imp.features.master.goods.costing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.ReadScopeVersionAuthority;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.support.MigratedProjectionSchema;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import java.util.Objects;
import java.util.UUID;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/** Real RR/data-query boundary for isolated cost SQL tests. Only the authority
 * stamp is controlled here. These projections deliberately omit production
 * triggers/FKs; runtime-role marker/compactor ACL is owned by the full protocol PG suite. */
final class GoodsCostSummaryReadFixture {
    private GoodsCostSummaryReadFixture() {}
    static void initialize(JdbcTemplate jdbc) {
        MigratedProjectionSchema.createCurrentTables(jdbc,"authorization_state","summary_read_domains","summary_read_markers");
        jdbc.update("INSERT INTO authorization_state(singleton_id,epoch,business_dataset_id,business_reset_generation) VALUES(1,0,?,0)",UUID.randomUUID());
        for(String domain:java.util.List.of("goods-cost-versions","goods-cost-templates"))
            jdbc.update("INSERT INTO summary_read_domains(domain,epoch,compacted_markers) VALUES(?,?,0)",domain,UUID.randomUUID());
    }
    static VersionedSummaryPages reader(JdbcTemplate jdbc,SecurityContextCurrentUser current) {
        var authority=mock(ReadScopeVersionAuthority.class);
        when(authority.scopeForCurrentSnapshot(eq("master_goods_cost"),any(AuthUser.class))).thenReturn("isolated-cost-test-authority");
        return new VersionedSummaryPages(jdbc,authority,current,new ObjectMapper().findAndRegisterModules(),
                new DataSourceTransactionManager(Objects.requireNonNull(jdbc.getDataSource())));
    }
}
