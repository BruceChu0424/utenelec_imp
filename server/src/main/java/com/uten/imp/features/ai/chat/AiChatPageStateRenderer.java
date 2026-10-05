package com.uten.imp.features.ai.chat;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * ADR-150 deterministic rendering of the current page snapshot. Used whenever the model is not
 * available, fails, or its reply does not pass {@link AiChatAnswerGuard}. It only rearranges what
 * the page itself reported: legend (colour = status = meaning, row count), items to check (row /
 * column / current value / reason / suggestion) and field states. It never invents a meaning.
 */
final class AiChatPageStateRenderer {
    static final int LIMIT = 12;
    private static final Map<String, String> TONE_COLORS = Map.of("neutral", "灰", "info", "蓝", "success", "绿",
            "warning", "黄", "danger", "红", "fuchsia", "品红", "violet", "紫", "accent", "青绿");

    enum Focus { ROW, COLORS, REVIEW, SUMMARY }

    /** "第3行", "row 3", "3번째 행": the question is about one row of the page's table. */
    private static final java.util.regex.Pattern ROW = java.util.regex.Pattern.compile(
            "第\\s*(\\d{1,4})\\s*行|(?i:\\brow\\s*#?\\s*(\\d{1,4})\\b)|(\\d{1,4})\\s*번째\\s*(?:행|줄)");
    /** Words that ask why or how, so a colour question needs more than the legend. */
    private static final java.util.regex.Pattern REASONING = java.util.regex.Pattern.compile(
            "为什么|为何|为啥|怎么|如何|怎样|下一步|该做|要做|规则|口径|(?i:\\bwhy\\b|\\bhow\\b|\\bnext\\b|\\brule)|왜|어떻게");

    private AiChatPageStateRenderer() {}

    static Focus focus(String question) {
        if (row(question) != null) return Focus.ROW;
        if (AiChatDialogueSupport.asksAboutColors(question)) return Focus.COLORS;
        if (AiChatDialogueSupport.asksForReview(question)) return Focus.REVIEW;
        return Focus.SUMMARY;
    }

    /** The row number the question names, or null. */
    static Integer row(String question) {
        if (question == null) return null;
        var matcher = ROW.matcher(java.text.Normalizer.normalize(question, java.text.Normalizer.Form.NFKC));
        if (!matcher.find()) return null;
        for (int group = 1; group <= matcher.groupCount(); group++) {
            if (matcher.group(group) != null) return Integer.valueOf(matcher.group(group));
        }
        return null;
    }

    /**
     * A question only about what the page's colours mean ("不同状态是什么颜色"), with a legend or badges to read:
     * the deterministic answer is exact and immediate, so no model call is made for it.
     */
    static boolean legendOnly(AiChatPageSnapshot snapshot, String question) {
        if (snapshot == null || question == null || focus(question) != Focus.COLORS) return false;
        if (REASONING.matcher(question).find()) return false;
        return !snapshot.allLegend().isEmpty() || (snapshot.badges() != null && !snapshot.badges().isEmpty());
    }

    static String render(AiChatPageSnapshot snapshot, String question, String uiConventions) {
        return switch (focus(question)) {
            case ROW -> row(snapshot, row(question), uiConventions);
            case COLORS -> colors(snapshot, uiConventions);
            case REVIEW -> review(snapshot);
            case SUMMARY -> summary(snapshot);
        };
    }

    /**
     * One row the question names: each column's text, what the page flagged in it, and the legend meaning of a
     * status the row shows. Falls back to the page summary when no table has that row.
     */
    static String row(AiChatPageSnapshot snapshot, int rowNo, String uiConventions) {
        StringBuilder reply = new StringBuilder();
        for (var table : list(snapshot.tables())) {
            var row = list(table.rows()).stream().filter(item -> item.no() != null && item.no() == rowNo).findFirst();
            if (row.isEmpty()) continue;
            List<String> columns = list(table.columns()).stream().map(AiChatPageSnapshot.Column::label).toList();
            List<String> cells = list(row.get().cells());
            if (!reply.isEmpty()) reply.append("\n\n");
            reply.append("第 ").append(rowNo).append(" 行");
            String label = AiChatPageSnapshot.rowLabel(cells);
            if (label != null && !label.isBlank()) reply.append(" ").append(label);
            if (table.title() != null && !table.title().isBlank()) reply.append(" (").append(table.title()).append(")");
            reply.append(":");
            for (int i = 0; i < cells.size(); i++) {
                String value = cells.get(i);
                if (value == null || value.isBlank()) continue;
                String column = i < columns.size() && !columns.get(i).isBlank() ? columns.get(i) : "第 " + (i + 1) + " 列";
                reply.append("\n- ").append(column).append(": ").append(value);
                for (var entry : list(table.legend())) {
                    if (entry.value() != null && !entry.value().isBlank() && value.contains(entry.value())) {
                        String colour = colorName(entry.color(), entry.tone());
                        reply.append(" (").append(colour == null ? "" : colour + " = ").append(entry.value());
                        if (entry.meaning() != null && !entry.meaning().isBlank()) reply.append(": ").append(entry.meaning());
                        reply.append(")");
                        break;
                    }
                }
            }
            for (var cell : list(table.flaggedCells())) {
                if (cell.rowNo() != null && cell.rowNo() == rowNo) reply.append("\n- 页面标记: ").append(flaggedLine(cell));
            }
        }
        if (reply.isEmpty()) return summary(snapshot);
        reply.append("\n\n以上是页面当前显示的这一行内容，具体以页面为准。");
        return reply.toString();
    }

