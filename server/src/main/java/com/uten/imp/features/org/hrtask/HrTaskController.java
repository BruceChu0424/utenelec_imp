package com.uten.imp.features.org.hrtask;

import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

/**
 * HR 任务中心（行政与人力资源部工作台「任务中心」卡片 + 页面）。
 * 只读动态计算，权限与员工档案查看一致（employee:view）。
 */
@RestController
@RequestMapping("/api/org/hr-tasks")
@RequiredArgsConstructor
public class HrTaskController {

    private final HrTaskService service;

    @GetMapping("/summary")
    @PreAuthorize("hasAuthority('employee:view')")
    public HrTaskSummary summary() {
        return service.summary();
    }

    @GetMapping("/count")
    @PreAuthorize("hasAuthority('employee:view')")
    public Map<String, Long> count() {
        return Map.of("count", service.badgeCount());
    }
}
