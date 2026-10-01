package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.docnumber.DocNumberPrefix;
import com.uten.imp.common.docnumber.DocNumberService;
import org.hibernate.resource.jdbc.spi.StatementInspector;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfEnvironmentVariable;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.config.AutowireCapableBeanFactory;
import org.springframework.boot.autoconfigure.orm.jpa.HibernatePropertiesCustomizer;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.autoconfigure.web.servlet.MockMvcPrint;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Import;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.springframework.test.web.servlet.MockMvc;
import org.testcontainers.containers.PostgreSQLContainer;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.authentication;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

@EnabledIfEnvironmentVariable(named="UTEN_RUN_DB_TESTS", matches="(?i)true")
@SpringBootTest(webEnvironment=SpringBootTest.WebEnvironment.MOCK, properties={
        "spring.profiles.active=dev", "uten.audit.retention.enabled=false",
        "uten.reporting.materialized-view-refresh.enabled=false", "uten.production.readiness-reconcile.enabled=false",
        "uten.inventory.value-work-initial-delay-ms=3600000", "uten.workshop-material.auto-close.enabled=false",
        "uten.policy-intelligence.enabled=false", "uten.features.goods-owner-scope-enabled=false",
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only",
        "uten.jwt.secret=full-chain-harness-jwt-secret-0123456789-test-only",
        "uten.crypto.pgp-master-key=full-chain-harness-pgp-master-key-test-only-0123456789",
        "uten.crypto.hmac-key=full-chain-harness-hmac-key-test-only",
        "uten.bootstrap.admin-login=full-chain-bootstrap-admin-test",
        "uten.bootstrap.admin-password=HarnessAdminPass-1!"})
@AutoConfigureMockMvc(print=MockMvcPrint.NONE)
@Import(FinanceDepartmentReferencePostgresTest.ProbeConfiguration.class)
class FinanceDepartmentReferencePostgresTest {
    private static final PostgreSQLContainer<?> POSTGRES=new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("uten_finance_department").withUsername("uten").withPassword("uten");
    private static final String PICKER="/api/org/departments/finance-allocation-picker-tree";
    private static final ThreadLocal<List<String>> SQL=new ThreadLocal<>();
    @TestConfiguration static class ProbeConfiguration {
        @Bean HibernatePropertiesCustomizer financeReferenceSqlProbe() {
            return properties -> properties.put("hibernate.session_factory.statement_inspector", (StatementInspector) sql -> {
                var capture=SQL.get(); if(capture!=null) capture.add(sql); return sql;
            });
        }
    }
    @DynamicPropertySource static void database(DynamicPropertyRegistry properties) {
        POSTGRES.start(); properties.add("spring.datasource.url",POSTGRES::getJdbcUrl);
        properties.add("spring.datasource.username",POSTGRES::getUsername);
        properties.add("spring.datasource.password",POSTGRES::getPassword);
    }
    @Autowired MockMvc http;
    @Autowired ObjectMapper json;
    @Autowired JdbcTemplate db;
    @Autowired DocNumberService numbers;
    @Autowired AutowireCapableBeanFactory beans;
    private FullChainEndToEndTest fixture;
    @BeforeEach void prepare(){fixture=new FullChainEndToEndTest();beans.autowireBean(fixture);}
    @AfterEach void cleanup(){SQL.remove();SecurityContextHolder.clearContext();}

