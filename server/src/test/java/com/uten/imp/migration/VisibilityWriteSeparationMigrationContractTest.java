package com.uten.imp.migration;

import org.junit.jupiter.api.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class VisibilityWriteSeparationMigrationContractTest {

    @Test
    void v398RemovesBroadAssignmentAndGuardsBothReactivationPaths() throws Exception {
        String sql = Files.readString(Path.of(
                "src/main/resources/db/migration/"
                        + "V398__offboarding_audit_and_responsibility_race_guards.sql"));

        assertThat(sql.indexOf("CREATE OR REPLACE FUNCTION fn_audit_redact_row"))
                .isLessThan(sql.indexOf("UPDATE employee_data_handovers handover"));

        assertThat(sql)
                .contains("DELETE FROM department_permissions")
                .contains("DELETE FROM role_permissions")
                .contains("permission.code = 'client:assign'")
                .contains("fn_require_current_data_scope_pair")
                .contains("ARRAY[v_initial_recipient, NEW.owner_employee_id]")
                .contains("ORDER BY employee.id")
                .contains("BEFORE INSERT OR UPDATE OF user_id, owner_employee_id, owner_employment_generation")
                .contains("ON user_data_scopes")
                .contains("CONSTRAINT='user_data_scopes_current_pair'")
                .contains("fn_require_current_client_visibility_grantee")
                .contains("UPDATE OF grantee_employee_id, active")
                .contains("FOR SHARE OF employee")
                .contains("FOR SHARE OF account")
                .contains("fn_text_array_has_unique_members")
                .contains("fn_guard_employee_handover_scope_mutation")
                .contains("FOR UPDATE OF handover")
                .contains("v_status<>'EXECUTING'")
                .contains("NEW.scope=ANY(v_requested_scopes)")
                .contains("owner_employment_generation")
                .contains("NEW.owner_employment_generation:=v_owner_generation")
                .contains("FOR SHARE OF employee")
                .contains("history.event_type='rehire'")
                .contains("source_employment_generation")
                .contains("target_employment_generation")
                .contains("default_successor_employment_generation")
                .contains("employee_data_handovers_generation_chk")
                .contains("UPDATE OF owner_employee_id, is_deleted ON clients")
                .contains("UPDATE OF owner_employee_id, is_deleted ON goods")
                .contains("UPDATE OF owner_employee_id, is_deleted ON suppliers")
                .contains("UPDATE OF keeper_id, is_deleted ON moulds")
                .contains("UPDATE OF manager_id, is_deleted ON departments")
                .contains("fn_require_current_attachment_upload_user")
                .contains("BEFORE INSERT OR UPDATE OF user_id, status ON attachment_upload_sessions")
                .contains("CONSTRAINT='attachment_upload_sessions_current_user'")
                .contains("fn_reject_employment_history_mutation")
                .contains("BEFORE UPDATE OR DELETE ON employment_history")
                .contains("account.status = 'active'");
    }
}
