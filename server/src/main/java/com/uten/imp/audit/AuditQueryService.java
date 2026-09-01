package com.uten.imp.audit;

import com.uten.imp.common.export.ExportColumn;
import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.common.time.BusinessTime;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.PageResponse;
import com.uten.imp.common.web.Pageables;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Predicate;
import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Root;
import lombok.RequiredArgsConstructor;
import org.hibernate.query.criteria.JpaExpression;
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
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

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
@RequiredArgsConstructor(onConstructor_ = @org.springframework.beans.factory.annotation.Autowired)
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
    private static final List<String> AUTOMATIC_ACTIVITY_ACTIONS = List.of(
            "refresh_token",
            "visitor_refresh_token");
    private static final List<String> SUCCESS_RESULT_CODES = List.of(
            "success",
            "succeeded");
    private static final Set<String> ALLOWED_RISK_LEVELS = Set.of(
            "critical", "high", "medium", "low", "risky");
    private static final Set<String> ALLOWED_OUTCOMES = Set.of("success", "failure");
    private static final Set<String> ALLOWED_EVENT_CATEGORIES = Set.of(
            "security", "authorization", "authentication", "export",
            "data_change", "system", "business");
    private static final Set<String> ALLOWED_EVENT_SOURCES = Set.of(
            "request", "database", "business", "security");
    private static final Map<String, List<String>> OPERATION_ACTIONS = Map.of(
            "create", List.of("insert", "http_post"),
            "update", List.of("update", "http_put", "http_patch"),
            "delete", List.of("delete", "http_delete"),
            "write", List.of(
                    "insert", "update", "delete",
                    "http_post", "http_put", "http_patch", "http_delete"),
            "read", List.of("http_get"));
    private static final Map<String, List<String>> TARGET_TYPE_ALIASES = Map.of(
            "goods", List.of("goods", "api/master/goods"),
            "material_categories", List.of(
                    "material_categories", "api/master/material-categories"),
            "clients", List.of("clients", "api/master/clients"),
            "suppliers", List.of("suppliers", "api/master/suppliers"));
    private static final DateTimeFormatter EXPORT_TIME =
            DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");
    private static final List<ExportColumn> EXPORT_COLUMNS = List.of(
            new ExportColumn("createdAt", "发生时间(北京时间)", ExportColumn.TEXT),
            new ExportColumn("actor", "操作人", ExportColumn.TEXT),
            new ExportColumn("actorName", "操作人姓名", ExportColumn.TEXT),
            new ExportColumn("actorDepartment", "操作人部门", ExportColumn.TEXT),
            new ExportColumn("actorPosition", "操作人职位", ExportColumn.TEXT),
            new ExportColumn("actorType", "主体类型", ExportColumn.TEXT),
            new ExportColumn("actionLabel", "做了什么", ExportColumn.TEXT),
            new ExportColumn("objectLabel", "操作对象", ExportColumn.TEXT),
            new ExportColumn("targetName", "对象名称/单号", ExportColumn.TEXT),
            new ExportColumn("targetDisplayName", "业务对象名称", ExportColumn.TEXT),
            new ExportColumn("targetBusinessCode", "业务编号/单号", ExportColumn.TEXT),
            new ExportColumn("targetLegacyCode", "旧系统编号", ExportColumn.TEXT),
            new ExportColumn("pageLabel", "所在页面", ExportColumn.TEXT),
            new ExportColumn("targetId", "对象 ID", ExportColumn.TEXT),
            new ExportColumn("outcome", "操作结果", ExportColumn.TEXT),
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
            new ExportColumn("deviceTimeZoneOffsetMinutes", "时区偏移(分钟)", ExportColumn.TEXT),
            new ExportColumn("deviceIsPhysical", "物理设备状态", ExportColumn.TEXT),
            new ExportColumn("deviceInstallationId", "本机安装标识", ExportColumn.TEXT),
            new ExportColumn("clientEventId", "本地操作 ID", ExportColumn.TEXT),
            new ExportColumn("clientEventAt", "本机发起时间", ExportColumn.TEXT),
            new ExportColumn("deviceCaptureStatus", "设备信息状态", ExportColumn.TEXT),
            new ExportColumn("deviceProfileHash", "设备快照摘要", ExportColumn.TEXT),
            new ExportColumn("ip", "IP 地址", ExportColumn.TEXT),
            new ExportColumn("httpMethod", "请求方式", ExportColumn.TEXT),
            new ExportColumn("httpPath", "HTTP 路径", ExportColumn.TEXT),
            new ExportColumn("statusCode", "请求状态码", ExportColumn.TEXT),
            new ExportColumn("durationMs", "耗时(毫秒)", ExportColumn.TEXT),
            new ExportColumn("requestId", "操作关联编号", ExportColumn.TEXT),
            new ExportColumn("auditId", "审计日志 ID", ExportColumn.TEXT));

    private final AuditLogRepository repo;
    private final AuditEventInterpreter interpreter;
    private final AuditActorDirectory actorDirectory;
    private final AuditSummaryAggregation summaryAggregation;

    /** Package-local compatibility constructor for focused specification tests. */
    AuditQueryService(
            AuditLogRepository repo,
            AuditEventInterpreter interpreter,
            AuditActorDirectory actorDirectory) {
        this(repo, interpreter, actorDirectory, null);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('audit_log:view')")
    public AuditPageResponse query(AuditSearchCriteria criteria, int page, int size) {
        validateInvestigationScope(criteria);
        AuditSearchCriteria boundedCriteria = withResolvedSnapshot(criteria);
        long snapshotId = boundedCriteria.snapshotId();
        Specification<AuditLog> spec = specification(boundedCriteria);
        Pageable pageable = Pageables.of(page, size,
                Sort.by(Sort.Direction.DESC, "createdAt")
                        .and(Sort.by(Sort.Direction.DESC, "id")));
        Page<AuditLog> p = repo.findAll(spec, pageable);
        AuditActorDirectory.Resolution actors = actorDirectory.resolve(
                AuditActorDirectory.actorIdsOf(p.getContent()),
                AuditActorDirectory.actorAccountsOf(p.getContent()));
        List<AuditLogRow> items = p.getContent().stream()
                .map(value -> AuditLogRow.of(
                        value,
                        interpreter,
                        actors.forActor(value.getActorId(), value.getActorAccount())))
                .toList();
        return new AuditPageResponse(
                items,
                pageable.getPageNumber() + 1,
                pageable.getPageSize(),
                p.getTotalElements(),
                p.getTotalPages(),
                snapshotId);
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('audit_log:view')")
    public AuditSummary summary(AuditSearchCriteria criteria) {
        validateInvestigationScope(criteria);
        AuditSearchCriteria bounded = withResolvedSnapshot(criteria);
        Specification<AuditLog> base = specification(bounded);
        return summaryAggregation.summarize(
                base,
                riskSpecification("risky"),
                riskSpecification("critical"),
                outcomeSpecification("failure"),
                operationSpecification("write"),
                bounded.dateFrom(),
                bounded.dateTo());
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('audit_log:view')")
    public PageResponse<AuditActorOption> actors(String keyword, int page, int size) {
        return actorDirectory.findActors(keyword, page, size);
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
    public ExportPayload export(AuditSearchCriteria criteria, int maxRows) {
        validateInvestigationScope(criteria);
        if (maxRows < 1 || maxRows > 100_000) {
            throw new ApiException(
                    ErrorCode.VALIDATION_FAILED,
                    "导出行数上限配置异常，请先在系统设置中调整为 1 至 100000");
        }
        int safeMaxRows = Math.min(maxRows, 10_000);
        Specification<AuditLog> spec = specification(withResolvedSnapshot(criteria));
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
        AuditActorDirectory.Resolution actors = actorDirectory.resolve(
                AuditActorDirectory.actorIdsOf(page.getContent()),
                AuditActorDirectory.actorAccountsOf(page.getContent()));
        List<Map<String, Object>> rows = page.getContent().stream()
                .map(value -> toExportRow(value, actors))
                .toList();
        return new ExportPayload(EXPORT_COLUMNS, rows, rows.size());
    }

    private Map<String, Object> toExportRow(AuditLog value, AuditActorDirectory.Resolution actors) {
        AuditLogRow row = AuditLogRow.of(
                value,
                interpreter,
                actors.forActor(value.getActorId(), value.getActorAccount()));
        Map<String, Object> exported = new LinkedHashMap<>();
        exported.put("createdAt", row.getCreatedAt() == null
                ? ""
                : row.getCreatedAt()
                        .atZoneSameInstant(BusinessTime.ZONE)
                        .format(EXPORT_TIME) + "(北京时间)");
        exported.put("actor", row.getActorDisplay());
        exported.put("actorName", firstNonBlank(row.getActorName(), ""));
        exported.put("actorDepartment", firstNonBlank(row.getActorDepartment(), ""));
        exported.put("actorPosition", firstNonBlank(row.getActorPosition(), ""));
        exported.put("actorType", row.getActorType());
        exported.put("actionLabel", row.getActionLabel());
        exported.put("objectLabel", row.getObjectLabel());
        exported.put("targetName", firstNonBlank(row.getTargetName(), ""));
        exported.put("targetDisplayName",
                firstNonBlank(row.getTargetDisplayName(), ""));
        exported.put("targetBusinessCode",
                firstNonBlank(row.getTargetBusinessCode(), ""));
        exported.put("targetLegacyCode",
                firstNonBlank(row.getTargetLegacyCode(), ""));
        exported.put("pageLabel", firstNonBlank(row.getPageLabel(), ""));
        exported.put("targetId", row.getTargetId());
        exported.put("outcome", failed(row) ? "失败" : "成功");
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
                        .format(EXPORT_TIME) + "(北京时间)");
        exported.put("deviceCaptureStatus", value.getDeviceCaptureStatus());
        exported.put("deviceProfileHash", value.getDeviceProfileHash());
        exported.put("ip", row.getIp());
        exported.put("httpMethod", httpMethodLabel(value.getHttpMethod()));
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
        if (row.getResult() == null) {
            return false;
        }
        String mainCode = row.getResult().split(";", 2)[0]
                .trim()
                .toLowerCase(Locale.ROOT);
        return !SUCCESS_RESULT_CODES.contains(mainCode);
    }

    private String riskLabel(String value) {
        return switch (value == null ? "" : value) {
            case "critical" -> "严重";
            case "high" -> "高";
            case "medium" -> "中";
            case "low" -> "低";
            default -> "未登记";
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
            default -> "未登记事件类型";
        };
    }

    private String sourceLabel(String value) {
        return switch (value == null ? "" : value) {
            case "request" -> "请求覆盖";
            case "database" -> "数据库变更";
            case "security" -> "安全拦截";
            case "business" -> "业务事件";
            default -> "未登记记录来源";
        };
    }

    private String httpMethodLabel(String value) {
        return switch (value == null ? "" : value.trim().toUpperCase(Locale.ROOT)) {
            case "GET" -> "读取";
            case "POST" -> "提交";
            case "PUT" -> "整体更新";
            case "PATCH" -> "局部更新";
            case "DELETE" -> "删除";
            case "HEAD" -> "读取响应信息";
            default -> "请求方式未记录";
        };
    }

    private String firstNonBlank(String value, String fallback) {
        return value == null || value.isBlank() ? fallback : value;
    }

    Specification<AuditLog> specification(AuditSearchCriteria criteria) {
        validateFilterValues(criteria);
        String actorScope = normalizedActorScope(criteria.actorScope());
        String operationKind = normalizedOperationKind(criteria.operationKind());
        String riskLevel = normalizedFilter(criteria.riskLevel());
        String eventCategory = normalizedFilter(criteria.eventCategory());
        String outcome = normalizedFilter(criteria.outcome());
        String eventSource = normalizedFilter(criteria.eventSource());
        UUID parsedRequestId = parseRequestId(criteria.requestId());
        if (criteria.snapshotId() != null) {
            validateSnapshotId(criteria.snapshotId());
        }
        Specification<AuditLog> base = (root, q, cb) -> {
            List<Predicate> ps = new ArrayList<>();
            if (hasText(criteria.action())) {
                ps.add(cb.like(cb.lower(root.get("action")),
                        criteria.action().trim().toLowerCase(Locale.ROOT) + "%"));
            }
            if (criteria.actorId() != null) {
                ps.add(cb.equal(root.get("actorId"), criteria.actorId()));
            } else if (hasText(criteria.actorAccount())) {
                ps.add(cb.like(cb.lower(root.get("actorAccount")),
                        "%" + criteria.actorAccount().trim().toLowerCase(Locale.ROOT) + "%"));
            }
            if (criteria.activityOnly()) {
                ps.add(cb.notEqual(cb.lower(root.get("eventSource")), "database"));
                Expression<String> activityAction = cb.lower(root.get("action"));
                Expression<String> activityResult = cb.lower(root.get("result"));
                ps.add(cb.not(cb.and(
                        activityAction.in(AUTOMATIC_ACTIVITY_ACTIONS),
                        cb.equal(activityResult, "success"))));
                Expression<String> requestMethod = cb.upper(root.get("httpMethod"));
                Expression<String> requestPath = cb.lower(root.get("httpPath"));
                List<Predicate> automaticReadRoutes = new ArrayList<>();
                automaticReadRoutes.add(
                        requestPath.in(AuditNoisePolicy.automaticReadPaths()));
                AuditNoisePolicy.automaticReadSqlLikePatterns().forEach(pattern ->
                        automaticReadRoutes.add(cb.like(requestPath, pattern)));
                Predicate automaticRead = cb.and(
                        requestMethod.in(List.of("GET", "HEAD")),
                        cb.or(automaticReadRoutes.toArray(new Predicate[0])));
                List<Predicate> automaticSessionRoutes = new ArrayList<>();
                automaticSessionRoutes.add(
                        requestPath.in(AuditNoisePolicy.automaticSessionWritePaths()));
                AuditNoisePolicy.automaticSessionWriteSqlLikePatterns().forEach(pattern ->
                        automaticSessionRoutes.add(cb.like(requestPath, pattern)));
                Predicate automaticSessionWrite = cb.and(
                        cb.equal(requestMethod, "POST"),
                        cb.or(automaticSessionRoutes.toArray(new Predicate[0])));
                Predicate automaticHeartbeat = cb.and(
                        cb.equal(requestMethod, "POST"),
                        cb.like(requestPath, AuditNoisePolicy.heartbeatSqlLikePattern()));
                Predicate successfulHttp = cb.or(
                        cb.isNull(root.get("statusCode")),
                        cb.lessThan(root.get("statusCode"), 400));
                Predicate successfulResult = mainResultExpression(root, cb)
                        .in(SUCCESS_RESULT_CODES);
                Predicate historicalAutomaticSuccess = cb.and(
                        cb.equal(cb.lower(root.get("eventSource")), "request"),
                        cb.or(automaticRead, automaticSessionWrite, automaticHeartbeat),
                        successfulHttp,
                        successfulResult);
                ps.add(cb.not(historicalAutomaticSuccess));
            }
            if (hasText(criteria.targetType())) {
                String normalizedTarget = criteria.targetType()
                        .trim().toLowerCase(Locale.ROOT);
                Expression<String> storedTarget = cb.lower(
                        root.<String>get("targetType"));
                List<String> aliases = TARGET_TYPE_ALIASES.get(normalizedTarget);
                ps.add(aliases == null
                        ? cb.equal(storedTarget, normalizedTarget)
                        : storedTarget.in(aliases));
            }
            if (hasText(criteria.targetId())) {
                ps.add(cb.equal(cb.lower(root.get("targetId")),
                        criteria.targetId().trim().toLowerCase(Locale.ROOT)));
            }
            if (eventSource != null) {
                ps.add(cb.equal(cb.lower(root.get("eventSource")),
                        eventSource));
            }
            if (parsedRequestId != null) {
                ps.add(cb.equal(root.get("requestId"), parsedRequestId));
            }
            if (criteria.snapshotId() != null) {
                ps.add(cb.lessThanOrEqualTo(root.get("id"), criteria.snapshotId()));
            }
            if (operationKind != null) {
                ps.add(operationPredicate(root, cb, operationKind));
            }
            if (actorScope != null) {
                var actorId = root.get("actorId");
                Predicate anonymousEvidence = anonymousEvidencePredicate(root, cb);
                Predicate userActor = cb.isNotNull(actorId);
                Predicate systemActor = cb.and(
                        cb.isNull(actorId),
                        cb.not(anonymousEvidence),
                        failurePredicate(root, cb));
                ps.add(switch (actorScope) {
                    case "user" -> userActor;
                    case "anonymous" -> anonymousEvidence;
                    default -> systemActor;
                });
            }
            if (hasText(criteria.keyword())) {
                String pattern = "%" + escapeLike(
                        criteria.keyword().trim().toLowerCase(Locale.ROOT)) + "%";
                Expression<String> requestIdText = ((JpaExpression<?>)
                        root.get("requestId")).cast(String.class);
                Expression<String> viewDisplayName = cb.function(
                        "jsonb_extract_path_text",
                        String.class,
                        root.get("after"),
                        cb.literal("view_display_name"));
                Expression<String> targetDisplayName = cb.function(
                        "jsonb_extract_path_text",
                        String.class,
                        root.get("after"),
                        cb.literal("target_display_name"));
                Expression<String> targetBusinessCode = cb.function(
                        "jsonb_extract_path_text",
                        String.class,
                        root.get("after"),
                        cb.literal("target_business_code"));
                Expression<String> targetLegacyCode = cb.function(
                        "jsonb_extract_path_text",
                        String.class,
                        root.get("after"),
                        cb.literal("target_legacy_code"));
                // 操作人支持按"姓名"检索：先解析命中的用户 ID，再并入 OR 组。
                java.util.Set<UUID> nameMatchedActorIds =
                        actorDirectory.findUserIdsByNameKeyword(criteria.keyword());
                List<Predicate> keywordOr = new ArrayList<>(List.of(
                        cb.like(cb.lower(root.get("action")), pattern, '!'),
                        cb.like(cb.lower(root.get("actorAccount")), pattern, '!'),
                        cb.like(cb.lower(root.get("targetType")), pattern, '!'),
                        cb.like(cb.lower(root.get("targetId")), pattern, '!'),
                        cb.like(cb.lower(viewDisplayName), pattern, '!'),
                        cb.like(cb.lower(targetDisplayName), pattern, '!'),
                        cb.like(cb.lower(targetBusinessCode), pattern, '!'),
                        cb.like(cb.lower(targetLegacyCode), pattern, '!'),
                        cb.like(cb.lower(root.get("httpPath")), pattern, '!'),
                        cb.like(cb.lower(requestIdText), pattern, '!')));
                if (nameMatchedActorIds != null && !nameMatchedActorIds.isEmpty()) {
                    keywordOr.add(root.get("actorId").in(nameMatchedActorIds));
                }
                ps.add(cb.or(keywordOr.toArray(new Predicate[0])));
            }
            if (criteria.dateFrom() != null) {
                ps.add(cb.greaterThanOrEqualTo(root.get("createdAt"),
                        BusinessTime.startOfDay(criteria.dateFrom())));
            }
            if (criteria.dateTo() != null) {
                // 闭区间：dateTo 当日 23:59:59.999
                OffsetDateTime toExclusive = BusinessTime.startOfDay(criteria.dateTo().plusDays(1));
                ps.add(cb.lessThan(root.get("createdAt"), toExclusive));
            }
            return cb.and(ps.toArray(new Predicate[0]));
        };
        if (riskLevel != null) {
            base = base.and(riskSpecification(riskLevel));
        }
        if (eventCategory != null) {
            base = base.and(categorySpecification(eventCategory));
        }
        if (outcome != null) {
            base = base.and(outcomeSpecification(outcome));
        }
        return base;
    }

    static void validateFilterValues(AuditSearchCriteria criteria) {
        validateAllowed(
                criteria.riskLevel(), ALLOWED_RISK_LEVELS,
                "风险等级仅支持严重、高、中、低、有风险");
        validateAllowed(
                criteria.outcome(), ALLOWED_OUTCOMES,
                "结果仅支持成功、失败");
        validateAllowed(
                criteria.eventCategory(), ALLOWED_EVENT_CATEGORIES,
                "事件类型仅支持安全事件、权限变更、登录认证、数据导出、数据变化、系统设置、业务操作");
        validateAllowed(
                criteria.eventSource(), ALLOWED_EVENT_SOURCES,
                "记录来源仅支持页面操作、数据变化明细、业务事件、安全拦截");
    }

    private static void validateAllowed(
            String value,
            Set<String> allowed,
            String message) {
        String normalized = normalizedFilter(value);
        if (normalized != null && !allowed.contains(normalized)) {
            throw new ApiException(ErrorCode.MALFORMED_REQUEST, message);
        }
    }

    private static String normalizedFilter(String value) {
        return value == null || value.isBlank()
                ? null
                : value.trim().toLowerCase(Locale.ROOT);
    }

    /**
     * Historical soft deletes were written by PostgreSQL as UPDATE rows. Keep
     * them visible under the user-facing delete filter without rewriting the
     * immutable audit history. Future transitions are stored as delete.
     */
    private Predicate softDeletePredicate(
            Root<AuditLog> root,
            CriteriaBuilder cb,
            Expression<String> action) {
        Expression<String> beforeDeleted = cb.function(
                "jsonb_extract_path_text", String.class,
                root.get("before"), cb.literal("is_deleted"));
        Expression<String> afterDeleted = cb.function(
                "jsonb_extract_path_text", String.class,
                root.get("after"), cb.literal("is_deleted"));
        Expression<String> beforeDeletedAt = cb.function(
                "jsonb_extract_path_text", String.class,
                root.get("before"), cb.literal("deleted_at"));
        Expression<String> afterDeletedAt = cb.function(
                "jsonb_extract_path_text", String.class,
                root.get("after"), cb.literal("deleted_at"));
        Expression<Boolean> beforeHasDeletedAt = cb.function(
                "jsonb_exists", Boolean.class,
                root.get("before"), cb.literal("deleted_at"));
        Expression<Boolean> afterHasDeletedAt = cb.function(
                "jsonb_exists", Boolean.class,
                root.get("after"), cb.literal("deleted_at"));
        Predicate flagTransition = cb.and(
                cb.isNotNull(beforeDeleted),
                cb.isNotNull(afterDeleted),
                cb.equal(beforeDeleted, "false"),
                cb.equal(afterDeleted, "true"));
        Predicate timestampTransition = cb.and(
                cb.isTrue(beforeHasDeletedAt),
                cb.isTrue(afterHasDeletedAt),
                cb.isNull(beforeDeletedAt),
                cb.isNotNull(afterDeletedAt));
        return cb.and(
                cb.equal(action, "update"),
                cb.or(flagTransition, timestampTransition));
    }

    private long validateSnapshotId(long snapshotId) {
        if (snapshotId < 0) {
            throw new ApiException(
                    ErrorCode.MALFORMED_REQUEST, "查询快照编号不能小于 0");
        }
        return snapshotId;
    }

    private AuditSearchCriteria withResolvedSnapshot(AuditSearchCriteria criteria) {
        long snapshotId = criteria.snapshotId() == null
                ? repo.findMaxId()
                : validateSnapshotId(criteria.snapshotId());
        return criteria.withSnapshotId(snapshotId);
    }

    private String normalizedOperationKind(String value) {
        if (!hasText(value)) {
            return null;
        }
        String normalized = value.trim().toLowerCase(Locale.ROOT);
        if (!OPERATION_ACTIONS.containsKey(normalized)) {
            throw new ApiException(
                    ErrorCode.MALFORMED_REQUEST,
                    "操作类型仅支持新增、修改、删除、写操作、查看");
        }
        return normalized;
    }

    private String normalizedActorScope(String value) {
        if (!hasText(value)) {
            return null;
        }
        String normalized = value.trim().toLowerCase(Locale.ROOT);
        if (!List.of("user", "system", "anonymous").contains(normalized)) {
            throw new ApiException(
                    ErrorCode.MALFORMED_REQUEST,
                    "人员范围仅支持人员、匿名访问、系统任务");
        }
        return normalized;
    }

    private UUID parseRequestId(String value) {
        if (!hasText(value)) {
            return null;
        }
        try {
            UUID parsed = UUID.fromString(value.trim());
            if (!parsed.toString().equalsIgnoreCase(value.trim())) {
                throw new IllegalArgumentException("non-canonical UUID");
            }
            return parsed;
        } catch (IllegalArgumentException exception) {
            throw new ApiException(
                    ErrorCode.MALFORMED_REQUEST,
                    "操作关联编号必须为标准 UUID");
        }
    }

    void validateInvestigationScope(AuditSearchCriteria criteria) {
        if (hasText(criteria.requestId())) {
            parseRequestId(criteria.requestId());
            validateOptionalDateWindow(criteria.dateFrom(), criteria.dateTo());
            return;
        }
        if ("anonymous".equals(normalizedActorScope(criteria.actorScope()))) {
            if (criteria.dateFrom() == null || criteria.dateTo() == null) {
                throw new ApiException(
                        ErrorCode.MALFORMED_REQUEST,
                        "查询匿名安全事件必须选择完整日期区间(北京时间)");
            }
            validateDateWindow(criteria.dateFrom(), criteria.dateTo());
            return;
        }
        if ("system".equals(normalizedActorScope(criteria.actorScope()))) {
            if (!criteria.activityOnly()) {
                throw new ApiException(
                        ErrorCode.MALFORMED_REQUEST,
                        "系统异常只支持人员活动视图");
            }
            if (criteria.dateFrom() == null || criteria.dateTo() == null) {
                throw new ApiException(
                        ErrorCode.MALFORMED_REQUEST,
                        "查询系统异常必须选择完整日期区间(北京时间)");
            }
            validateDateWindow(criteria.dateFrom(), criteria.dateTo());
            return;
        }
        if (criteria.actorId() == null) {
            throw new ApiException(
                    ErrorCode.MALFORMED_REQUEST,
                    "请先选择操作人员，再查询审计日志");
        }
        if (criteria.dateFrom() == null || criteria.dateTo() == null) {
            throw new ApiException(
                    ErrorCode.MALFORMED_REQUEST,
                    "请选择完整的开始日期和结束日期(北京时间)");
        }
        validateDateWindow(criteria.dateFrom(), criteria.dateTo());
    }

    private void validateOptionalDateWindow(LocalDate dateFrom, LocalDate dateTo) {
        if (dateFrom == null && dateTo == null) {
            return;
        }
        if (dateFrom == null || dateTo == null) {
            throw new ApiException(
                    ErrorCode.MALFORMED_REQUEST,
                    "开始日期和结束日期必须同时填写(北京时间)");
        }
        validateDateWindow(dateFrom, dateTo);
    }

    private void validateDateWindow(LocalDate dateFrom, LocalDate dateTo) {
        if (dateFrom.isAfter(dateTo)) {
            throw new ApiException(
                    ErrorCode.MALFORMED_REQUEST,
                    "开始日期不能晚于结束日期");
        }
        long inclusiveDays = ChronoUnit.DAYS.between(dateFrom, dateTo) + 1;
        if (inclusiveDays > 31) {
            throw new ApiException(
                    ErrorCode.MALFORMED_REQUEST,
                    "单次最多查询连续 31 天的审计日志，请缩小日期区间");
        }
    }

    Specification<AuditLog> operationSpecification(String operationKind) {
        String normalized = normalizedOperationKind(operationKind);
        return (root, q, cb) -> operationPredicate(root, cb, normalized);
    }

    private Predicate operationPredicate(
            Root<AuditLog> root,
            CriteriaBuilder cb,
            String operationKind) {
        Expression<String> action = cb.lower(root.get("action"));
        Expression<String> method = cb.upper(root.get("httpMethod"));
        Expression<String> category = cb.lower(root.get("eventCategory"));
        Predicate directDataAction = switch (operationKind) {
            case "create" -> cb.equal(action, "insert");
            case "update" -> cb.equal(action, "update");
            case "delete" -> cb.equal(action, "delete");
            case "write" -> action.in(List.of("insert", "update", "delete"));
            case "read" -> cb.equal(action, "http_get");
            default -> cb.disjunction();
        };
        Predicate methodMatch = switch (operationKind) {
            case "create" -> cb.equal(method, "POST");
            case "update" -> method.in(List.of("PUT", "PATCH"));
            case "delete" -> cb.equal(method, "DELETE");
            case "write" -> method.in(List.of("POST", "PUT", "PATCH", "DELETE"));
            case "read" -> cb.equal(method, "GET");
            default -> cb.disjunction();
        };
        Predicate userBusinessMethod = "read".equals(operationKind)
                ? methodMatch
                : cb.and(
                        methodMatch,
                        cb.not(category.in(List.of(
                                "authentication", "security", "export"))),
                        cb.not(cb.like(action, "view!_%", '!')));
        Predicate effective = cb.or(directDataAction, userBusinessMethod);
        if ("read".equals(operationKind)) {
            return cb.or(effective, cb.like(action, "view!_%", '!'));
        }
        if ("delete".equals(operationKind)) {
            return cb.or(effective, softDeletePredicate(root, cb, action));
        }
        if ("update".equals(operationKind)) {
            return cb.and(effective, cb.not(softDeletePredicate(root, cb, action)));
        }
        return effective;
    }

    private Predicate anonymousEvidencePredicate(
            Root<AuditLog> root,
            CriteriaBuilder cb) {
        var actorId = root.get("actorId");
        Expression<String> account = cb.lower(cb.trim(root.get("actorAccount")));
        Expression<String> action = cb.lower(root.get("action"));
        Expression<String> eventSource = cb.lower(root.get("eventSource"));
        Expression<String> category = cb.lower(root.get("eventCategory"));
        Predicate notSystemAccount = cb.or(
                cb.isNull(root.get("actorAccount")),
                cb.not(account.in(List.of("system", "ops"))));
        Predicate securityOrLogin = cb.or(
                cb.equal(eventSource, "security"),
                category.in(List.of("security", "authentication")),
                cb.like(action, "%login%"),
                cb.like(action, "%access_denied%"));
        return cb.and(cb.isNull(actorId), notSystemAccount, securityOrLogin);
    }

    private boolean hasText(String value) {
        return value != null && !value.isBlank();
    }

    private String escapeLike(String value) {
        return value.replace("!", "!!")
                .replace("%", "!%")
                .replace("_", "!_");
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
                        promotedMediumRisk,
                        softDeletePredicate(root, cb, action));
            }
            if (!List.of("critical", "high", "medium", "low").contains(normalized)) {
                return cb.disjunction();
            }
            if ("medium".equals(normalized)) {
                return cb.and(
                        cb.or(
                                cb.equal(storedRisk, "medium"),
                                promotedMediumRisk),
                        cb.not(softDeletePredicate(root, cb, action)));
            }
            if ("low".equals(normalized)) {
                return cb.and(
                        cb.equal(storedRisk, "low"),
                        cb.not(action.in(FORCED_MEDIUM_RISK_ACTIONS)),
                        cb.not(softDeletePredicate(root, cb, action)));
            }
            if ("high".equals(normalized)) {
                return cb.or(
                        cb.equal(storedRisk, "high"),
                        softDeletePredicate(root, cb, action));
            }
            return cb.and(
                    cb.equal(storedRisk, normalized),
                    cb.not(softDeletePredicate(root, cb, action)));
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

    Specification<AuditLog> outcomeSpecification(String outcome) {
        return (root, q, cb) -> {
            String normalized = outcome.trim().toLowerCase(Locale.ROOT);
            Predicate failed = failurePredicate(root, cb);
            return "success".equals(normalized) ? cb.not(failed) : failed;
        };
    }

    private Predicate failurePredicate(
            Root<AuditLog> root,
            CriteriaBuilder cb) {
        Predicate successfulResult = mainResultExpression(root, cb)
                .in(SUCCESS_RESULT_CODES);
        return cb.or(
                cb.and(
                        cb.isNotNull(root.get("statusCode")),
                        cb.greaterThanOrEqualTo(root.get("statusCode"), 400)),
                cb.and(
                        cb.isNotNull(root.get("result")),
                        cb.not(successfulResult)));
    }

    static boolean isSystemExceptionRecord(AuditLog value) {
        if (value == null || value.getActorId() != null) {
            return false;
        }
        String account = value.getActorAccount() == null
                ? ""
                : value.getActorAccount().trim().toLowerCase(Locale.ROOT);
        if (!account.isBlank() && !List.of("system", "ops").contains(account)) {
            return false;
        }
        String action = value.getAction() == null
                ? ""
                : value.getAction().trim().toLowerCase(Locale.ROOT);
        String source = value.getEventSource() == null
                ? ""
                : value.getEventSource().trim().toLowerCase(Locale.ROOT);
        String category = value.getEventCategory() == null
                ? ""
                : value.getEventCategory().trim().toLowerCase(Locale.ROOT);
        if (account.isBlank()
                && ("security".equals(source)
                || List.of("security", "authentication").contains(category)
                || action.contains("login")
                || action.contains("access_denied"))) {
            return false;
        }
        if (value.getStatusCode() != null && value.getStatusCode() >= 400) {
            return true;
        }
        if (value.getResult() == null) {
            return false;
        }
        String main = value.getResult().split(";", 2)[0]
                .trim().toLowerCase(Locale.ROOT);
        return !SUCCESS_RESULT_CODES.contains(main);
    }

    private Expression<String> mainResultExpression(
            Root<AuditLog> root,
            CriteriaBuilder cb) {
        return cb.lower(cb.trim(cb.function(
                "split_part",
                String.class,
                root.get("result"),
                cb.literal(";"),
                cb.literal(1))));
    }

    @Transactional(readOnly = true)
    @PreAuthorize("hasAuthority('audit_log:view')")
    public AuditLogDetail detail(long id) {
        return repo.findById(id)
                .map(value -> AuditLogDetail.of(
                        value,
                        interpreter,
                        actorDirectory
                                .resolve(
                                        value.getActorId() == null
                                                ? List.of()
                                                : List.of(value.getActorId()),
                                        value.getActorAccount() == null
                                                ? List.of()
                                                : List.of(value.getActorAccount()))
                                .forActor(value.getActorId(), value.getActorAccount())))
                .orElseThrow(() -> new ApiException(
                        ErrorCode.NOT_FOUND, "审计日志不存在或已归档"));
    }
}
