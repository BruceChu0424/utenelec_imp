package com.uten.imp.businesschain;

import org.junit.jupiter.api.Test;
import java.util.Map;
import java.util.UUID;
import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;

/** Ordinary HR permissions provide a read-only inventory; destructive merges remain owner maintenance. */
class EmployeeDuplicateArchiveFlowPostgresTest extends AuthSessionPostgresTestSupport {
    @org.springframework.beans.factory.annotation.Autowired com.uten.imp.security.TxSessionVars identityCrypto;
    @org.springframework.beans.factory.annotation.Autowired org.springframework.transaction.PlatformTransactionManager transactions;
    @org.springframework.beans.factory.annotation.Autowired
    @org.springframework.beans.factory.annotation.Qualifier("requestMappingHandlerMapping")
    org.springframework.web.servlet.mvc.method.annotation.RequestMappingHandlerMapping routes;

    @Test void evenSuperAdminCannotInvokeAnOrdinaryDuplicateArchiveWriteRoute() throws Exception {
        String admin=adminToken();Employee retained=newEmployee(admin,"DEPT_ENG");UUID source=duplicate(retained);
        String employeeBefore=jdbc.queryForObject("SELECT to_jsonb(e)::text FROM employees e WHERE id=?",String.class,source);
        String accountsBefore=jdbc.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(u) ORDER BY id),'[]'::jsonb)::text FROM users u",String.class);
        long aliases=jdbc.queryForObject("SELECT count(*) FROM employee_identity_aliases",Long.class);
        assertTrue(routes.getHandlerMethods().keySet().stream().noneMatch(mapping ->
            mapping.getPatternValues().stream().anyMatch(path -> path.contains("duplicate-archive"))
            && mapping.getMethodsCondition().getMethods().contains(org.springframework.web.bind.annotation.RequestMethod.POST)));
        var rejected=mvc.perform(json(post(path(source)),request(retained),admin)).andReturn();
        assertEquals(404,rejected.getResponse().getStatus(),body(rejected));
        assertEquals(employeeBefore,jdbc.queryForObject("SELECT to_jsonb(e)::text FROM employees e WHERE id=?",String.class,source));
        assertEquals(accountsBefore,jdbc.queryForObject("SELECT COALESCE(jsonb_agg(to_jsonb(u) ORDER BY id),'[]'::jsonb)::text FROM users u",String.class));
        assertEquals(aliases,jdbc.queryForObject("SELECT count(*) FROM employee_identity_aliases",Long.class));
    }

    @Test void authorizedPreviewReportsResponsibilityWithoutChangingOwnershipOrEmployees() throws Exception {
        String admin=adminToken();Employee retained=newEmployee(admin,"DEPT_ENG");UUID source=duplicate(retained);
        UUID supplier=UUID.randomUUID();
        jdbc.update("INSERT INTO suppliers(id,code,name,status,code_sequence,owner_employee_id) VALUES(?,?,?,'使用',(SELECT COALESCE(MAX(code_sequence),0)+1 FROM suppliers),?)",supplier,"DUP-"+supplier,"核验责任测试",source);
        String employeeBefore=jdbc.queryForObject("SELECT to_jsonb(e)::text FROM employees e WHERE id=?",String.class,source);
        var checked=mvc.perform(get(path(source)+"/preview").param("retainedCode",code(retained)).header("Authorization","Bearer "+admin)).andReturn();
        assertEquals(200,checked.getResponse().getStatus(),body(checked));
        assertFalse(json(checked).path("blockers").isEmpty(),body(checked));
        assertEquals(employeeBefore,jdbc.queryForObject("SELECT to_jsonb(e)::text FROM employees e WHERE id=?",String.class,source));
        assertEquals(source,jdbc.queryForObject("SELECT owner_employee_id FROM suppliers WHERE id=?",UUID.class,supplier));
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM employee_identity_aliases WHERE alias_employee_id=?",Integer.class,source));
    }

    @Test void currentDatabaseRefusesRecreatingANullHashDuplicateWithoutAnyAccountSideEffect() throws Exception {
        String admin=adminToken();Employee retained=newEmployee(admin,"DEPT_ENG");UUID source=duplicate(retained);
        String phoneCipher=new org.springframework.transaction.support.TransactionTemplate(transactions)
                .execute(status->identityCrypto.encrypt("13690009997"));
        String employeeBefore=jdbc.queryForObject("SELECT to_jsonb(e)::text FROM employees e WHERE id=?",String.class,source);
        var rejected=assertThrows(org.springframework.dao.DataIntegrityViolationException.class,()->jdbc.update("""
            INSERT INTO employee_sensitive(employee_id,id_card_enc,id_card_check,phone_enc)
            SELECT ?,id_card_enc,id_card_check,? FROM employee_sensitive WHERE employee_id=?
            """,source,phoneCipher,UUID.fromString(retained.employeeId())));
        assertEquals("23514",((java.sql.SQLException)rejected.getMostSpecificCause()).getSQLState());
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM users WHERE employee_id=?",Integer.class,source));
        assertEquals(0,jdbc.queryForObject("SELECT count(*) FROM employee_sensitive WHERE employee_id=?",Integer.class,source));
        assertEquals(employeeBefore,jdbc.queryForObject("SELECT to_jsonb(e)::text FROM employees e WHERE id=?",String.class,source));
    }
    @Test void currentFingerprintCannotBeClearedAndOnboardingCannotBypassTheExistingIdentity() throws Exception {
        String admin=adminToken();Employee existing=newEmployee(admin,"DEPT_ENG");UUID id=UUID.fromString(existing.employeeId());
        String cipher=jdbc.queryForObject("SELECT id_card_enc FROM employee_sensitive WHERE employee_id=?",String.class,id);
        String document=new org.springframework.transaction.support.TransactionTemplate(transactions)
                .execute(status->identityCrypto.tryDecrypt(cipher).orElseThrow());
        String beforeSensitive=jdbc.queryForObject("SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",String.class,id);
        var rejected=assertThrows(org.springframework.dao.DataIntegrityViolationException.class,()->
            jdbc.update("UPDATE employee_sensitive SET id_card_hash=NULL WHERE employee_id=?",id));
        assertEquals("23514",((java.sql.SQLException)rejected.getMostSpecificCause()).getSQLState());
        UUID department=jdbc.queryForObject("SELECT department_id FROM employees WHERE id=?",UUID.class,id);
        var request=Map.of("profile",Map.of("fullName","另一个显示姓名","idType","身份证","idNumber",document,"phone","13690009998"),
                "employment",Map.of("departmentId",department,"hireDate",java.time.LocalDate.now().minusDays(1).toString(),"confirmedAt",java.time.LocalDate.now().minusDays(1).toString(),"employmentType","regular","status","active"),
                "account",Map.of("openAccount",false));
        long before=jdbc.queryForObject("SELECT count(*) FROM employees",Long.class);
        var created=mvc.perform(json(post("/api/org/employees"),request,adminToken())).andReturn();
        assertEquals(409,created.getResponse().getStatus(),body(created));
        assertEquals(before,jdbc.queryForObject("SELECT count(*) FROM employees",Long.class));
        assertEquals(beforeSensitive,jdbc.queryForObject("SELECT to_jsonb(s)::text FROM employee_sensitive s WHERE employee_id=?",String.class,id));
    }
    private String path(UUID source){return "/api/org/employees/"+source+"/duplicate-archive";}
    private String code(Employee employee){return jdbc.queryForObject("SELECT code FROM employees WHERE id=?",String.class,UUID.fromString(employee.employeeId()));}
    private Map<String,Object> request(Employee retained){return Map.of("retainedEmployeeId",retained.employeeId(),"sourceVersion",0,"retainedVersion",0,"reason","已核对原始证件与入职记录，属于重复误建","identityVerified",true);}
    private UUID duplicate(Employee retained){
        UUID id=UUID.randomUUID();jdbc.update("""
            INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
            SELECT ?,?,'复核来源-'||?::text,'其他',department_id,hire_date,status,employment_type FROM employees WHERE id=?
            """,id,"DUP"+id.toString().replace("-","").substring(0,12),id.toString(),UUID.fromString(retained.employeeId()));return id;
    }
}
