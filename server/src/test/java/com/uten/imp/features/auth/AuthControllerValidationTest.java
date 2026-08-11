package com.uten.imp.features.auth;

import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.Optional;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class AuthControllerValidationTest {

    @Test
    void logoutRejectsOversizedRefreshTokenBeforeTokenService() throws Exception {
        TokenIssuer tokenIssuer = mock(TokenIssuer.class);
        AuthController controller = controller(
                tokenIssuer,
                mock(SecurityContextCurrentUser.class));
        MockMvc mvc = MockMvcBuilders.standaloneSetup(controller)
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();

        mvc.perform(post("/api/auth/logout")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"refreshToken\":\"" + "x".repeat(513) + "\"}"))
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.code").value(ErrorCode.VALIDATION_FAILED.name()));

        verifyNoInteractions(tokenIssuer);
    }

    @Test
    void logoutStillAcceptsAnEmptyBody() throws Exception {
        TokenIssuer tokenIssuer = mock(TokenIssuer.class);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.get()).thenReturn(Optional.empty());
        MockMvc mvc = MockMvcBuilders.standaloneSetup(controller(tokenIssuer, currentUser))
                .setControllerAdvice(new GlobalExceptionHandler())
                .build();

        mvc.perform(post("/api/auth/logout"))
                .andExpect(status().isOk());

        verify(tokenIssuer).logout(null);
    }

    private static AuthController controller(
            TokenIssuer tokenIssuer,
            SecurityContextCurrentUser currentUser) {
        return new AuthController(
                mock(LoginService.class),
                mock(PasswordService.class),
                tokenIssuer,
                currentUser);
    }
}
