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
    @Test void narrowActorsAndSilentViewersHaveTheSameLivePolicyInDeliveryAndPostgres() {
        try(var postgres=new PostgreSQLContainer("postgres:16-alpine")) {
            postgres.start();
            var jdbc=new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()));
            NoticeParticipationSqlFixture.install(jdbc);
            for(var contract:List.of(
                    List.of("/subcontract/orders/123","subcontract_order:view","subcontract_order:submit_finance","PROCUREMENT_FINANCE_REJECTED"),
                    List.of("/production/plans/123","production_plan:view","production_planning_package:generate","PRODUCTION_MATERIAL_INCREMENT_SUBMITTED"))) {
                var actor=new java.util.HashSet<>(Set.of("notice:read",contract.get(1),contract.get(2)));
                for(boolean subscribed:List.of(true,false,true)) {
                    if(subscribed) actor.add(contract.get(2));else actor.remove(contract.get(2));
                    assertThat(BusinessNoticeParticipation.allowed(contract.get(0),"GOODS_BOM_UPDATED",actor)).isEqualTo(subscribed);
                    assertThat(jdbc.queryForObject("SELECT fn_notice_participation_visible(?,?,?)",Boolean.class,
                            contract.get(0),"GOODS_BOM_UPDATED",BusinessNoticeParticipation.readRules(actor))).isEqualTo(subscribed);
                    // A precise action event takes precedence over the ordinary route fallback.
                    assertThat(jdbc.queryForObject("SELECT fn_notice_participation_visible(?,?,?)",Boolean.class,
                            contract.get(0),contract.get(3),BusinessNoticeParticipation.readRules(actor))).isFalse();
                }
                for(Set<String> silent:List.of(Set.of("notice:read",contract.get(1)),Set.of("notice:read",contract.get(2)),
                        Set.of(contract.get(1),contract.get(2)),Set.of("notice:read",contract.get(1),
                                "company_file:view","company_file:edit","company_file:upload","company_file:manage_permissions","attachment:upload"))) {
                    assertThat(BusinessNoticeParticipation.allowed(contract.get(0),"GOODS_BOM_UPDATED",silent)).isFalse();
                    assertThat(jdbc.queryForObject("SELECT fn_notice_participation_visible(?,?,?)",Boolean.class,
                            contract.get(0),"GOODS_BOM_UPDATED",BusinessNoticeParticipation.readRules(silent))).isFalse();
                }
            }
        }
    }

    @Test void deliveryAndDatabaseListCountHistoryFiltersUseTheSameGrantAndRevocationPolicy() {
        try(var postgres=new PostgreSQLContainer("postgres:16-alpine")) {
            postgres.start();
            var jdbc=new JdbcTemplate(new DriverManagerDataSource(postgres.getJdbcUrl(),postgres.getUsername(),postgres.getPassword()));
            NoticeParticipationSqlFixture.install(jdbc);
            jdbc.execute("CREATE TABLE notice_participation_probe_receipt(id integer,route text,event text,resolved boolean)");
            jdbc.update("INSERT INTO notice_participation_probe_receipt VALUES (1,'/sales/orders/123','SALES_ORDER_CANCELED',false),(2,'/sales/orders/456','SALES_ORDER_FINANCE_REJECTED',true),(3,'/production/plans/123',NULL,false),(4,NULL,NULL,false)");
            for(Set<String> grants:List.of(Set.of("notice:read","sales_order:view"),
                    Set.of("notice:read","sales_order:view","sales_order:edit"),Set.of("notice:read","sales_order:view"))) {
                String rules=BusinessNoticeParticipation.readRules(grants);
                for(var row:jdbc.queryForList("SELECT * FROM notice_participation_probe_receipt")) {
                    boolean delivered=BusinessNoticeParticipation.allowed((String)row.get("route"),(String)row.get("event"),grants);
                    assertThat(jdbc.queryForObject("SELECT fn_notice_participation_visible(route,event,?) FROM notice_participation_probe_receipt WHERE id=?",Boolean.class,rules,row.get("id"))).isEqualTo(delivered);
                }
                assertThat(jdbc.queryForObject("SELECT count(*) FROM notice_participation_probe_receipt WHERE fn_notice_participation_visible(route,event,?)",Long.class,rules))
                        .isEqualTo(grants.contains("sales_order:edit")?3L:1L);
            }
            assertThat(jdbc.queryForObject("SELECT count(*) FROM notice_participation_probe_receipt",Long.class)).isEqualTo(4L);
            jdbc.update("INSERT INTO notice_participation_probe_receipt VALUES (5,'/profile/me/changes','PROFILE_CHANGE_APPROVED',true),(6,'/profile/edit','PROFILE_CHANGE_REJECTED',false)");
            for (Set<String> grants : List.of(Set.of("notice:read", "profile_change:view"),
                    Set.of("notice:read", "profile:edit:self"), Set.of("notice:read", "profile_change:view"))) {
                String rules=BusinessNoticeParticipation.readRules(grants);
                assertThat(jdbc.queryForObject("SELECT count(*) FROM notice_participation_probe_receipt WHERE id IN(5,6) AND fn_notice_participation_visible(route,event,?)",
                        Long.class,rules)).isEqualTo(grants.contains("profile:edit:self")?2L:0L);
                for (var row : jdbc.queryForList("SELECT * FROM notice_participation_probe_receipt WHERE id IN(5,6)")) {
                    assertThat(jdbc.queryForObject("SELECT fn_notice_participation_visible(route,event,?) FROM notice_participation_probe_receipt WHERE id=?",
                            Boolean.class,rules,row.get("id"))).isEqualTo(BusinessNoticeParticipation.allowed(
                                    (String)row.get("route"),(String)row.get("event"),grants));
                }
            }
            assertThat(jdbc.queryForObject("SELECT count(*) FROM notice_participation_probe_receipt",Long.class)).isEqualTo(6L);
            for (var example : LegacyProfileResultNoticeFixture.examples(java.util.UUID.randomUUID())) {
                for (Set<String> grants : List.of(Set.of("notice:read","profile_change:view"),
                        Set.of("notice:read","profile:edit:self"))) {
                    assertThat(jdbc.queryForObject("SELECT fn_notice_participation_visible(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                            Boolean.class,LegacyProfileResultNoticeFixture.sqlArguments(example.notice(),BusinessNoticeParticipation.readRules(grants))))
                            .isEqualTo(BusinessNoticeParticipation.allowed(example.notice(),grants));
                }
                assertThat(example.notice().getAggregateId()).isNull();
            }
            for(String event:ReviewNoticeCatalog.events()) {
                String rules=BusinessNoticeParticipation.readRules(Set.of("notice:read","sales_order:view"));
                assertThat(jdbc.queryForObject("SELECT fn_notice_participation_visible(NULL,?,?)",Boolean.class,event,rules)).as(event).isFalse();
            }
        }
    }
}
