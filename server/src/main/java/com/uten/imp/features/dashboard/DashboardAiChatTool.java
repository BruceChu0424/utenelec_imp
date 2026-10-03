package com.uten.imp.features.dashboard;

import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.springframework.stereotype.Component;

import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;

/** Uses the same department, row-scope and badge facts as the caller's workbench. */
@Component
public class DashboardAiChatTool implements AiChatToolPort {
    private static final DateTimeFormatter TIME = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss")
            .withZone(ZoneId.of("Asia/Shanghai"));
    private final DashboardOverviewService overview;
    private final SecurityContextCurrentUser currentUser;

    public DashboardAiChatTool(DashboardOverviewService overview, SecurityContextCurrentUser currentUser) {
        this.overview = overview;
        this.currentUser = currentUser;
    }

    @Override public String name() { return "my_workbench"; }
    @Override public String title() { return "我的部门待办"; }
    @Override public String description() {
        return "Read current user's own department workbench counts and tasks. No other person or department, "
                + "no arbitrary document details. Result states its scope and time. Takes no arguments.";
    }
    @Override public String domain() { return "SELF"; }
    @Override public Map<String, Object> parameters() {
        return Map.of("type", "object", "properties", Map.of(), "required", List.of(), "additionalProperties", false);
    }
    @Override public boolean available() {
        return currentUser.get().filter(u -> !u.isVisitor() && u.getEmployeeId() != null
                && u.getImpersonatedBy() == null && !u.isMustChangePassword() && u.isAccountNonLocked())
                .map(u -> u.isSuperAdmin() || u.getPermissions().contains("ai:use")).orElse(false);
    }

    @Override public Map<String, Object> execute(Map<String, Object> arguments) {
        if (!available()) throw new ApiException(ErrorCode.FORBIDDEN);
        if (arguments == null || !arguments.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "部门待办只查询你当前的工作台范围");
        }
        DashboardOverviewDto facts = overview.overview();
        StringBuilder reply = new StringBuilder("以下是你当前工作台可见的部门信息，查询时间 ")
                .append(TIME.format(facts.generatedAt())).append(" (北京时间)。");
        List<String> lines = countLines(facts);
        lines.forEach(line -> reply.append("\n").append(line));
        if (lines.isEmpty()) reply.append("\n当前没有可展示的业务计数；这不代表全公司没有任务。");
        reply.append("\n来源: 我的工作台 / 今日概览。仅包含当前部门、权限和数据范围允许查看的内容。");
        return Map.of("reply", reply.toString(), "actions", List.of(), "source", "dashboard/overview",
                "generatedAt", facts.generatedAt().toString(), "_toolEvidence", Map.of("counts", signature(lines)));
    }

    @Override public void authorizeResultRead(Map<String, Object> evidence) {
        if (!available()) throw new ApiException(ErrorCode.FORBIDDEN);
        // Record ownership can change without revoking a function permission. Only replay a count
        // snapshot if the current authorized projection still supports those exact count facts.
        if (evidence == null || !signature(countLines(overview.overview())).equals(evidence.get("counts"))) {
            throw new ApiException(ErrorCode.FORBIDDEN, "工作台数据或可见范围已变化，请重新查询当前待办");
        }
    }

    private static List<String> countLines(DashboardOverviewDto facts) {
        List<String> lines = new ArrayList<>();
        // Notification text is user-authored and may contain unrelated information. Expense AI remains
        // retired (ADR-094). This capability only exposes trusted operational count cards.
        for (DashboardOverviewDto.MetricCard metric : facts.metrics()) {
            if (!List.of("production-pending", "sales-active").contains(metric.id()) || metric.sensitive()) continue;
            lines.add(metric.title() + ": " + metric.value());
        }
        for (DashboardOverviewDto.TodoCard todo : facts.todos()) {
            if (todo.id() == null || todo.id().startsWith("notice-") || todo.id().startsWith("expense-")
                    || "production-pending".equals(todo.id())) continue;
            lines.add(todo.title() + " (待办 " + todo.count() + ")");
        }
        return List.copyOf(lines);
    }

    private static String signature(List<String> lines) {
        try {
            return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(String.join("\n", lines).getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException unavailable) {
            throw new IllegalStateException("SHA-256 unavailable", unavailable);
        }
    }
}
