package com.uten.imp.businesschain;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.common.taskclaim.TaskClaimService;
import com.uten.imp.features.sales.shipment.*;
import com.uten.imp.features.sales.shipment.dto.*;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.*;
import org.springframework.test.util.ReflectionTestUtils;
import java.math.BigDecimal;
import java.util.*;
import static org.assertj.core.api.Assertions.*;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only","uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789","uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test","uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@FinanceScopedChain
class FinanceShipmentReproductionEndToEndTest {
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FinanceScopedChainDatabase.register(registry,FinanceShipmentReproductionEndToEndTest.class);}
    @Autowired AutowireCapableBeanFactory beans;@Autowired JdbcTemplate db;@Autowired SalesShipmentService shipments;@Autowired SalesShipmentPrintService prints;@Autowired TaskClaimService claims;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}
    @Test void approvedActorAndOriginalTwelvePaperColumnsStayFrozenWhileRevocationRetiresPrintAuthorization(){
        var fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);var w=fixture.seedWorld("finance-original-paper");fixture.loginAs(w.superAdminUserId());
        ReflectionTestUtils.invokeMethod(fixture,"putDirectTargetStock",w,w.goodsE(),"10");UUID order=fixture.createApprovedOrder(w,w.goodsE(),"10","100");UUID item=db.queryForObject("SELECT id FROM sales_order_items WHERE order_id=?",UUID.class,order);
        ShipmentSaveRequest request=ReflectionTestUtils.invokeMethod(fixture,"shipmentRequest",w,item,w.goodsE(),"10");var draft=shipments.create(request);
        db.update("UPDATE goods SET model='MODEL-ORIGINAL',series='SERIES-ORIGINAL' WHERE id=?",w.goodsE());
        assertThatThrownBy(()->prints.read(draft.getId())).isInstanceOf(ApiException.class).hasMessageContaining("尚未财务审核");
        var lease=claims.claim("SALES_SHIPMENT_FINANCE_AUDIT",draft.getId().toString());var info=shipments.financeAuditInfo(draft.getId());
        shipments.financeAudit(draft.getId(),new ShipmentFinanceDecisionRequest(((Number)info.get("reviewRevision")).longValue(),info.get("contentHash").toString(),lease.claimId(),null,new BigDecimal("7")));
        var paper=prints.read(draft.getId());assertThat(paper.headers()).containsExactly("序号","编号","产品型号","系列","产品名称","颜色","单位","数量","单价","折扣","金额","备注");assertThat(paper.title()).isEqualTo("发货清单");assertThat(paper.formCode()).isEqualTo("YT-FM-XS-05");
        assertThat(paper.lines().getFirst().model()).isEqualTo("MODEL-ORIGINAL");assertThat(paper.lines().getFirst().series()).isEqualTo("SERIES-ORIGINAL");assertThat(paper.financeAuditorName()).isNotBlank().doesNotContain("历史未留");
        assertThat(paper.signatures()).extracting(s->s.label()).containsExactly("仓管","制单员","审核员","仓库审核","客户签名");assertThat(paper.signatures().get(2).name()).isEqualTo(paper.financeAuditorName());
        UUID actor=db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,w.superAdminUserId());
        db.update("UPDATE employees SET full_name='已改名的当前姓名' WHERE id=?",actor);db.update("UPDATE goods SET model='CURRENT-MODEL',series='CURRENT-SERIES' WHERE id=?",w.goodsE());
        var after=prints.read(draft.getId());assertThat(after.financeAuditorName()).isEqualTo(paper.financeAuditorName());assertThat(after.lines().getFirst().model()).isEqualTo("MODEL-ORIGINAL");assertThat(after.contentDigest()).isEqualTo(paper.contentDigest());prints.authorize(draft.getId(),paper.contentDigest());
        assertThat(db.queryForObject("SELECT actual_receipt_context IS NOT NULL AND print_context IS NOT NULL AND actor_name_snapshot IS NOT NULL FROM sales_shipment_finance_release_events WHERE shipment_id=? AND event_type='RELEASED'",Boolean.class,draft.getId())).isTrue();
        shipments.financeAuditReverse(draft.getId());assertThatThrownBy(()->prints.authorize(draft.getId(),paper.contentDigest())).isInstanceOf(ApiException.class).hasMessageContaining("尚未财务审核");
        assertThat(db.queryForObject("SELECT finance_auditor_name_snapshot FROM sales_shipments WHERE id=?",String.class,draft.getId())).isNull();
        assertThat(db.queryForObject("SELECT actor_name_snapshot FROM sales_shipment_finance_release_events WHERE shipment_id=? AND event_type='RELEASED'",String.class,draft.getId())).isEqualTo(paper.financeAuditorName());
    }
}
