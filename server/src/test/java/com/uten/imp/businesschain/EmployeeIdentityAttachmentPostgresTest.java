package com.uten.imp.businesschain;

import org.junit.jupiter.api.Test;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.*;

/** Real private DB, HTTP identity resolution and owner authorization; no production files or credentials. */
@org.springframework.test.context.TestPropertySource(properties = {
        "uten.storage.uploads-enabled=true", "uten.storage.malware-scan.provider=test-only"
})
class EmployeeIdentityAttachmentPostgresTest extends AuthSessionPostgresTestSupport {
    @Test
    void canonicalSelfReadsSeparateHistoricalEmployeeAndContractFilesWithoutRewritingOwners() throws Exception {
        String admin=adminToken();Employee canonical=newEmployee(admin,"DEPT_ENG");
        filePermissions(admin,canonical);
        History history=history(UUID.fromString(canonical.employeeId()));
        String before=historyFingerprint(history);
        String self=login(canonical.loginAccount(),EMPLOYEE_PASSWORD).path("accessToken").asText();
        var response=mvc.perform(get("/api/profile/me").header("Authorization","Bearer "+self)).andReturn();
        assertEquals(200,response.getResponse().getStatus(),body(response));
        var profile=json(response);assertEquals(0,profile.path("attachments").size());
        assertEquals(2,profile.path("historicalAttachmentGroups").size());
        Set<String> ids=new java.util.HashSet<>();
        for(var group:profile.path("historicalAttachmentGroups")) {
            assertEquals(history.employee().toString(),group.path("sourceEmployeeId").asText());
            var file=group.path("attachments").get(0);assertTrue(file.path("historyReadOnly").asBoolean());
            assertEquals(group.path("ownerId").asText(),file.path("ownerId").asText());
            ids.add(file.path("id").asText());
        }
        assertEquals(Set.of(history.employeeFile().toString(),history.contractFile().toString()),ids);
        for(UUID file:List.of(history.employeeFile(),history.contractFile())) {
            var detail=mvc.perform(get("/api/attachments/"+file+"/history").header("Authorization","Bearer "+self)).andReturn();
            assertEquals(200,detail.getResponse().getStatus(),body(detail));
            var unavailable=mvc.perform(get("/api/attachments/"+file+"/history/download").header("Authorization","Bearer "+self)).andReturn();
            assertEquals(409,unavailable.getResponse().getStatus(),"no retained bytes are fabricated for synthetic legacy metadata");
        }
        assertEquals(before,historyFingerprint(history));
    }

    @Test
    void publicEmployeeReadSurvivesPrivateFileDenialAndArchivedOwnersRemainUnwritable() throws Exception {
        String admin=adminToken();Employee canonical=newEmployee(admin,"DEPT_ENG"),other=newEmployee(admin,"DEPT_ENG");
        filePermissions(admin,other);History history=history(UUID.fromString(canonical.employeeId()));
        String before=historyFingerprint(history);
        String outsider=login(other.loginAccount(),EMPLOYEE_PASSWORD).path("accessToken").asText();
        var publicDetail=mvc.perform(get("/api/org/employees/"+canonical.employeeId()).header("Authorization","Bearer "+outsider)).andReturn();
        assertEquals(200,publicDetail.getResponse().getStatus(),body(publicDetail));
        assertEquals(0,json(publicDetail).path("attachments").size());
        assertEquals(0,json(publicDetail).path("historicalAttachmentGroups").size());
        assertTrue(json(publicDetail).path("phone").asText().contains("****"));
        assertNotEquals(canonical.loginAccount(),json(publicDetail).path("phone").asText());
        assertTrue(json(publicDetail).path("idNumber").asText().contains("****"));
        assertTrue(json(publicDetail).path("bankAccount").isNull());
        assertTrue(json(publicDetail).path("hujiAddress").isNull());
        var denied=mvc.perform(get("/api/attachments/"+history.employeeFile()+"/history").header("Authorization","Bearer "+outsider)).andReturn();
        assertEquals(404,denied.getResponse().getStatus());
        admin=adminToken();
        for(var owner:List.of(Map.entry("EMPLOYEE",history.employee()),Map.entry("EMPLOYEE_CONTRACT",history.contract()))) {
            var upload=mvc.perform(json(post("/api/attachments/presign"),Map.of("ownerType",owner.getKey(),
                    "ownerId",owner.getValue(),"fileName","new.pdf","contentType","application/pdf","sizeBytes",8),admin)).andReturn();
            assertEquals(404,upload.getResponse().getStatus(),body(upload));
        }
        var category=mvc.perform(json(put("/api/attachments/"+history.employeeFile()+"/category"),Map.of("category","new"),admin)).andReturn();
        assertEquals(404,category.getResponse().getStatus(),body(category));
        assertEquals(before,historyFingerprint(history));
    }

