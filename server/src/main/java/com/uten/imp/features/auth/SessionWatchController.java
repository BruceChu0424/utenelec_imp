package com.uten.imp.features.auth;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AuthUser;
import org.springframework.http.HttpHeaders;
import org.springframework.security.core.annotation.AuthenticationPrincipal;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.context.request.async.DeferredResult;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpServletRequest;

@RestController
public class SessionWatchController {
    public static final String AUTHENTICATED_WATCH = SessionWatchController.class.getName() + ".authenticated";
    private final SessionWatchService watches;

    public SessionWatchController(SessionWatchService watches) { this.watches = watches; }

    @GetMapping("/api/auth/session/watch")
    public DeferredResult<SessionWatchService.Response> watch(
            @AuthenticationPrincipal AuthUser user, HttpServletRequest request, HttpServletResponse response) {
        if (user == null || user.isVisitor()) throw new ApiException(ErrorCode.UNAUTHORIZED);
        request.setAttribute(AUTHENTICATED_WATCH, Boolean.TRUE);
        response.setHeader(HttpHeaders.CACHE_CONTROL, "no-store");
        return watches.watch(user.getSessionId(),
                user.getImpersonatedBy() == null ? user.getId() : user.getImpersonatedBy());
    }
}
