package com.uten.imp.features.production.execution;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.time.Clock;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Real production facts; no model-written query, owner selector, state override or business mutation. */
@Component
public class ProductionAiChatTool implements AiChatToolPort {
    static final int LIMIT = 20;
    private static final String OVERVIEW = "OVERVIEW";
    private static final String WORKSHOP = "WORKSHOP";
    private static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss").withZone(ZoneId.of("Asia/Shanghai"));
    private final AiChatAccessPolicy access;
    private final SecurityContextCurrentUser current;
    private final ProductionExecutionWorkbenchService workbench;
    private final ObjectMapper json;
    private final Clock clock;

    public ProductionAiChatTool(AiChatAccessPolicy access, SecurityContextCurrentUser current,
                                ProductionExecutionWorkbenchService workbench, ObjectMapper json, Clock clock) {
        this.access = access; this.current = current; this.workbench = workbench; this.json = json; this.clock = clock;
    }
    @Override public String name() { return "production_in_progress"; }
    @Override public String title() { return "查询正在生产的产品"; }
    @Override public String domain() { return "PRODUCTION"; }
    @Override public boolean rememberQueryArguments() { return true; }
    @Override public String description() {
        return "查询当前已实际开工(IN_PROGRESS)的产品和工单，可不填keyword列出在产，也可按货品名称或编码查询。"
                + "范围取当前账号的生产总览权限或本人车间任务权限；不含待料、待开工。返回最多20张工单及总数、单位、车间、报工/质检/入库数量和查询时间。"
                + "仅当前工单快照，无历史日期参数；不能用当前结果回答昨天或上月的生产情况。";
    }
    @Override public Map<String,Object> parameters() {
        return Map.of("type", "object", "additionalProperties", false, "properties",
                Map.of("keyword", Map.of("type", "string", "maxLength", 80)), "required", List.of());
    }
    @Override public boolean available() {
        return access.hasDomain(domain()) && current.get().filter(actor -> actor.isSuperAdmin()
                || actor.getPermissions().contains("production_execution:overview")
                || actor.getPermissions().contains("production_execution:view")).isPresent();
    }

    @Override @Transactional(readOnly = true)
    public Map<String,Object> execute(Map<String,Object> arguments) {
        require();
        String keyword = keyword(arguments);
        String scope = current.get().filter(actor -> actor.isSuperAdmin()
                || actor.getPermissions().contains("production_execution:overview")).isPresent() ? OVERVIEW : WORKSHOP;
        Snapshot snapshot = snapshot(keyword, scope);
        String time = TIME.format(clock.instant());
        return Map.of("reply", render(snapshot, time, false), "detailReply", render(snapshot, time, true),
                "actions", List.of(), "_toolEvidence",
                Map.of("scope", scope, "keyword", keyword, "snapshot", digest(snapshot)));
    }

    private static String render(Snapshot snapshot, String time, boolean detailed) {
        if (snapshot.rows().isEmpty()) return "没找到正在生产的工单。";
        StringBuilder answer = new StringBuilder("正在生产：共 ").append(snapshot.total()).append(" 张工单。");
        if (detailed) answer.append("\n截至 ").append(time).append("。");
        int shown = Math.min(detailed ? LIMIT : 5, snapshot.rows().size());
        for (Map<String,String> row : snapshot.rows().subList(0, shown)) {
            answer.append("\n• ").append(row.get("productName")).append("（").append(row.get("productCode"))
                    .append("） · ").append(row.get("workshop"));
            if (detailed) answer.append(" · ").append(row.get("color")).append("\n  工单 ").append(row.get("segmentCode"))
                    .append("；计划单 ").append(row.get("planNo"));
            answer.append("：已报工 ").append(row.get("reported")).append(" / 计划 ").append(row.get("planned"))
                    .append(" ").append(row.get("unit"));
            if (detailed) answer.append("\n  待检 ").append(row.get("fqcPending")).append("；合格 ").append(row.get("fqcPassed"))
                    .append("；不合格 ").append(row.get("fqcFailed")).append("；待入库 ").append(row.get("inboundPending"))
                    .append("；已入库 ").append(row.get("inbound")).append(" ").append(row.get("unit"));
            answer.append("。");
        }
        if (snapshot.total() > shown) {
            answer.append("\n另有 ").append(snapshot.total() - shown).append(" 张，");
            int expandable = snapshot.rows().size() - shown;
            if (!detailed && expandable > 0) {
                answer.append("回复“展开”可").append(snapshot.total() > snapshot.rows().size() ? "再看 " + expandable + " 张；其余请到生产任务页查看" : "看更多");
            } else answer.append("请到生产任务页查看");
            answer.append("。");
        }
        return answer.toString();
    }

