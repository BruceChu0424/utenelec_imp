package com.uten.imp.audit;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.Pageables;
import jakarta.persistence.criteria.Predicate;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.data.domain.Pageable;
import org.springframework.data.domain.Sort;
import org.springframework.data.jpa.domain.Specification;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/**
 * 审计日志查询（管理端读侧）。
 * <p>写侧由 {@link AuditService} / DB 触发器负责；本类只读，给 /api/admin/audit-logs 用。
 * <ul>
 *   <li>action：前缀模糊（如 "export" 匹配 export_purchase_report / export_sales_report ...）。</li>
 *   <li>actorAccount：子串模糊（不区分大小写）。</li>
 *   <li>dateFrom / dateTo：闭区间，按 created_at 过滤；业务日期边界使用 Asia/Shanghai，
 *       数据库存储仍为 TIMESTAMPTZ。</li>
 * </ul>
 * 默认按 created_at DESC（最新在前），单页最多 100 条（由 Pageables 收敛）。
 */
@Service
@RequiredArgsConstructor
public class AuditQueryService {

    private static final List<String> FORCED_MEDIUM_RISK_ACTIONS = List.of(
            "view_audit_log_detail",
            "verify_local_audit_receipt",
            "download_payroll_slip");
    private static final List<String> AUDIT_INVESTIGATION_ACTIONS = List.of(
            "view_audit_log_list",
            "view_audit_log_summary",
            "view_audit_log_detail",
            "verify_local_audit_receipt");
    private static final List<String> DATA_EXPORT_ACTIONS = List.of(
            "download_payroll_slip");
    private static final DateTimeFormatter EXPORT_TIME =
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
    private static final List<ExportColumn> EXPORT_COLUMNS = List.of(
            new ExportColumn("createdAt", "发生时间（北京时间）", ExportColumn.TEXT),
            new ExportColumn("actor", "操作人", ExportColumn.TEXT),
            new ExportColumn("actionLabel", "做了什么", ExportColumn.TEXT),
            new ExportColumn("actionCode", "动作编码", ExportColumn.TEXT),
            new ExportColumn("objectLabel", "操作对象", ExportColumn.TEXT),
            new ExportColumn("targetId", "对象 ID", ExportColumn.TEXT),
            new ExportColumn("outcome", "操作结果", ExportColumn.TEXT),
            new ExportColumn("resultCode", "结果编码", ExportColumn.TEXT),
            new ExportColumn("riskLevel", "风险等级", ExportColumn.TEXT),
            new ExportColumn("riskReason", "风险原因", ExportColumn.TEXT),
            new ExportColumn("eventCategory", "事件类型", ExportColumn.TEXT),
            new ExportColumn("eventSource", "记录来源", ExportColumn.TEXT),
            new ExportColumn("deviceName", "设备名称", ExportColumn.TEXT),
            new ExportColumn("deviceManufacturer", "设备厂商", ExportColumn.TEXT),
            new ExportColumn("deviceModel", "设备型号", ExportColumn.TEXT),
            new ExportColumn("devicePlatform", "设备平台", ExportColumn.TEXT),
            new ExportColumn("deviceOsVersion", "系统版本", ExportColumn.TEXT),
            new ExportColumn("appVersion", "应用版本", ExportColumn.TEXT),
            new ExportColumn("appBuild", "应用构建", ExportColumn.TEXT),
            new ExportColumn("deviceFormFactor", "设备形态", ExportColumn.TEXT),
            new ExportColumn("deviceBrowser", "浏览器", ExportColumn.TEXT),
            new ExportColumn("deviceLocale", "语言区域", ExportColumn.TEXT),
            new ExportColumn("deviceTimeZone", "本机时区", ExportColumn.TEXT),
            new ExportColumn("deviceTimeZoneOffsetMinutes", "时区偏移（分钟）", ExportColumn.TEXT),
            new ExportColumn("deviceIsPhysical", "物理设备状态", ExportColumn.TEXT),
            new ExportColumn("deviceInstallationId", "本机安装标识", ExportColumn.TEXT),
            new ExportColumn("clientEventId", "本地操作 ID", ExportColumn.TEXT),
            new ExportColumn("clientEventAt", "本机发起时间", ExportColumn.TEXT),
            new ExportColumn("deviceCaptureStatus", "设备信息状态", ExportColumn.TEXT),
            new ExportColumn("deviceProfileHash", "设备快照摘要", ExportColumn.TEXT),
            new ExportColumn("ip", "IP 地址", ExportColumn.TEXT),
            new ExportColumn("httpMethod", "HTTP 方法", ExportColumn.TEXT),
            new ExportColumn("httpPath", "HTTP 路径", ExportColumn.TEXT),
            new ExportColumn("statusCode", "HTTP 状态码", ExportColumn.TEXT),
            new ExportColumn("durationMs", "耗时（毫秒）", ExportColumn.TEXT),
            new ExportColumn("requestId", "Request ID", ExportColumn.TEXT),
            new ExportColumn("auditId", "审计日志 ID", ExportColumn.TEXT));

