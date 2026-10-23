package com.uten.imp.businesschain;

import com.uten.imp.features.subcontract.material_issue.SubcontractSelectedOutboundService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import static org.assertj.core.api.Assertions.assertThat;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false","uten.concurrency.verify-nested-footprint=true",
        "uten.workshop-material.auto-close.enabled=false","uten.inventory.value-work.enabled=false","uten.policy-intelligence.enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class SubcontractSelectedOutboundNoticePostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties){FullChainEndToEndTest.registerDataSource(properties);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired SubcontractSelectedOutboundService commands;
    @AfterEach void clear(){SecurityContextHolder.clearContext();}

    @Test void sourceCardShowsOnlyRemainingBAndDisappearsAfterBWithoutDuplicateCardsOnReplay() {
        var checks=new SubcontractSelectedOutboundEndToEndTest();beans.autowireBean(checks);checks.setup();
        UUID[] keeper=new UUID[1];
        var s=checks.scenario(false,world->{
            keeper[0]=checks.h.fixture.createUserWithPerms(world,"selected-notice-"+UUID.randomUUID(),
                    "notice:read","subcontract_outbound:view","subcontract_outbound:execute");
            db.update("INSERT INTO warehouse_keepers(warehouse_id,employee_id) SELECT ?,employee_id FROM users WHERE id=?",world.warehouseId(),keeper[0]);
        });
        Set<UUID> scope=new java.util.HashSet<>(Set.of(s.source(),s.orderItem(),s.a(),s.b()));
        drain(checks,scope);
        assertThat(active(s.source(),keeper[0])).singleElement().asString().contains("共 2 种物料");
        var a=checks.request(s,s.aItem(),"10");var sent=commands.execute(s.source(),a);scope.add(sent.executionIssueId());
        drain(checks,scope);
        assertThat(active(s.source(),keeper[0])).singleElement().asString().contains("共 1 种物料");
        int afterA=noticeCount(s.source(),keeper[0]);
        assertThat(commands.execute(s.source(),a)).isEqualTo(sent);drain(checks,scope);
        assertThat(noticeCount(s.source(),keeper[0])).isEqualTo(afterA);
        assertThat(active(s.source(),keeper[0])).hasSize(1);
        var b=checks.request(s,s.bItem(),"20");commands.execute(s.source(),b);drain(checks,scope);
        assertThat(active(s.source(),keeper[0])).isEmpty();
        int afterB=noticeCount(s.source(),keeper[0]);commands.execute(s.source(),b);drain(checks,scope);
        assertThat(noticeCount(s.source(),keeper[0])).isEqualTo(afterB);
        assertThat(active(s.source(),keeper[0])).isEmpty();
        assertThat(db.queryForObject("SELECT count(*) FROM business_outbox WHERE event_type='SUBCONTRACT_OUTBOUND_COMPLETED' AND aggregate_id IN (?,?)",Integer.class,s.source(),sent.executionIssueId())).isEqualTo(2);
    }
    private void drain(SubcontractSelectedOutboundEndToEndTest checks,Set<UUID> ids){ReflectionTestUtils.invokeMethod(checks.h,"drainOutboxFor",ids);}
    private List<String> active(UUID source,UUID keeper){return db.queryForList("SELECT content FROM notices WHERE aggregate_id=? AND audience_user_id=? AND source_event='SUBCONTRACT_OUTBOUND_READY' AND resolved_at IS NULL",String.class,source,keeper);}
    private int noticeCount(UUID source,UUID keeper){return db.queryForObject("SELECT count(*) FROM notices WHERE aggregate_id=? AND audience_user_id=? AND source_event='SUBCONTRACT_OUTBOUND_READY'",Integer.class,source,keeper);}
}
