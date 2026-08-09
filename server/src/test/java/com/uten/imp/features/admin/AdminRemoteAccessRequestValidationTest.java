package com.uten.imp.features.admin;

import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.validation.beanvalidation.LocalValidatorFactoryBean;
import org.springframework.test.web.servlet.MockMvc;

import java.util.UUID;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.put;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class AdminRemoteAccessRequestValidationTest {

    private UserAccountAdminService accounts;
    private MockMvc mvc;
    private UUID targetId;

    @BeforeEach
    void setUp() {
        accounts = mock(UserAccountAdminService.class);
        AdminUserController controller = new AdminUserController(
                accounts,
                mock(RoleAdminService.class),
                mock(PermissionOverrideAdminService.class),
                mock(DataScopeAdminService.class));
        LocalValidatorFactoryBean validator = new LocalValidatorFactoryBean();
        validator.afterPropertiesSet();
        mvc = org.springframework.test.web.servlet.setup.MockMvcBuilders
                .standaloneSetup(controller)
                .setControllerAdvice(new GlobalExceptionHandler())
                .setValidator(validator)
                .build();
        targetId = UUID.randomUUID();
    }

    @Test
    void missingRemoteAccessFieldIsValidationFailureAndCannotRevoke() throws Exception {
        mvc.perform(put(path())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value(ErrorCode.VALIDATION_FAILED.name()))
                .andExpect(jsonPath("$.fieldErrors[0].field").value("remoteAccess"));

        verifyNoInteractions(accounts);
    }

    @Test
    void explicitNullRemoteAccessIsValidationFailureAndCannotRevoke() throws Exception {
        mvc.perform(put(path())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"remoteAccess\":null}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value(ErrorCode.VALIDATION_FAILED.name()));

        verifyNoInteractions(accounts);
    }

    @Test
    void absentRequestBodyIsMalformedAndCannotRevoke() throws Exception {
        mvc.perform(put(path()).contentType(MediaType.APPLICATION_JSON))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value(ErrorCode.MALFORMED_REQUEST.name()));

        verifyNoInteractions(accounts);
    }

    @Test
    void explicitFalseRemainsAValidRevocationRequest() throws Exception {
        mvc.perform(put(path())
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"remoteAccess\":false}"))
                .andExpect(status().isOk());

        verify(accounts).setRemoteAccess(targetId, false);
    }

    private String path() {
        return "/api/admin/users/" + targetId + "/remote-access";
    }
}