    static String colors(AiChatPageSnapshot snapshot, String uiConventions) {
        List<String> lines = new ArrayList<>();
        var legend = snapshot.allLegend();
        boolean severalColumns = legend.stream().map(entry -> entry.column() == null ? "" : entry.column()).distinct().count() > 1;
        for (var entry : legend) {
            lines.add((severalColumns && entry.column() != null && !entry.column().isBlank() ? entry.column() + ": " : "")
                    + legendLine(entry));
        }
        List<String> badgeLines = new ArrayList<>();
        for (var badge : list(snapshot.badges())) {
            String color = colorName(badge.color(), badge.tone());
            if (color == null) continue;
            badgeLines.add(color + " = " + badge.label() + (badge.count() == null ? "" : " (" + badge.count() + ")"));
        }
        StringBuilder reply = new StringBuilder();
        if (lines.isEmpty() && badgeLines.isEmpty()) {
            reply.append("这个页面没有登记状态颜色的图例，我看不到这里每种颜色对应的状态。");
            if (uiConventions != null && !uiConventions.isBlank()) reply.append("\n\n").append(uiConventions);
            return reply.toString();
        }
        if (!lines.isEmpty()) {
            reply.append("页面上的状态颜色(颜色 = 状态 = 含义):");
            appendNumbered(reply, lines);
        }
        if (!badgeLines.isEmpty()) {
            if (!reply.isEmpty()) reply.append("\n\n");
            reply.append("页面上的徽章:");
            appendNumbered(reply, badgeLines);
        }
        reply.append("\n\n以上是页面当前显示的内容，具体以页面为准。");
        return reply.toString();
    }

    static String review(AiChatPageSnapshot snapshot) {
        List<String> lines = new ArrayList<>();
        for (var cell : snapshot.allFlagged()) lines.add(flaggedLine(cell));
        for (var field : list(snapshot.fields())) {
            String state = field.state() == null ? "NORMAL" : field.state();
            if ("NORMAL".equals(state)) continue;
            lines.add(field.label() + ": " + fieldState(state)
                    + (field.value() == null || field.value().isBlank() ? "" : "; 当前值 " + field.value())
                    + (field.message() == null || field.message().isBlank() ? "" : "; 原因: " + field.message())
                    + "; 建议: " + suggestion(state));
        }
        if (lines.isEmpty()) {
            return "页面上没有标出需要核对的值(没有黄框待核对、红框必填未填或错误提示)。"
                    + (snapshot.isEmpty() ? "" : "\n如果你觉得哪里不对，可以告诉我是哪一行、哪一列。");
        }
        StringBuilder reply = new StringBuilder("需要你核对的有 " + lines.size() + " 项:");
        appendNumbered(reply, lines);
        reply.append("\n\n核对无误后由你在页面上保存或提交。");
        return reply.toString();
    }

