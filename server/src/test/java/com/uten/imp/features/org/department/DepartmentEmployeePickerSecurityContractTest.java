package com.uten.imp.features.org.department;

import com.uten.imp.application.port.AttachmentAccessPort;
import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.admin.UserAccountAdminService;
import com.uten.imp.features.org.department.dto.DepartmentPickerNode;
import com.uten.imp.features.org.employee.EmployeeCommandService;
import com.uten.imp.features.org.employee.EmployeeController;
import com.uten.imp.features.org.employee.EmployeeOnboardingService;
import com.uten.imp.features.org.employee.EmployeeQueryService;
import com.uten.imp.responsibility.DataHandoverService;
import com.uten.imp.security.AuthUser;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.web.context.support.AnnotationConfigWebApplicationContext;
import com.uten.imp.support.MockControllerSecurityContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.authentication.AnonymousAuthenticationToken;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.config.annotation.method.configuration.EnableMethodSecurity;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.test.util.AopTestUtils;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.lang.reflect.RecordComponent;
import java.util.Arrays;
import java.util.List;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/** Real Spring method-security proxies enforce the minimal tree's business boundary. */
class DepartmentEmployeePickerSecurityContractTest {
    private static final String PICKER = "/api/org/departments/employee-picker-tree";

    @Configuration
    @EnableMethodSecurity
    static class Config {
        @Bean DepartmentService departments() { return mock(DepartmentService.class); }
        @Bean EmployeeQueryService employees() { return mock(EmployeeQueryService.class); }
        @Bean AuditDetailViewRecorder audit() { return mock(AuditDetailViewRecorder.class); }
        @Bean DepartmentController departmentController(DepartmentService service, AuditDetailViewRecorder audit) {
            return new DepartmentController(service, mock(WorkforceOverviewService.class), audit);
        }
        @Bean EmployeeController employeeController(EmployeeQueryService queries, AuditDetailViewRecorder audit) {
            return new EmployeeController(queries, mock(EmployeeOnboardingService.class),
                    mock(EmployeeCommandService.class), mock(UserAccountAdminService.class),
                    mock(DataHandoverService.class), audit, mock(AttachmentAccessPort.class));
        }
    }

    private AnnotationConfigWebApplicationContext context;
    private MockMvc http;
    private DepartmentService departments;
    private EmployeeQueryService employees;
    private final UUID companyId = UUID.randomUUID();
    private final UUID departmentId = UUID.randomUUID();

    @BeforeEach
    void setUp() {
        context = MockControllerSecurityContext.open(Config.class);
        departments = AopTestUtils.getUltimateTargetObject(context.getBean(DepartmentService.class));
        employees = AopTestUtils.getUltimateTargetObject(context.getBean(EmployeeQueryService.class));
        when(departments.employeePickerTree()).thenReturn(List.of(new DepartmentPickerNode(
                companyId, "UTEN", "公司", "公司", null,
                List.of(new DepartmentPickerNode(departmentId, "DEPT_SALES", "综合营销部",
                        "一级部门", companyId, List.of())))));
        http = MockMvcBuilders.standaloneSetup(context.getBean(DepartmentController.class),
                        context.getBean(EmployeeController.class))
                .setControllerAdvice(new GlobalExceptionHandler()).build();
    }

    @AfterEach
    void cleanUp() {
        SecurityContextHolder.clearContext();
        context.close();
    }