    private final AuditLogRepository repo;
    private final AuditEventInterpreter interpreter;

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('audit_log:view')")
    public PageResponse<AuditLogRow> query(String actionPrefix,
                                           String actorAccount,
                                           String riskLevel,
                                           String eventCategory,
                                           String outcome,
                                           LocalDate dateFrom,
                                           LocalDate dateTo,
                                           int page,
                                           int size) {
        Specification<AuditLog> spec = specification(
                actionPrefix,
                actorAccount,
                riskLevel,
                eventCategory,
                outcome,
                dateFrom,
                dateTo);
        Pageable pageable = Pageables.of(page, size, Sort.by(Sort.Direction.DESC, "createdAt"));
        Page<AuditLog> p = repo.findAll(spec, pageable);
        List<AuditLogRow> items = p.getContent().stream()
                .map(value -> AuditLogRow.of(value, interpreter))
                .toList();
        return new PageResponse<>(items, page, size, p.getTotalElements(), p.getTotalPages());
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('audit_log:view')")
    public AuditSummary summary(String actionPrefix,
                                String actorAccount,
                                String eventCategory,
                                LocalDate dateFrom,
                                LocalDate dateTo) {
        Specification<AuditLog> base = specification(
                actionPrefix, actorAccount, null, eventCategory, null, dateFrom, dateTo);
        long total = repo.count(base);
        long risk = repo.count(base.and(riskSpecification("risky")));
        long critical = repo.count(base.and(riskSpecification("critical")));
        long failed = repo.count(base.and(outcomeSpecification("failure")));
        long dataChanges = repo.count(base.and(categorySpecification("data_change")));

        LocalDate today = BusinessTime.today();
        LocalDate trendStart = today.minusDays(6);
        Map<LocalDate, AuditSummary.DailyPoint> actual = new HashMap<>();
        for (Object[] row : repo.summarizeDaily(
                BusinessTime.startOfDay(trendStart),
                BusinessTime.startOfDay(today.plusDays(1)),
                actionPrefix,
                actorAccount,
                eventCategory)) {
            LocalDate date = row[0] instanceof LocalDate localDate
                    ? localDate
                    : ((java.sql.Date) row[0]).toLocalDate();
            actual.put(date, new AuditSummary.DailyPoint(
                    date,
                    ((Number) row[1]).longValue(),
                    ((Number) row[2]).longValue()));
        }
        List<AuditSummary.DailyPoint> trend = new ArrayList<>();
        for (int offset = 0; offset < 7; offset++) {
            LocalDate date = trendStart.plusDays(offset);
            trend.add(actual.getOrDefault(date, new AuditSummary.DailyPoint(date, 0, 0)));
        }
        return new AuditSummary(total, risk, critical, failed, dataChanges, List.copyOf(trend));
    }

    /**
     * Exports the exact same filtered online result set as the audit page.
     *
     * <p>Raw before/after JSON and user-agent are deliberately excluded from
     * bulk export because they are large and more sensitive. The audit ID and
     * request ID remain available for a focused detail investigation.
     */
    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('audit_log:view')"
            + " and hasAuthority('audit_log:export')")
    public ExportPayload export(String actionPrefix,
                                String actorAccount,
                                String riskLevel,
                                String eventCategory,
                                String outcome,
                                LocalDate dateFrom,
                                LocalDate dateTo,
                                int maxRows) {
        if (maxRows < 1 || maxRows > 100_000) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "导出行数上限配置异常，请先在系统设置中调整为 1 至 100000");
        }
        int safeMaxRows = maxRows;
        Specification<AuditLog> spec = specification(
                actionPrefix,
                actorAccount,
                riskLevel,
                eventCategory,
                outcome,
                dateFrom,
                dateTo);
        long total = repo.count(spec);
        if (total > safeMaxRows) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "当前筛选结果共 " + total + " 条，超过单次导出上限 "
                            + safeMaxRows + " 条，请缩小日期或筛选范围");
        }
        Page<AuditLog> page = repo.findAll(
                spec,
                PageRequest.of(
                        0,
                        safeMaxRows,
                        Sort.by(Sort.Direction.DESC, "createdAt")
                                .and(Sort.by(Sort.Direction.DESC, "id"))));
        List<Map<String, Object>> rows = page.getContent().stream()
                .map(this::toExportRow)
                .toList();
        return new ExportPayload(EXPORT_COLUMNS, rows, rows.size());
    }

    private Map<String, Object> toExportRow(AuditLog value) {
        AuditLogRow row = AuditLogRow.of(value, interpreter);
        Map<String, Object> exported = new LinkedHashMap<>();
        exported.put("createdAt", row.getCreatedAt() == null
                ? ""
                : row.getCreatedAt()
                        .atZoneSameInstant(BusinessTime.ZONE)
                        .format(EXPORT_TIME));
        exported.put("actor", firstNonBlank(row.getActorAccount(), "系统"));
        exported.put("actionLabel", row.getActionLabel());
        exported.put("actionCode", row.getAction());
        exported.put("objectLabel", row.getObjectLabel());
        exported.put("targetId", row.getTargetId());
        exported.put("outcome", failed(row) ? "失败" : "成功");
        exported.put("resultCode", row.getResult());
        exported.put("riskLevel", riskLabel(row.getRiskLevel()));
        exported.put("riskReason", row.getRiskReason());
        exported.put("eventCategory", categoryLabel(row.getEventCategory()));
        exported.put("eventSource", sourceLabel(row.getEventSource()));
        exported.put("deviceName", value.getDeviceName());
        exported.put("deviceManufacturer", value.getDeviceManufacturer());
        exported.put("deviceModel", value.getDeviceModel());
        exported.put("devicePlatform", value.getDevicePlatform());
        exported.put("deviceOsVersion", value.getDeviceOsVersion());
        exported.put("appVersion", value.getAppVersion());
        exported.put("appBuild", value.getAppBuild());
        exported.put("deviceFormFactor", value.getDeviceFormFactor());
        exported.put("deviceBrowser", value.getDeviceBrowser());
        exported.put("deviceLocale", value.getDeviceLocale());
        exported.put("deviceTimeZone", value.getDeviceTimeZone());
        exported.put("deviceTimeZoneOffsetMinutes", value.getDeviceTimeZoneOffsetMinutes());
        exported.put("deviceIsPhysical", value.getDeviceIsPhysical() == null
                ? ""
                : value.getDeviceIsPhysical() ? "客户端报告为真机" : "客户端报告为模拟器");
        exported.put("deviceInstallationId", value.getDeviceInstallationId());
        exported.put("clientEventId", value.getClientEventId());
        exported.put("clientEventAt", value.getClientEventAt() == null
                ? ""
                : value.getClientEventAt()
                        .atZoneSameInstant(BusinessTime.ZONE)
                        .format(EXPORT_TIME));
        exported.put("deviceCaptureStatus", value.getDeviceCaptureStatus());
        exported.put("deviceProfileHash", value.getDeviceProfileHash());
        exported.put("ip", row.getIp());
        exported.put("httpMethod", value.getHttpMethod());
        exported.put("httpPath", value.getHttpPath());
        exported.put("statusCode", row.getStatusCode());
        exported.put("durationMs", row.getDurationMs());
        exported.put("requestId", row.getRequestId());
        exported.put("auditId", row.getId());
        return exported;
    }

    private boolean failed(AuditLogRow row) {
        if (row.getStatusCode() != null && row.getStatusCode() >= 400) {
            return true;
        }
        return row.getResult() != null
                && !"success".equalsIgnoreCase(row.getResult());
    }

    private String riskLabel(String value) {
        return switch (value == null ? "" : value) {
            case "critical" -> "严重";
            case "high" -> "高";
            case "medium" -> "中";
            case "low" -> "低";
            default -> firstNonBlank(value, "未知");
        };
    }

    private String categoryLabel(String value) {
        return switch (value == null ? "" : value) {
            case "security" -> "安全事件";
            case "authorization" -> "权限变更";
            case "authentication" -> "登录认证";
            case "export" -> "数据导出";
            case "data_change" -> "数据变更";
            case "system" -> "系统设置";
            case "business" -> "业务操作";
            default -> firstNonBlank(value, "其他");
        };
    }

    private String sourceLabel(String value) {
        return switch (value == null ? "" : value) {
            case "request" -> "请求覆盖";
            case "database" -> "数据库变更";
            case "security" -> "安全拦截";
            case "business" -> "业务事件";
            default -> firstNonBlank(value, "其他");
        };
    }

    private String firstNonBlank(String value, String fallback) {
        return value == null || value.isBlank() ? fallback : value;
    }

    private Specification<AuditLog> specification(String actionPrefix,
                                                  String actorAccount,
                                                  String riskLevel,
                                                  String eventCategory,
                                                  String outcome,
                                                  LocalDate dateFrom,
                                                  LocalDate dateTo) {
        Specification<AuditLog> base = (root, q, cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (actionPrefix != null && !actionPrefix.isBlank()) {
                ps.add(cb.like(cb.lower(root.get("action")),
                        actionPrefix.trim().toLowerCase(Locale.ROOT) + "%"));
            }
            if (actorAccount != null && !actorAccount.isBlank()) {
                ps.add(cb.like(cb.lower(root.get("actorAccount")),
                        "%" + actorAccount.trim().toLowerCase(Locale.ROOT) + "%"));
            }
            if (dateFrom != null) {
                ps.add(cb.greaterThanOrEqualTo(root.get("createdAt"),
                        BusinessTime.startOfDay(dateFrom)));
            }
            if (dateTo != null) {
                // 闭区间：dateTo 当日 23:59:59.999
                OffsetDateTime toExclusive = BusinessTime.startOfDay(dateTo.plusDays(1));
                ps.add(cb.lessThan(root.get("createdAt"), toExclusive));
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        if (riskLevel != null && !riskLevel.isBlank()) {
            base = base.and(riskSpecification(riskLevel));
        }
        if (eventCategory != null && !eventCategory.isBlank()) {
            base = base.and(categorySpecification(eventCategory));
        }
        if (outcome != null && !outcome.isBlank()) {
            base = base.and(outcomeSpecification(outcome));
        }
        return base;
    }

    Specification<AuditLog> riskSpecification(String riskLevel) {
        return (root, q, cb) -> {
            String normalized = riskLevel.trim().toLowerCase(Locale.ROOT);
            var storedRisk = root.<String>get("riskLevel");
            var action = cb.lower(root.<String>get("action"));
            Predicate promotedMediumRisk = cb.and(
                    cb.equal(storedRisk, "low"),
                    action.in(FORCED_MEDIUM_RISK_ACTIONS));
            if ("risky".equals(normalized)) {
                return cb.or(
                        storedRisk.in(List.of("critical", "high", "medium")),
                        promotedMediumRisk);
            }
            if (!List.of("critical", "high", "medium", "low").contains(normalized)) {
                return cb.disjunction();
            }
            if ("medium".equals(normalized)) {
                return cb.or(
                        cb.equal(storedRisk, "medium"),
                        promotedMediumRisk);
            }
            if ("low".equals(normalized)) {
                return cb.and(
                        cb.equal(storedRisk, "low"),
                        cb.not(action.in(FORCED_MEDIUM_RISK_ACTIONS)));
            }
            return cb.equal(storedRisk, normalized);
        };
    }

    Specification<AuditLog> categorySpecification(String eventCategory) {
        return (root, q, cb) -> {
            String normalized = eventCategory.trim().toLowerCase(Locale.ROOT);
            var action = cb.lower(root.<String>get("action"));
            Predicate forcedSecurity = action.in(AUDIT_INVESTIGATION_ACTIONS);
            Predicate forcedExport = action.in(DATA_EXPORT_ACTIONS);
            Predicate anyForcedCategory = cb.or(forcedSecurity, forcedExport);
            Predicate storedCategory = cb.equal(root.get("eventCategory"), normalized);
            Predicate storedUnforcedCategory = cb.and(
                    storedCategory,
                    cb.not(anyForcedCategory));
            if ("security".equals(normalized)) {
                return cb.or(forcedSecurity, storedUnforcedCategory);
            }
            if ("export".equals(normalized)) {
                return cb.or(forcedExport, storedUnforcedCategory);
            }
            return storedUnforcedCategory;
        };
    }

    private Specification<AuditLog> outcomeSpecification(String outcome) {
        return (root, q, cb) -> {
            String normalized = outcome.trim().toLowerCase(Locale.ROOT);
            var result = cb.lower(root.get("result"));
            var failed = cb.or(
                    cb.and(
                            cb.isNotNull(root.get("statusCode")),
                            cb.greaterThanOrEqualTo(root.get("statusCode"), 400)),
                    cb.and(cb.isNotNull(root.get("result")), cb.notEqual(result, "success")));
            return "success".equals(normalized) ? cb.not(failed) : failed;
        };
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('audit_log:view')")
    public AuditLogDetail detail(long id) {
        return repo.findById(id)
                .map(value -> AuditLogDetail.of(value, interpreter))
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND, "审计日志不存在或已归档"));
    }
}