    static String summary(AiChatPageSnapshot snapshot) {
        StringBuilder reply = new StringBuilder();
        reply.append("当前页面").append(snapshot.title() == null ? "" : ": " + snapshot.title());
        for (var table : list(snapshot.tables())) {
            reply.append("\n- 表格").append(table.title() == null || table.title().isBlank() ? "" : " " + table.title()).append(":");
            if (table.totalRows() != null) reply.append(" 共 ").append(table.totalRows()).append(" 行");
            if (table.visibleRows() != null) reply.append("，当前显示 ").append(table.visibleRows()).append(" 行");
            if (table.selectedRows() != null && table.selectedRows() > 0) reply.append("，已勾选 ").append(table.selectedRows()).append(" 行");
            List<String> columns = list(table.columns()).stream().map(AiChatPageSnapshot.Column::label)
                    .filter(label -> !label.isBlank()).toList();
            if (!columns.isEmpty()) reply.append("\n  列: ").append(String.join("、", columns));
        }
        var legend = snapshot.allLegend();
        if (!legend.isEmpty()) {
            reply.append("\n- 状态颜色:");
            legend.stream().limit(LIMIT).forEach(entry -> reply.append("\n  ").append(legendLine(entry)));
            if (legend.size() > LIMIT) reply.append("\n  还有 ").append(legend.size() - LIMIT).append(" 项。");
        }
        long review = snapshot.allFlagged().size()
                + list(snapshot.fields()).stream().filter(field -> field.state() != null && !"NORMAL".equals(field.state())).count();
        if (review > 0) reply.append("\n- 需要核对: ").append(review).append(" 项(问我「有什么需要检查」可以逐条列出)");
        List<String> fields = list(snapshot.fields()).stream().filter(field -> field.value() != null && !field.value().isBlank())
                .limit(LIMIT).map(field -> field.label() + " = " + field.value()).toList();
        if (!fields.isEmpty()) reply.append("\n- 字段: ").append(String.join("; ", fields));
        for (var notice : list(snapshot.notices()).stream().limit(3).toList()) {
            reply.append("\n- 提示").append(notice.title() == null || notice.title().isBlank() ? "" : " " + notice.title())
                    .append(": ").append(notice.text());
        }
        if (snapshot.isEmpty()) reply.append("\n页面没有提供表格或字段内容。");
        return reply.toString();
    }

    static String legendLine(AiChatPageSnapshot.LegendEntry entry) {
        String color = colorName(entry.color(), entry.tone());
        StringBuilder line = new StringBuilder();
        line.append(color == null ? "(无颜色)" : color).append(" = ").append(entry.value());
        line.append(" = ").append(entry.meaning() == null || entry.meaning().isBlank() ? "页面没有写明含义" : entry.meaning());
        if (entry.count() != null) line.append(" (").append(entry.count()).append(" 行)");
        return line.toString();
    }

    static String flaggedLine(AiChatPageSnapshot.FlaggedCell cell) {
        StringBuilder line = new StringBuilder();
        if (cell.rowNo() != null) line.append("第 ").append(cell.rowNo()).append(" 行");
        if (cell.rowLabel() != null && !cell.rowLabel().isBlank()) line.append(line.isEmpty() ? "" : " ").append(cell.rowLabel());
        if (cell.column() != null && !cell.column().isBlank()) line.append(line.isEmpty() ? "" : " / ").append(cell.column());
        if (line.isEmpty()) line.append("页面标记的一项");
        line.append(": ").append(cellState(cell.state()));
        if (cell.value() != null) line.append("; 当前值 ").append(cell.value().isBlank() ? "(空)" : cell.value());
        if (cell.reason() != null && !cell.reason().isBlank()) line.append("; 原因: ").append(cell.reason());
        line.append("; 建议: ").append(suggestion(cell.state()));
        return line.toString();
    }

    private static void appendNumbered(StringBuilder reply, List<String> lines) {
        int index = 1;
        for (String line : lines.stream().limit(LIMIT).toList()) reply.append("\n").append(index++).append(". ").append(line);
        if (lines.size() > LIMIT) reply.append("\n还有 ").append(lines.size() - LIMIT).append(" 项。");
    }

    /** Colour name the page reported, else the shared tone's name; null when neither is known. */
    static String colorName(String name, String tone) {
        if (name != null && !name.isBlank()) return name;
        return tone == null ? null : TONE_COLORS.get(tone);
    }

    private static String cellState(String state) {
        return switch (state) {
            case "REVIEW" -> "黄框待核对";
            case "REQUIRED_EMPTY" -> "红框必填未填";
            case "ERROR" -> "有错误";
            case "WARNING" -> "有提示";
            default -> "整行被标出";
        };
    }

    private static String fieldState(String state) {
        return switch (state) {
            case "REQUIRED_EMPTY" -> "红框必填未填";
            case "AUTOFILLED" -> "黄框预填待核对";
            case "ERROR" -> "有错误";
            default -> "有提示";
        };
    }

    private static String suggestion(String state) {
        return switch (state) {
            case "REVIEW", "AUTOFILLED" -> "核对无误就保留，不对就改正";
            case "REQUIRED_EMPTY" -> "补填后再保存";
            case "ERROR" -> "按提示改正";
            case "WARNING" -> "看一下提示内容再决定";
            default -> "打开这一行看标记原因";
        };
    }

    private static <T> List<T> list(List<T> values) { return values == null ? List.of() : values; }
}
