package com.uten.imp.features.workbench.badge;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 工作台徽章汇总接口(ADR-108)。
 *
 * <p>只读、只返回数字; 每个入口是否出现由该入口原计数端点自己的 {@code @PreAuthorize} 判定,
 * 接口本身只要求「已登录的员工」。前端唯一的徽章数据源 badgeSummaryProvider 60s 拉一次。
 */
@RestController
@RequestMapping("/api/workbench")
@RequiredArgsConstructor
public class WorkbenchBadgeController {

    private final WorkbenchBadgeService service;

    @GetMapping("/badges")
    @PreAuthorize("isAuthenticated() and !principal.visitor")
    public WorkbenchBadgeSummary badges() {
        return service.summary();
    }
}
