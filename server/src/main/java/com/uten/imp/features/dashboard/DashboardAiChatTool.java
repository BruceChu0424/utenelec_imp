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
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;

/** Uses the same department, row-scope and badge facts as the caller's workbench. */
@Component
public class DashboardAiChatTool implements AiChatToolPort {
    @Override public boolean rememberQueryArguments() { return true; }
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
                + "no arbitrary document details. Returns short operational counts with optional detail. Takes no arguments.";
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
    /** ADR-150: the already-authorized detail text (quantities and tasks, no costs) may be composed by the model. */
    @Override public Map<String, Object> modelFacts(Map<String, Object> result) {
        return result.get("detailReply") instanceof String text ? Map.of("facts", text) : Map.of();
    }

    @Override public Map<String, Object> execute(Map<String, Object> arguments) {
        if (!available()) throw new ApiException(ErrorCode.FORBIDDEN);
        if (arguments == null || !arguments.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "部门待办只查询你当前的工作台范围");
        }
        DashboardOverviewDto facts = overview.overview();
        List<String> lines = countLines(facts);
        return Map.of("reply", render(facts, false), "detailReply", render(facts, true),
                "actions", List.of(), "source", "dashboard/overview",
                "generatedAt", facts.generatedAt().toString(), "_toolEvidence", Map.of("counts", signature(lines)));
    }

    private record DisplayLine(String text, int priority, long count) {}

    private static String render(DashboardOverviewDto facts, boolean detailed) {
        List<DisplayLine> visible = new ArrayList<>();
        for (DashboardOverviewDto.MetricCard metric : facts.metrics()) {
            if (!List.of("production-pending", "sales-active").contains(metric.id()) || metric.sensitive()) continue;
            long count;
            try { count = Long.parseLong(metric.value()); }
            catch (NumberFormatException malformed) { count = -1; }
            if (count == 0) continue;
            visible.add(new DisplayLine(metric.title() + "：" + (count < 0 ? "暂时查不到数量" : metric.value()),
                    count < 0 ? 2 : "production-pending".equals(metric.id()) ? 0 : 1, count));
        }
        for (DashboardOverviewDto.TodoCard todo : facts.todos()) {
            if (todo.id() == null || todo.id().startsWith("notice-") || todo.id().startsWith("expense-")
                    || "production-pending".equals(todo.id()) || todo.count() == 0) continue;
            visible.add(new DisplayLine(todo.title() + "：待办 " + todo.count() + " 项", 0, todo.count()));
        }
        if (visible.isEmpty()) return countLines(facts).isEmpty() ? "暂时没有可显示的待办。" : "目前没有待办或进行中的任务。";
        visible.sort(Comparator.comparingInt(DisplayLine::priority)
                .thenComparing(Comparator.comparingLong(DisplayLine::count).reversed()).thenComparing(DisplayLine::text));
        int shown = detailed ? visible.size() : Math.min(5, visible.size());
        StringBuilder reply = new StringBuilder("目前需要关注：");
        for (DisplayLine line : visible.subList(0, shown)) reply.append("\n• ").append(line.text()).append("。");
        if (visible.size() > shown) reply.append("\n另有 ").append(visible.size() - shown).append(" 项，回复“展开”可看更多。");
        if (detailed) reply.append("\n更新于 ").append(TIME.format(facts.generatedAt())).append("。");
        return reply.toString();
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
