package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.notice.NoticeService;
import com.uten.imp.features.notice.ChainNoticeService;
import com.uten.imp.features.production.dailyreport.ProductionDailyReportService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import java.util.Map;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;

/** Real output/report and real authenticated reads: delivered cards never retain revoked plan scope. */
@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS",matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK,properties={
        "spring.profiles.active=dev","uten.audit.retention.enabled=false","uten.reporting.materialized-view-refresh.enabled=false",
        "uten.production.readiness-reconcile.enabled=false","uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true","uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only","uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc
class ProductionOverLimitNoticeScopeEndToEndTest {
    private static final String PASSWORD="NoticeScope-Only-Test-1!";
    private static final String EVENT="PRODUCTION_OVER_LIMIT_PENDING";
    @DynamicPropertySource static void database(DynamicPropertyRegistry registry){FullChainEndToEndTest.registerDataSource(registry);}
    @Autowired AutowireCapableBeanFactory beans;
    @Autowired JdbcTemplate db;
    @Autowired NoticeService notices;
    @Autowired ChainNoticeService chain;
    @Autowired ProductionDailyReportService reports;
    @Autowired PasswordEncoder passwords;
    @Autowired ObjectMapper json;
    @Autowired MockMvc mvc;
    @AfterEach void logout(){SecurityContextHolder.clearContext();}

    @Test void onlyTheNewEventNeedsARealSourceAndMalformedOrMissingAnchorsFailClosed() {
        assertEquals(Boolean.TRUE,db.queryForObject("""
                SELECT fn_notice_production_over_limit_visible('UNRELATED_EVENT',NULL,NULL,FALSE,FALSE,'not-a-uuid')
                """,Boolean.class));
        assertEquals(Boolean.FALSE,db.queryForObject("""
                SELECT fn_notice_production_over_limit_visible('PRODUCTION_OVER_LIMIT_PENDING',
                    'PRODUCTION_OVER_LIMIT_DISPOSITION',NULL,TRUE,TRUE,'')
                """,Boolean.class));
        assertEquals(Boolean.FALSE,db.queryForObject("""
                SELECT fn_notice_production_over_limit_visible('PRODUCTION_OVER_LIMIT_PENDING',
                    'PRODUCTION_OVER_LIMIT_DISPOSITION',?,TRUE,TRUE,'')
                """,Boolean.class,UUID.randomUUID()));
        assertEquals(Boolean.FALSE,db.queryForObject("""
                SELECT fn_notice_production_over_limit_visible('PRODUCTION_OVER_LIMIT_PENDING',NULL,?,TRUE,TRUE,'')
                """,Boolean.class,UUID.randomUUID()));
    }

