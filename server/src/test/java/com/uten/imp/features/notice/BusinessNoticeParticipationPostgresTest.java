package com.uten.imp.features.notice;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DriverManagerDataSource;
import org.testcontainers.postgresql.PostgreSQLContainer;
import java.util.List;
import java.util.Set;
import static org.assertj.core.api.Assertions.assertThat;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
class BusinessNoticeParticipationPostgresTest {
    @Test void deliveryAndDatabaseListCountHistoryFiltersUseTheSameGrantAndRevocationPolicy() {
        try(var postgres=new PostgreSQLContainer("postgres:16-alpine")) {
            postgres.start();
            var jdbc=new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()));
            NoticeParticipationSqlFixture.install(jdbc);
            jdbc.execute("CREATE TABLE receipt(id integer,route text,event text,resolved boolean)");
            jdbc.update("INSERT INTO receipt VALUES (1,'/sales/orders/123','SALES_ORDER_CANCELED',false),(2,'/sales/orders/456','SALES_ORDER_FINANCE_REJECTED',true),(3,'/production/plans/123',NULL,false),(4,NULL,NULL,false)");
            for(Set<String> grants:List.of(Set.of("notice:read","sales_order:view"),
                    Set.of("notice:read","sales_order:view","sales_order:edit"),Set.of("notice:read","sales_order:view"))) {
                String rules=BusinessNoticeParticipation.readRules(grants);
                for(var row:jdbc.queryForList("SELECT * FROM receipt")) {
                    boolean delivered=BusinessNoticeParticipation.allowed((String)row.get("route"),(String)row.get("event"),grants);
                    assertThat(jdbc.queryForObject("SELECT fn_notice_participation_visible(route,event,?) FROM receipt WHERE id=?",Boolean.class,rules,row.get("id"))).isEqualTo(delivered);
                }
                assertThat(jdbc.queryForObject("SELECT count(*) FROM receipt WHERE fn_notice_participation_visible(route,event,?)",Long.class,rules))
                        .isEqualTo(grants.contains("sales_order:edit")?3L:1L);
            }
            assertThat(jdbc.queryForObject("SELECT count(*) FROM receipt",Long.class)).isEqualTo(4L);
            for(String event:ReviewNoticeCatalog.events()) {
                String rules=BusinessNoticeParticipation.readRules(Set.of("notice:read","sales_order:view"));
                assertThat(jdbc.queryForObject("SELECT fn_notice_participation_visible(NULL,?,?)",Boolean.class,event,rules)).as(event).isFalse();
            }
        }
    }
}