    @Override @Transactional(readOnly = true)
    public void authorizeResultRead(Map<String,Object> evidence) {
        require();
        if (evidence == null || !evidence.keySet().equals(Set.of("scope", "keyword", "snapshot"))
                || !(evidence.get("scope") instanceof String scope) || !Set.of(OVERVIEW, WORKSHOP).contains(scope)
                || !(evidence.get("keyword") instanceof String keyword)
                || !(evidence.get("snapshot") instanceof String expected) || !expected.matches("[0-9a-f]{64}")) throw changed();
        keyword(Map.of("keyword", keyword));
        // Requery the original bounded scope, never a newly widened choice of scope. IDs, workshop,
        // counts and all displayed facts participate, so transfers and concurrent changes invalidate it.
        if (!expected.equals(digest(snapshot(keyword, scope)))) throw changed();
    }

    private Snapshot snapshot(String keyword, String scope) {
        CurrentAuthorityGuard.requireAll(OVERVIEW.equals(scope) ? "production_execution:overview" : "production_execution:view");
        var page = workbench.inProgressTasks(keyword.isBlank() ? null : keyword, OVERVIEW.equals(scope), LIMIT);
        if (page.getItems().size() > LIMIT || page.getTotal() < page.getItems().size()) throw changed();
        List<Map<String,String>> rows = page.getItems().stream().map(this::facts).toList();
        return new Snapshot(scope, keyword, page.getTotal(), rows);
    }
    private Map<String,String> facts(ProductionExecutionWorkbenchSegment row) {
        if (row.segmentId() == null || !"IN_PROGRESS".equals(row.segmentStatus())) throw changed();
        Map<String,String> out = new LinkedHashMap<>();
        out.put("segmentId", row.segmentId().toString()); out.put("planId", String.valueOf(row.planId()));
        out.put("workshopId", String.valueOf(row.workshopDepartmentId())); out.put("status", row.segmentStatus());
        out.put("segmentCode", text(row.segmentCode())); out.put("planNo", text(row.planNo()));
        out.put("productCode", text(row.productCode())); out.put("productName", text(row.productName()));
        out.put("color", text(row.productColorName())); out.put("unit", text(row.productUnitName())); out.put("workshop", text(row.workshopName()));
        out.put("planned", number(row.plannedQty())); out.put("reported", number(row.reportedQty()));
        out.put("fqcPending", number(row.fqcPendingQty())); out.put("fqcPassed", number(row.fqcPassedQty()));
        out.put("fqcFailed", number(row.fqcFailedQty())); out.put("inboundPending", number(row.finishedInboundPendingQty()));
        out.put("inbound", number(row.inboundQty()));
        return out;
    }
    private void require() {
        access.requireDomain(domain());
        if (!available()) throw new ApiException(ErrorCode.FORBIDDEN, "你没有查看生产执行或车间任务的权限");
    }
    private static String keyword(Map<String,Object> arguments) {
        if (arguments == null || !Set.of("keyword").containsAll(arguments.keySet())) throw new ApiException(ErrorCode.VALIDATION_FAILED, "生产查询只能按货品名称或编码筛选");
        if (!arguments.containsKey("keyword")) return "";
        if (!(arguments.get("keyword") instanceof String value) || value.length() > 80 || value.codePoints().anyMatch(Character::isISOControl))
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "货品名称或编码不能超过 80 个字");
        return value.strip();
    }
    private String digest(Snapshot snapshot) {
        try { return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(json.writeValueAsString(snapshot).getBytes(StandardCharsets.UTF_8))); }
        catch (JsonProcessingException | NoSuchAlgorithmException failure) { throw new IllegalStateException("Cannot fingerprint production answer", failure); }
    }
    private record Snapshot(String scope, String keyword, long total, List<Map<String,String>> rows) {}
    private static String text(String value) {
        if (value == null || value.isBlank()) return "未登记";
        String clean=value.replaceAll("[\\p{Cntrl}]", " ");
        return clean.length() <= 64 ? clean : clean.substring(0,63) + "…";
    }
    private static String number(BigDecimal value) { return value == null ? "未登记" : value.stripTrailingZeros().toPlainString(); }
    private static ApiException changed() { return new ApiException(ErrorCode.FORBIDDEN, "在产工单或可见范围已变化，请重新查询"); }
}
