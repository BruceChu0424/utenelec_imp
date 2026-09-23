package com.uten.imp.features.auth;

import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.auth.dto.TokenResponse;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.mockito.ArgumentMatchers.any;
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

    /** ADR-108: 会话快照算不出来时 /me 仍返回资料(session 为空), 不让恢复会话失败。 */
    @Test
    void meStillReturnsProfileWhenSessionSnapshotFails() throws Exception {
        TokenIssuer tokenIssuer = mock(TokenIssuer.class);
        TokenResponse.UserProfile profile = mock(TokenResponse.UserProfile.class);
        when(tokenIssuer.me(any())).thenReturn(profile);
        SessionSnapshotService snapshots = mock(SessionSnapshotService.class);
        when(snapshots.current()).thenThrow(new IllegalStateException("组织树数据异常"));
        AuthController controller = new AuthController(
                mock(LoginService.class), mock(PasswordService.class), tokenIssuer,
                mock(SecurityContextCurrentUser.class), snapshots);

        AuthController.MeResponse response = controller.me();

        assertThat(response.profile()).isSameAs(profile);
        assertThat(response.session()).isNull();
    }

    @Test
    void meCarriesSessionSnapshotWhenAvailable() throws Exception {
        TokenIssuer tokenIssuer = mock(TokenIssuer.class);
        SessionSnapshotService snapshots = mock(SessionSnapshotService.class);
        var snapshot = new SessionSnapshotService.SessionSnapshot(List.of("sales.orders"), Map.of(), Map.of());
        when(snapshots.current()).thenReturn(snapshot);
        AuthController controller = new AuthController(
                mock(LoginService.class), mock(PasswordService.class), tokenIssuer,
                mock(SecurityContextCurrentUser.class), snapshots);

        assertThat(controller.me().session()).isSameAs(snapshot);
    }

    private static AuthController controller(
            TokenIssuer tokenIssuer,
            SecurityContextCurrentUser currentUser) {
        return new AuthController(
                mock(LoginService.class),
                mock(PasswordService.class),
                tokenIssuer,
                currentUser,
                mock(SessionSnapshotService.class));
    }
}
