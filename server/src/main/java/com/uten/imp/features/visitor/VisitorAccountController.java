package com.uten.imp.features.visitor;

import com.uten.imp.features.visitor.dto.VisitorAuthDto;
import lombok.RequiredArgsConstructor;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 访客账号接口（authenticated；访客主体）。
 * GET /api/visitor/me 冷启动会话校验：令牌有效且账号在库时返回当前资料，
 * 过期/吊销令牌由 JwtAuthFilter 401，客户端据此结束本地恢复的会话。
 */
@RestController
@RequestMapping("/api/visitor")
@RequiredArgsConstructor
public class VisitorAccountController {

    private final VisitorAuthService authService;

    @GetMapping("/me")
    public VisitorAuthDto.MeResponse me() {
        return authService.me();
    }
}
