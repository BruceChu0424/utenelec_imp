package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.JsonNode;
import org.junit.jupiter.api.Test;
import org.springframework.test.web.servlet.MvcResult;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;

/** Actual audit Criteria/list/count SQL, including a large name match pool and historical actors. */
class AuditActorNameSearchPostgresTest extends AuthSessionPostgresTestSupport {
    @Test void matchingNamesStayInASubqueryWithBoundedBindingsAndHistoricalLiteralPhraseSemantics() throws Exception {
        String suffix=UUID.randomUUID().toString().substring(0,8);
        String name="审计姓名_%\\"+suffix;
        UUID department=jdbc.queryForObject("SELECT id FROM departments WHERE code='DEPT_HR'",UUID.class);
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT md5(?||n)::uuid,'NAME-SEARCH-'||?||'-'||n,?||' '||n,'其他',?,DATE '2020-01-01','active','regular'
                FROM generate_series(1,1201) n
                """,suffix,suffix,name,department);
        jdbc.update("""
                INSERT INTO users(id,employee_id,login_account,password_hash,must_change_password,status)
                SELECT md5('actor-user-'||e.id)::uuid,e.id,'actor-search-'||e.id,'synthetic-test-only',false,'active'
                FROM employees e WHERE e.code LIKE ?
                ""","NAME-SEARCH-"+suffix+"-%");
        UUID employee=jdbc.queryForObject("SELECT id FROM employees WHERE code=?",UUID.class,"NAME-SEARCH-"+suffix+"-1");
        UUID staff=jdbc.queryForObject("SELECT id FROM users WHERE employee_id=?",UUID.class,employee);
        jdbc.update("UPDATE users SET is_deleted=true,status='disabled' WHERE id=?",staff);
        jdbc.update("UPDATE employees SET is_deleted=true,status='resigned' WHERE id=?",employee);
        UUID visitor=UUID.randomUUID();
        String visitorNo="V1"+String.format("%07d",(visitor.getLeastSignificantBits() & 0x7fffffffL)%10000000);
        jdbc.update("""
                INSERT INTO visitor_accounts(id,phone_enc,phone_hash,name,visitor_no,status)
                VALUES (?,encode(pgp_sym_encrypt('13900000001','auth-session-pgp-key-0123456789-test-only'),'base64'),?,?,?,'blocked')
                """,visitor,visitor.toString().replace("-","").repeat(2),name+" 访客",visitorNo);
        String target="name-subquery-"+suffix;
        event(staff,target,"opaque-staff");event(visitor,target,"opaque-visitor");
        String token=adminToken();
        ProductionJdbcMeasurement.Sample measured=ProductionJdbcMeasurement.begin();
        JsonNode result;
        try {result=read(token,name,target,staff);}
        finally {ProductionJdbcMeasurement.end();}
        System.out.println("AUDIT-NAME-SUBQUERY staffPool=1201 maxPreparedParameterIndex="
                +measured.maxPreparedParameterIndex+" logicalStatements="+measured.logicalStatements);
        assertEquals(1,result.path("total").asInt());
        assertEquals(1,result.path("items").size());
        assertTrue(measured.maxPreparedParameterIndex<200,
                "1201 matching actors must not expand a Java ID set into SQL bindings: "+measured.maxPreparedParameterIndex);
        assertEquals(1,read(token,name+" 1",target,staff).path("total").asInt());
        assertEquals(0,read(token,name+" 1",target,visitor).path("total").asInt(),
                "Keep the original whole-phrase name rule; do not AND words across name/visitor-number fields");
        assertEquals(1,read(token,visitorNo,target,visitor).path("total").asInt());
        assertEquals(0,read(token,"审计姓名AX"+suffix,target,staff).path("total").asInt(),"Percent/underscore/backslash remain literal");
    }

    private void event(UUID actor,String target,String account) {
        jdbc.update("""
                INSERT INTO audit_log(actor_id,actor_account,action,target_type,target_id,event_source,result,risk_level,event_category)
                VALUES(?,?,'actor_name_subquery_fixture','users',?,'business','success','low','business')
                """,actor,account,target);
    }

    private JsonNode read(String token,String keyword,String target,UUID actorId) throws Exception {
        var day=com.uten.imp.common.time.BusinessTime.today();
        MvcResult result=mvc.perform(get("/api/admin/audit-logs").param("keyword",keyword)
                .param("actorId",actorId.toString())
                .param("actorScope","user").param("dateFrom",day.minusDays(1).toString()).param("dateTo",day.plusDays(1).toString())
                .param("targetType","users").param("targetId",target).param("activityOnly","false")
                .param("size","1").header("Authorization","Bearer "+token)).andReturn();
        assertEquals(200,result.getResponse().getStatus(),body(result));
        return json(result);
    }
}