    @Test void eachAllocationWritePermissionAllowsOnlyTheMinimalPickerAndDoesNotGrantHrAccess() throws Exception {
        for(String permission:List.of("finance_expense:create","finance_expense:edit","finance_other_income:create","finance_other_income:edit")) {
            Authentication actor=auth(user(permission));
            JsonNode tree=read(PICKER,actor,200);assertTrue(tree.isArray());assertFalse(tree.isEmpty());
            assertMinimalTree(tree);
            read("/api/org/departments/tree",actor,403);
            read("/api/org/departments/employee-picker-tree",actor,403);
        }
    }
    @Test void readOnlyFinanceAndUnrelatedWritesDoNotAuthorizeTheReferenceDirectory() throws Exception {
        for(String permission:List.of("finance_expense:view","finance_other_income:view","finance_receipt:create","department:view"))
            read(PICKER,auth(user(permission)),403);
    }
    @Test void expenseDetailReadsOnlyItsReferencesInOneQueryIncludingHistoricalDeletedDepartment() throws Exception {
        verifyDocument("expenses","finance_expense:view",true);
    }
    @Test void otherIncomeDetailReadsOnlyItsReferencesInOneQueryIncludingHistoricalDeletedDepartment() throws Exception {
        verifyDocument("incomes","finance_other_income:view",false);
    }
    @Test void unauthorizedObjectCannotTriggerAReferenceLabelLookup() throws Exception {
        for (boolean expense : List.of(true, false)) {
            String permission=expense?"finance_expense:view":"finance_other_income:view";
            UUID owner=user(permission), other=user(permission);
            UUID department=department("私有单据部门");UUID report=report(expense,employee(owner),department,department);
            Authentication actor=auth(other);SQL.set(new ArrayList<>());
            read("/api/finance/"+(expense?"expenses":"incomes")+"/"+report,actor,404);
            assertEquals(0,labelQueries());
            SQL.remove();
        }
    }
    private void verifyDocument(String path,String permission,boolean expense)throws Exception {
        UUID owner=user(permission);UUID active=department("当前分摊部门"), historical=department("旧部门保留名称");
        UUID report=report(expense,employee(owner),active,historical);
        db.update("UPDATE departments SET is_deleted=TRUE WHERE id=?",historical);
        Authentication actor=auth(owner);SQL.set(new ArrayList<>());
        JsonNode detail=read("/api/finance/"+path+"/"+report,actor,200);
        assertEquals(1,labelQueries(),"40 allocation rows must resolve their two UUIDs in one bounded query");
        String labelQuery=SQL.get().stream().map(s->s.replaceAll("\\s+"," ").toLowerCase())
                .filter(s->s.contains("from departments where id in")).findFirst().orElseThrow();
        assertEquals(2,labelQuery.chars().filter(c->c=='?').count(),"Only the two persisted references are queried");
        assertEquals(40,detail.path("items").size());
        for(JsonNode item:detail.path("items")) {
            if(!item.hasNonNull("departmentId")){assertFalse(item.hasNonNull("departmentName"));continue;}
            String expected=item.path("departmentId").asText().equals(active.toString())?"当前分摊部门":"旧部门保留名称";
            assertEquals(expected,item.path("departmentName").asText());
            assertFalse(item.has("managerName"));assertFalse(item.has("headcount"));
        }
        SQL.remove();
        JsonNode choices=read(PICKER,auth(user("finance_expense:create")),200);
        assertTrue(choices.toString().contains(active.toString()));
        assertFalse(choices.toString().contains(historical.toString()));
        assertEquals(40,db.queryForObject("SELECT count(*) FROM "+(expense?"finance_expense_items WHERE expense_id=?":"finance_other_income_items WHERE income_id=?"),Integer.class,report));
    }
    private long labelQueries(){return SQL.get().stream().map(s->s.replaceAll("\\s+"," ").toLowerCase())
            .filter(s->s.contains("from departments where id in")).count();}
    private void assertMinimalTree(JsonNode nodes){for(JsonNode node:nodes){Set<String> fields=new HashSet<>();node.fieldNames().forEachRemaining(fields::add);
        assertTrue(Set.of("id","code","name","level","parentId","children").containsAll(fields));
        assertTrue(fields.containsAll(Set.of("id","code","name","level","children")));assertMinimalTree(node.path("children"));}}
    private UUID department(String name){UUID id=UUID.randomUUID();db.update("INSERT INTO departments(id,code,name,level) VALUES(?,?,?,'一级部门')",id,"FINREF-"+id,name);return id;}
    private UUID user(String permission){UUID id=UUID.randomUUID(), employee=UUID.randomUUID(), department=department("独立财务引用权限");
        db.update("INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type) VALUES(?,?,?,'其他',?,CURRENT_DATE,'active','regular')",employee,"FINREF-E-"+id,"财务引用测试",department);
        db.update("INSERT INTO users(id,employee_id,login_account,password_hash,status,must_change_password) VALUES(?,?,?,'test-only','active',FALSE)",id,employee,"finref-"+id);
        assertEquals(1,db.update("INSERT INTO user_permission_overrides(user_id,permission_id,effect) SELECT ?,id,'grant' FROM permissions WHERE code=?",id,permission));return id;}
    private UUID employee(UUID user){return db.queryForObject("SELECT employee_id FROM users WHERE id=?",UUID.class,user);}
    private UUID report(boolean expense,UUID maker,UUID first,UUID second){UUID id=UUID.randomUUID();String bill=numbers.nextNumber(expense?DocNumberPrefix.FIN_EXPENSE:DocNumberPrefix.FIN_OTHER_INCOME);
        String headers=expense?"finance_expenses":"finance_other_incomes",items=expense?"finance_expense_items":"finance_other_income_items",parent=expense?"expense_id":"income_id";
        db.update("INSERT INTO "+headers+"(id,bill_no,bill_date,maker_id,status) VALUES(?,?,CURRENT_DATE,?,0)",id,bill,maker);
        for(int row=0;row<40;row++) db.update("INSERT INTO "+items+"(id,"+parent+",bill_no,bill_date,line_no,department_id) VALUES(?,?,?,CURRENT_DATE,?,?)",UUID.randomUUID(),id,bill,row+1,row==0?null:row%2==0?first:second);
        return id;
    }
    private Authentication auth(UUID user){fixture.loginAs(user);Authentication actor=SecurityContextHolder.getContext().getAuthentication();SecurityContextHolder.clearContext();return actor;}
    private JsonNode read(String path,Authentication actor,int status)throws Exception {var response=http.perform(get(path).with(authentication(actor))).andReturn().getResponse();
        assertEquals(status,response.getStatus(),response.getContentAsString());return json.readTree(response.getContentAsByteArray());}
}
