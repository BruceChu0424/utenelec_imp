package com.uten.imp.features.visitor;

import com.uten.imp.features.visitor.dto.VisitorAuthDto;
import jakarta.servlet.http.HttpServletRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 访客鉴权接口（permitAll，见 SecurityConfig）。
 * POST /api/visitor/auth/send-code | login | refresh | logout
 */
@RestController
@RequestMapping("/api/visitor/auth")
@RequiredArgsConstructor
public class VisitorAuthController {

    private final VisitorAuthService authService;

    @PostMapping("/send-code")
    public VisitorAuthDto.SendCodeResponse sendCode(@RequestBody VisitorAuthDto.SendCodeRequest req,
                                                      HttpServletRequest http) {
        return authService.sendCode(req.phone(), http.getRemoteAddr());
    }

    @PostMapping("/login")
    public VisitorAuthDto.VisitorTokenResponse login(@RequestBody VisitorAuthDto.VisitorLoginRequest req,
                                                      HttpServletRequest http) {
        return authService.login(req.phone(), req.code(), http.getHeader("User-Agent"), http.getRemoteAddr());
    }

    @PostMapping("/refresh")
    public VisitorAuthDto.VisitorTokenResponse refresh(@RequestBody VisitorAuthDto.VisitorRefreshRequest req,
                                                         HttpServletRequest http) {
        return authService.refresh(req.refreshToken(), http.getHeader("User-Agent"));
    }

    @PostMapping("/logout")
    public void logout(@RequestBody VisitorAuthDto.VisitorRefreshRequest req) {
        authService.logout(req.refreshToken());
    }
}