    @ParameterizedTest
    @ValueSource(strings = {"employee:view", "account:support", "notice:publish", "client:assign",
            "warehouse:edit", "employee:handover", "employee:offboard", "audit_log:view"})
    void eachExistingInternalPickerAuthorityCanReadOnlyOrganizationReferences(String permission) throws Exception {
        login(staff(Set.of(permission), false, false));

        http.perform(get(PICKER))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].id").value(companyId.toString()))
                .andExpect(jsonPath("$[0].children[0].id").value(departmentId.toString()))
                .andExpect(jsonPath("$[0].children[0].parentId").value(companyId.toString()))
                .andExpect(jsonPath("$[0].children[0].managerId").doesNotExist())
                .andExpect(jsonPath("$[0].children[0].managerName").doesNotExist())
                .andExpect(jsonPath("$[0].children[0].headcount").doesNotExist())
                .andExpect(jsonPath("$[0].children[0].staff").doesNotExist());
        verify(departments).employeePickerTree();
        verifyNoInteractions(employees);
    }

    @ParameterizedTest
    @ValueSource(strings = {"account:support", "client:assign", "warehouse:edit", "employee:handover",
            "employee:offboard", "audit_log:view"})
    void businessPickerPermissionsDoNotOpenDepartmentManagementOrHrRoster(String permission) throws Exception {
        login(staff(Set.of(permission), false, false));

        http.perform(get("/api/org/departments/tree")).andExpect(status().isForbidden());
        http.perform(get("/api/org/departments/" + departmentId)).andExpect(status().isForbidden());
        http.perform(get("/api/org/employees")).andExpect(status().isForbidden());
        verifyNoInteractions(departments, employees);
    }

    @Test
    void noticePublisherKeepsExistingDepartmentTreeAccessWithoutObtainingHrRoster() throws Exception {
        login(staff(Set.of("notice:publish"), false, false));
        when(departments.tree()).thenReturn(List.of());

        http.perform(get("/api/org/departments/tree")).andExpect(status().isOk());
        http.perform(get("/api/org/employees")).andExpect(status().isForbidden());
        verify(departments).tree();
        verifyNoInteractions(employees);
    }
    @ParameterizedTest
    @ValueSource(strings={"employee:create","employee:edit"})
    void employeeEditorsCanChooseDepartmentsWithViewOnlyAndCannotEditTheOrganization(String action) throws Exception {
        login(staff(Set.of(action,"employee:view","department:view"),false,false));
        when(departments.tree()).thenReturn(List.of());
        http.perform(get("/api/org/departments/tree")).andExpect(status().isOk());
        http.perform(put("/api/org/departments/"+departmentId).contentType("application/json").content("{\"name\":\"unauthorized rename\"}"))
                .andExpect(status().isForbidden());
        verify(departments).tree();
        org.mockito.Mockito.verify(departments,org.mockito.Mockito.never()).update(org.mockito.ArgumentMatchers.any(),org.mockito.ArgumentMatchers.any());
    }

    @Test
    void authorizationManagementRequiresSuperAdminAndDoesNotGrantRosterAccess() throws Exception {
        login(staff(Set.of("authorization:manage"), false, false));
        http.perform(get(PICKER)).andExpect(status().isForbidden());
        verifyNoInteractions(departments);

        login(staff(Set.of("authorization:manage"), true, false));
        http.perform(get(PICKER)).andExpect(status().isOk());
        http.perform(get("/api/org/employees")).andExpect(status().isForbidden());
        verify(departments).employeePickerTree();
        verifyNoInteractions(employees);
    }

    @ParameterizedTest
    @ValueSource(strings = {"employee:view", "account:support", "notice:publish", "client:assign",
            "warehouse:edit", "employee:handover", "employee:offboard", "audit_log:view", "authorization:manage"})
    void visitorCannotReadCompanyHierarchyEvenWithAnInternalAuthority(String permission) throws Exception {
        login(AuthUser.visitor(UUID.randomUUID(), "visitor", "V0001", Set.of(permission)));

        http.perform(get(PICKER)).andExpect(status().isForbidden());
        verifyNoInteractions(departments, employees);
    }

    @ParameterizedTest
    @ValueSource(strings = {"department:view", "warehouse:view", "client:view", "notice:read",
            "finance_expense:create", "finance_expense:edit", "finance_other_income:create",
            "finance_other_income:edit", "production_plan:edit"})
    void unrelatedViewOrWriteAuthorityCannotReadEmployeePickerTree(String permission) throws Exception {
        login(staff(Set.of(permission), false, false));

        http.perform(get(PICKER)).andExpect(status().isForbidden());
        verifyNoInteractions(departments, employees);
    }

    @Test
    void anonymousOrPasswordChangeOnlySessionsCannotReadCompanyHierarchy() throws Exception {
        SecurityContextHolder.getContext().setAuthentication(new AnonymousAuthenticationToken(
                "anonymous", "anonymousUser", List.of(new SimpleGrantedAuthority("ROLE_ANONYMOUS"))));
        http.perform(get(PICKER)).andExpect(status().isForbidden());

        login(staff(Set.of("employee:view", "account:support", "authorization:manage"), true, true));
        http.perform(get(PICKER)).andExpect(status().isForbidden());
        verifyNoInteractions(departments, employees);
    }

    @Test
    void superAdminFlagWithoutAnyPickerAuthorityDoesNotGrantDirectoryAccess() throws Exception {
        login(staff(Set.of(), true, false));

        http.perform(get(PICKER)).andExpect(status().isForbidden());
        verifyNoInteractions(departments, employees);
    }

    @Test
    void pickerTreeDtoCannotExposeEmployeeOrDepartmentManagementFields() {
        assertThat(Arrays.stream(DepartmentPickerNode.class.getRecordComponents())
                .map(RecordComponent::getName))
                .containsExactly("id", "code", "name", "level", "parentId", "children")
                .doesNotContain("managerId", "managerName", "headcount", "staff");
    }

    private AuthUser staff(Set<String> permissions, boolean superAdmin, boolean mustChangePassword) {
        return new AuthUser(UUID.randomUUID(), UUID.randomUUID(), "staff", permissions,
                mustChangePassword, true, superAdmin);
    }

    private void login(AuthUser user) {
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken(user, "unused", user.getAuthorities()));
    }
}
