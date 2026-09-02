package com.uten.imp.features.reviews;

import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.Map;

/**
 * 我的待审收件台（V459）。页面守卫码 review_inbox:view；section 内容按各域
 * 「部门（主/兼职）× 职责权限码」资格过滤——本码只控页面可达，不代表持有
 * 各域处理资格。
 */
@RestController
@RequestMapping("/api/reviews/inbox")
public class ReviewInboxController {

    private final ReviewInboxService service;

    public ReviewInboxController(ReviewInboxService service) {
        this.service = service;
    }

    @GetMapping("/summary")
    @PreAuthorize("hasAuthority('review_inbox:view')")
    public Map<String, Object> summary() {
        return Map.of("sections", service.summary());
    }
}
