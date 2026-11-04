package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.finance.gl.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import java.util.List;
import static org.assertj.core.api.Assertions.*;

/** Actual migrated transactions prove import replay, native account creation and allocation rollback. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
class FinanceChartImportPostgresTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired FinanceChartService chart;
    @Autowired JdbcTemplate db;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}
    @Test void all177OriginalCodesImportWithoutMoneyAndNativeMappingIsAtomicAndReplayable()throws Exception {
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);
        var world=fixture.seedWorld("finance-chart");fixture.loginAs(world.superAdminUserId());
        int journalBefore=db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class);
        byte[] source=getClass().getResourceAsStream("/finance/finance-chart-codes.xls").readAllBytes();
        var preview=chart.preview("2026年9月份科目余额表代码.xls",source);
        assertThat(preview.rows()).hasSize(177);assertThat(preview.issues()).isEmpty();
        var applied=chart.apply(new FinanceChartContracts.Apply(preview.importId()));
        assertThat(applied.imported()).isEqualTo(177);
        assertThat(chart.apply(new FinanceChartContracts.Apply(preview.importId()))).isEqualTo(applied);
        assertThat(chart.preview("同一文件.xls",source).importId()).isEqualTo(preview.importId());
        assertThat(chart.list()).hasSize(177);
        assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(journalBefore);
        var account=chart.list().stream().filter(a->a.code().equals("1001")).findFirst().orElseThrow();
        var create=new FinanceChartContracts.CreateTarget(account.version(),"ACCOUNT");
        chart.createTarget("1001",create);chart.createTarget("1001",create);
        account=chart.list().stream().filter(a->a.code().equals("1001")).findFirst().orElseThrow();
        assertThat(account.targets()).hasSize(1);var nativeId=account.targets().getFirst().id();
        var mapping=new FinanceChartContracts.Mapping(account.version(),List.of(nativeId),"BS_1",null);
        chart.map("1001",mapping);chart.map("1001",mapping);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_report_line_bindings WHERE line_key='BS_1' AND style_id=?",Integer.class,nativeId)).isEqualTo(1);
        var bank=chart.list().stream().filter(a->a.code().equals("100201")).findFirst().orElseThrow();
        assertThatThrownBy(()->chart.map("100201",new FinanceChartContracts.Mapping(bank.version(),List.of(nativeId),"BS_1",null)))
                .isInstanceOf(ApiException.class).hasMessageContaining("重复归集");
        var current=chart.list().stream().filter(a->a.code().equals("1001")).findFirst().orElseThrow();
        assertThatThrownBy(()->chart.map("1001",new FinanceChartContracts.Mapping(current.version(),List.of(nativeId),null,"PL_1")))
                .isInstanceOf(ApiException.class);
        assertThat(db.queryForObject("SELECT count(*) FROM finance_report_line_bindings WHERE line_key='BS_1' AND style_id=?",Integer.class,nativeId)).isEqualTo(1);
        assertThat(db.queryForObject("SELECT count(*) FROM gl_entries",Integer.class)).isEqualTo(journalBefore);
        var other=fixture.seedWorld("finance-chart-other");fixture.loginAs(other.superAdminUserId());
        assertThatThrownBy(()->chart.imported(preview.importId())).isInstanceOf(ApiException.class).hasMessageContaining("不属于当前账号");
    }
}