    @Test void revokingOnlyDataScopeHidesPreviouslyDeliveredCardsBeforePaginationCountsAndDetail() throws Exception {
        var flow=new ProductionOverLimitDispositionEndToEndTest();beans.autowireBean(flow);
        Object scenario=ReflectionTestUtils.invokeMethod(flow,"draft");
        ReflectionTestUtils.invokeMethod(flow,"approve",scenario);
        UUID report=ReflectionTestUtils.invokeMethod(scenario,"report");
        UUID disposition=db.queryForObject("SELECT id FROM production_over_limit_dispositions WHERE report_id=?",UUID.class,report);
        UUID owner=db.queryForObject("SELECT plan.maker_id FROM production_over_limit_dispositions d JOIN production_plans plan ON plan.id=d.plan_id WHERE d.id=?",UUID.class,disposition);
        AuthUser admin=(AuthUser)SecurityContextHolder.getContext().getAuthentication().getPrincipal();
        UUID employee=UUID.randomUUID(),user=UUID.randomUUID();
        String account="notice-scope-"+user;
        db.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,'通知范围测试计划员','其他',id,CURRENT_DATE,'active','regular' FROM departments WHERE code='SUB_PLAN'
                """,employee,"NS-"+user.toString().substring(0,8));
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status) VALUES(?,?,?,?,false,'active')",
                user,employee,account,passwords.encode(PASSWORD));
        db.update("""
                INSERT INTO user_permission_overrides(user_id,permission_id,effect)
                SELECT ?,id,CASE WHEN code='production_plan:view:all' THEN 'revoke' ELSE 'grant' END
                FROM permissions WHERE code IN('production_plan:approve','notice:read','production_plan:view:all')
                """,user);
        grantScope(user,owner);
        UUID notice=notices.publishForUser(user,"超限范围测试","私有本批数量100及原因","approval","系统",
                "/production/over-limit-dispositions/"+disposition,EVENT,"urgent",disposition).getId();
        UUID control=notices.publishForUser(user,"普通控制通知","其他事件仍按原规则可读","task","系统","/notice",
                "OVER_LIMIT_SCOPE_CONTROL","normal").getId();
        // Exercise the shared TODO list/count predicates too without changing production publication semantics.
        db.update("UPDATE notices SET kind='TODO' WHERE id IN(?,?)",notice,control);

        String token=login(account);
        assertTrue(read("/api/notices/pending-reviews",token).toString().contains(notice.toString()));
        assertEquals(200,status("/api/production/over-limit-dispositions/"+disposition,token));
        assertEquals(1,read("/api/production/over-limit-dispositions/count",token).path("count").asInt());

        db.update("DELETE FROM user_data_scopes WHERE user_id=? AND scope='production_plan'",user);
        assertEquals(404,status("/api/production/over-limit-dispositions/"+disposition,token),
                "data scope is re-read for the already authenticated session");
        assertEquals(404,status("/api/notices/"+notice,token),
                "an existing session must lose the delivered notice with the same live plan scope");
        token=login(account);
        assertTrue(read("/api/auth/me",token).path("permissions").toString().contains("production_plan:approve"));
        assertEquals(0,read("/api/production/over-limit-dispositions/count",token).path("count").asInt());
        assertEquals(404,status("/api/production/over-limit-dispositions/"+disposition,token));
        assertFalse(read("/api/notices/pending-reviews",token).toString().contains(notice.toString()),
                "the delivered card must not retain quantities or reasons after plan scope is revoked");
        assertEquals(404,status("/api/notices/"+notice,token));
        for(String path:new String[]{"/api/notices","/api/notices?includeDeleted=true","/api/notices/arrivals?limit=1",
                "/api/notices/unread-index","/api/notices/todos?limit=1"}) {
            JsonNode response=read(path,token);
            assertFalse(response.toString().contains(notice.toString()),path);
            assertTrue(response.toString().contains(control.toString()),"filter must run before pagination: "+path);
        }
        assertEquals(1,read("/api/notices/unread-index",token).path("unreadCount").asInt());
        assertEquals(1,read("/api/notices/todos?limit=1",token).path("count").asInt());

        grantScope(user,owner);
        token=login(account);
        assertEquals(200,status("/api/notices/"+notice,token));
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken(admin,null,admin.getAuthorities()));
        reports.reverse(report);
        chain.deliverOutboxEvent("PRODUCTION_OVER_LIMIT_WITHDRAWN",disposition,json.createObjectNode());
        token=login(account);
        assertFalse(read("/api/notices/pending-reviews",token).toString().contains(notice.toString()));
        assertEquals("WITHDRAWN",read("/api/production/over-limit-dispositions/"+disposition,token).path("status").asText());
    }

    private void grantScope(UUID user,UUID owner){
        db.update("INSERT INTO user_data_scopes(user_id,scope,owner_employee_id) VALUES(?,'production_plan',?)",user,owner);
    }
    private String login(String account) throws Exception {
        MvcResult result=mvc.perform(post("/api/auth/login").contentType(MediaType.APPLICATION_JSON)
                .content(json.writeValueAsBytes(Map.of("loginAccount",account,"password",PASSWORD)))).andReturn();
        assertEquals(200,result.getResponse().getStatus());
        return json.readTree(result.getResponse().getContentAsByteArray()).path("accessToken").asText();
    }
    private JsonNode read(String path,String token) throws Exception {
        MvcResult result=mvc.perform(get(path).header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,result.getResponse().getStatus(),path);
        return json.readTree(result.getResponse().getContentAsByteArray());
    }
    private int status(String path,String token) throws Exception {
        return mvc.perform(get(path).header("Authorization","Bearer "+token)).andReturn().getResponse().getStatus();
    }
}