    private void filePermissions(String admin,Employee employee) throws Exception {
        var changed=mvc.perform(json(put("/api/admin/users/"+employee.userId()+"/permission-overrides"),
                Map.of("grants",List.of("employee:view","attachment:view","attachment:download"),
                        "revokes",List.of("employee:pii:view")),admin)
                .header("X-Uten-Step-Up",stepUp(admin,ADMIN_PASSWORD))).andReturn();
        assertEquals(200,changed.getResponse().getStatus(),body(changed));
    }

    private record History(UUID employee,UUID contract,UUID employeeFile,UUID contractFile) {}
    private History history(UUID canonical) {
        UUID alias=UUID.randomUUID(),contract=UUID.randomUUID(),employeeFile=UUID.randomUUID(),contractFile=UUID.randomUUID();
        jdbc.update("""
                INSERT INTO employees(id,code,full_name,id_type,department_id,hire_date,status,employment_type)
                SELECT ?,?,'Synthetic historical file owner','其他',department_id,CURRENT_DATE,'probation','regular'
                FROM employees WHERE id=?
                """,alias,"FILE-IDENTITY-"+alias.toString().substring(0,8),canonical);
        jdbc.update("INSERT INTO employee_contracts(id,employee_id,contract_type,start_date,sign_order) VALUES(?,?,'fixed',CURRENT_DATE,1)",contract,alias);
        file(employeeFile,"EMPLOYEE",alias);file(contractFile,"EMPLOYEE_CONTRACT",contract);
        jdbc.update("UPDATE employees SET is_deleted=true,deleted_at=now(),status='resigned' WHERE id=?",alias);
        var transaction=new TransactionTemplate(new DataSourceTransactionManager(jdbc.getDataSource()));
        transaction.executeWithoutResult(ignored->{
            jdbc.queryForObject("SELECT set_config('app.actor_account','ops:private-identity-file-fixture',true)",String.class);
            jdbc.queryForObject("SELECT set_config('app.employee_identity_merge_evidence','private-history-file-proof',true)",String.class);
            jdbc.update("INSERT INTO employee_identity_aliases(alias_employee_id,canonical_employee_id,reason,evidence_reference) VALUES(?,?,'Verified synthetic identity','private-history-file-proof')",alias,canonical);
        });
        return new History(alias,contract,employeeFile,contractFile);
    }

    private void file(UUID id,String type,UUID owner) {
        jdbc.update("""
                INSERT INTO attachments(id,owner_type,owner_id,storage_key,original_name,content_type,size_bytes,
                        lifecycle_state,storage_provider,stored_size_bytes,storage_encoding)
                VALUES(?,?,?,?,'historical.pdf','application/pdf',8,'LEGACY_UNVERIFIED','local',8,'IDENTITY')
                """,id,type,owner,"private-history-"+id+".pdf");
    }
    private String historyFingerprint(History history) {
        return jdbc.queryForObject("""
                SELECT md5(jsonb_build_object(
                    'employee',(SELECT to_jsonb(e) FROM employees e WHERE id=?),
                    'contract',(SELECT to_jsonb(c) FROM employee_contracts c WHERE id=?),
                    'files',(SELECT jsonb_agg(to_jsonb(a) ORDER BY id) FROM attachments a WHERE id IN (?,?)))::text)
                """,String.class,history.employee(),history.contract(),history.employeeFile(),history.contractFile());
    }
}
