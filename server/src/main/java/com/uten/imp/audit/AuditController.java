package com.uten.imp.audit;

import com.uten.imp.common.web.PageResponse;
import lombok.RequiredArgsConstructor;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;

/**
 * 审计日志查看（管理端读侧）。
 * <p>仅超级管理员（持有 authorization:manage，与 {@code AdminPermissionController} /
 * {@code AdminUserController} 一致）可访问——审计含全员操作记录，非管理员不可见。
 * <p>写侧：导出报表 / 登录 / 改密等事件由 {@link AuditService#logExplicit} 落库；
 * 数据变更由 audit_log 触发器写入。
 */
@RestController
@RequestMapping("/api/admin/audit-logs")
@RequiredArgsConstructor
public class AuditController {

    private final AuditQueryService auditQuery;

    /**
     * 分页查询审计日志（按 createdAt DESC）。
     *
     * @param action      动作前缀模糊匹配（如 "export" 命中所有 export_*_report）
     * @param actorAccount 操作人账号子串模糊（不区分大小写）
     * @param dateFrom    起始日期（含，ISO yyyy-MM-dd）
     * @param dateTo      截止日期（含，ISO yyyy-MM-dd）
     */
    @GetMapping
    @PreAuthorize("hasAuthority('authorization:manage') and principal.superAdmin")
    public PageResponse<AuditLogRow> list(
            @RequestParam(required = false) String action,
            @RequestParam(required = false) String actorAccount,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateFrom,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate dateTo,
            @RequestParam(defaultValue = "1") int page,
            @RequestParam(defaultValue = "20") int size) {
        return auditQuery.query(action, actorAccount, dateFrom, dateTo, page, size);
    }
}
