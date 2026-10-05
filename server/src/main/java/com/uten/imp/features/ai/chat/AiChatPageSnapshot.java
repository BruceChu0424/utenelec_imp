package com.uten.imp.features.ai.chat;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonInclude;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * ADR-150 bounded snapshot of what the user currently sees on the top-most page: tables (visible
 * columns, first rows, status legend, flagged cells), fields, badges, notices and the page's closed
 * action set. Everything here is untrusted page data. It is validated and sanitized before it can
 * reach a model, never stored beyond the temporary job input, and never grants any authority.
 */
@JsonIgnoreProperties(ignoreUnknown = true)
@JsonInclude(JsonInclude.Include.NON_NULL)
public record AiChatPageSnapshot(Integer version, String title, List<Table> tables, List<Field> fields,
                                 List<Badge> badges, List<Notice> notices, List<PageAction> pageActions,
                                 String focusField, List<String> withheld) {
    public static final int MAX_BYTES = 24 * 1024;
    public static final int MAX_TABLES = 4, MAX_COLUMNS = 12, MAX_ROWS = 30, MAX_VALUE = 80;
    public static final int MAX_FIELDS = 60, MAX_LEGEND = 40, MAX_FLAGGED = 80, MAX_BADGES = 30;
    public static final int MAX_NOTICES = 10, MAX_ACTIONS = 16;
    public static final Set<String> FIELD_STATES = Set.of("NORMAL", "REQUIRED_EMPTY", "AUTOFILLED", "WARNING", "ERROR");
    public static final Set<String> CELL_STATES = Set.of("REVIEW", "REQUIRED_EMPTY", "WARNING", "ERROR", "FLAGGED");
    public static final Set<String> TONES = Set.of("neutral", "info", "success", "warning", "danger", "fuchsia", "violet", "accent");
    public static final Set<String> NOTICE_KINDS = Set.of("BANNER", "INLINE", "DIALOG");
    public static final Set<String> ACTION_KINDS = Set.of("VIEW", "FORM", "SAVE", "SUBMIT");
    private static final Pattern UUID_TEXT = Pattern.compile(
            "(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}");
    private static final Pattern URL_TEXT = Pattern.compile("(?i)(?:[a-z][a-z0-9+.-]{1,15}://|www\\.)\\S*");
    private static final Pattern ACTION_NAME = Pattern.compile("[a-z][A-Za-z0-9_]{1,47}");
    private static final Pattern PARAM_NAME = Pattern.compile("[a-z][A-Za-z0-9_]{0,31}");
    /**
     * Default-not-sent values (ADR-150): costs and margins, payroll vocabulary, credit limits and personal
     * identifiers/contact details. A matching column or field keeps its label and state; its value, message
     * and explanation stay in the application. Same list as the client (ai_page_snapshot.dart).
     */
    static final Pattern SENSITIVE_LABEL = Pattern.compile("(?i).*("
            + "成本|毛利|利润|进价|进货价|工资|薪|奖金|年终奖|提成|佣金|社保|公积金|应发|实发|扣减|扣款|扣除合计|扣除金额|个税|所得税"
            + "|加班费|津贴|补贴|绩效|信用额度|信用余额|授信|身份证|证件号|护照|银行卡|银行账号|银行帐号|开户账号|账户号码|卡号"
            + "|手机|电话|联系方式|邮箱|住址|家庭地址|户籍"
            + "|cost|margin|profit|purchase\\s*price|salary|payroll|wage|bonus|commission|deduction|gross\\s*pay|net\\s*pay|income\\s*tax"
            + "|credit\\s*limit|id\\s*(?:card|number)|passport|bank\\s*account|account\\s*number|phone|mobile|e-?mail"
            + "|home\\s*address).*");
    /** Credentials never leave the application in any form: such a field is dropped entirely. */
    static final Pattern CREDENTIAL_LABEL = Pattern.compile("(?i)(?:.*(密码|口令|验证码|校验码|动态码|密钥|私钥|令牌"
            + "|password|passcode|passwd|secret|api[\\s_-]*key|access[\\s_-]*key"
            + "|(?:access|refresh|auth|bearer|session|api)[\\s_-]*token).*|\\s*token\\s*)");
    /**
     * Routes whose page content is never read (ADR-150): payroll, HR and personal records and credentials.
     * On these pages only the question itself is answered.
     */
    static final List<String> CONTENT_WITHHELD_ROUTES = List.of("/payroll", "/hr", "/employee", "/profile",
            "/change-password");
    /**
     * ADR-153 protected pages: system administration (system settings, AI service settings, permissions,
     * audit logs, server status), page permissions, security and device receipts. Their content is never
     * read and no page action is ever proposed there (the client registers nothing on them either).
     */
    static final List<String> PROTECTED_ROUTES = List.of("/admin", "/page-permissions", "/security",
            "/settings/device-receipts");
    private static final ObjectMapper JSON = new ObjectMapper();

    /** True when the page at {@code route} is one whose content is never sent to a model (withheld or protected). */
    public static boolean contentWithheld(String route) {
        if (route == null) return false;
        return under(route, CONTENT_WITHHELD_ROUTES) || protectedPage(route);
    }

    /** ADR-153: a system administration or security page; no snapshot and no page action there. */
    public static boolean protectedPage(String route) {
        return route != null && under(route, PROTECTED_ROUTES);
    }

    private static boolean under(String route, List<String> prefixes) {
        String path = canonicalRoute(route);
        return prefixes.stream().anyMatch(prefix -> path.equals(prefix) || path.startsWith(prefix + "/"));
    }

    /**
     * ADR-153 revision: the route a protection decision is made on. Letter case, repeated and trailing slashes never
     * get a page past the withheld or protected lists ("/ADMIN/ai-settings", "//admin/ai-settings").
     */
    static String canonicalRoute(String route) {
        if (route == null) return "";
        String path = route.toLowerCase(java.util.Locale.ROOT).replaceAll("/{2,}", "/");
        return path.length() > 1 && path.endsWith("/") ? path.substring(0, path.length() - 1) : path;
    }

    /**
     * Sensitive and credential labels are matched on the label as a person reads it: compatibility forms folded,
     * spaces and invisible characters removed ("成 本", "Ｃｏｓｔ" are 成本 and cost).
     */
    static boolean sensitiveLabel(String label) {
        if (label == null) return false;
        String folded = labelKey(label);
        return SENSITIVE_LABEL.matcher(folded).matches() || CREDENTIAL_LABEL.matcher(folded).matches()
                || SENSITIVE_LABEL.matcher(label).matches() || CREDENTIAL_LABEL.matcher(label).matches();
    }

    static boolean credentialLabel(String label) {
        return label != null && (CREDENTIAL_LABEL.matcher(labelKey(label)).matches() || CREDENTIAL_LABEL.matcher(label).matches());
    }

    private static String labelKey(String label) {
        return java.text.Normalizer.normalize(label, java.text.Normalizer.Form.NFKC).replaceAll("[\\s\\p{Cf}]+", "");
    }

    @JsonIgnoreProperties(ignoreUnknown = true) @JsonInclude(JsonInclude.Include.NON_NULL)
    public record Table(String title, Integer totalRows, Integer visibleRows, Integer selectedRows,
                        List<Column> columns, List<Row> rows, List<LegendEntry> legend,
                        List<FlaggedCell> flaggedCells, Boolean truncated) {}
    @JsonIgnoreProperties(ignoreUnknown = true) @JsonInclude(JsonInclude.Include.NON_NULL)
    public record Column(String label, String info, Boolean sensitive) {}
    @JsonIgnoreProperties(ignoreUnknown = true) @JsonInclude(JsonInclude.Include.NON_NULL)
    public record Row(Integer no, List<String> cells, Boolean selected, Boolean flagged) {}
    @JsonIgnoreProperties(ignoreUnknown = true) @JsonInclude(JsonInclude.Include.NON_NULL)
    public record LegendEntry(String column, String value, String color, String tone, String meaning, Integer count) {}
    @JsonIgnoreProperties(ignoreUnknown = true) @JsonInclude(JsonInclude.Include.NON_NULL)
    public record FlaggedCell(Integer rowNo, String rowLabel, String column, String value, String state, String reason) {}
    @JsonIgnoreProperties(ignoreUnknown = true) @JsonInclude(JsonInclude.Include.NON_NULL)
    public record Field(String label, String value, String state, Boolean required, String message, String info,
                        Boolean sensitive) {}
    @JsonIgnoreProperties(ignoreUnknown = true) @JsonInclude(JsonInclude.Include.NON_NULL)
    public record Badge(String label, String tone, String color, Integer count) {}
    @JsonIgnoreProperties(ignoreUnknown = true) @JsonInclude(JsonInclude.Include.NON_NULL)
    public record Notice(String kind, String title, String text) {}
    @JsonIgnoreProperties(ignoreUnknown = true) @JsonInclude(JsonInclude.Include.NON_NULL)
    public record PageAction(String name, String title, String kind, String risk, Map<String, Object> params, Integer table) {
        public PageAction(String name, String title, String kind, String risk, Map<String, Object> params) {
            this(name, title, kind, risk, params, null);
        }
    }

    /**
     * Returns a sanitized copy or throws 422. Structural limits, control characters and identifier-like
     * labels (UUID/URL) are rejected; UUIDs and URLs inside values are replaced; sensitive values are withheld.
     */
    public AiChatPageSnapshot sanitized() {
        if (version != null && version != 1) throw invalid();
        Set<String> withheldLabels = new LinkedHashSet<>();
        if (withheld != null) {
            if (withheld.size() > 30) throw invalid();
            for (String label : withheld) withheldLabels.add(label(label, 40, false));
        }
        List<Table> cleanTables = new ArrayList<>();
        for (Table table : bounded(tables, MAX_TABLES)) cleanTables.add(table(table, withheldLabels));
        List<Field> cleanFields = new ArrayList<>();
        for (Field field : bounded(fields, MAX_FIELDS)) {
            if (field == null) throw invalid();
            String fieldLabel = label(field.label(), 40, false);
            String state = field.state() == null ? "NORMAL" : field.state();
            if (!FIELD_STATES.contains(state)) throw invalid();
            if (credentialLabel(fieldLabel)) continue;
            // A message or explanation can quote the value ("超出信用额度 12,000"), so all three stay local.
            boolean secret = Boolean.TRUE.equals(field.sensitive()) || sensitiveLabel(fieldLabel);
            if (secret) withheldLabels.add(fieldLabel);
            cleanFields.add(new Field(fieldLabel, secret ? null : value(field.value(), MAX_VALUE), state,
                    Boolean.TRUE.equals(field.required()) ? Boolean.TRUE : null, secret ? null : value(field.message(), 200),
                    secret ? null : value(field.info(), 200), secret ? Boolean.TRUE : null));
        }
        List<Badge> cleanBadges = new ArrayList<>();
        for (Badge badge : bounded(badges, MAX_BADGES)) {
            if (badge == null) throw invalid();
            cleanBadges.add(new Badge(label(badge.label(), 40, false), tone(badge.tone()), color(badge.color()),
                    count(badge.count())));
        }
        List<Notice> cleanNotices = new ArrayList<>();
        for (Notice notice : bounded(notices, MAX_NOTICES)) {
            if (notice == null || !NOTICE_KINDS.contains(notice.kind())) throw invalid();
            String text = multiline(notice.text(), 600);
            if (text == null || text.isBlank()) throw invalid();
            cleanNotices.add(new Notice(notice.kind(), value(notice.title(), 80), text));
        }
        List<PageAction> cleanActions = new ArrayList<>();
        Set<String> names = new LinkedHashSet<>();
        for (PageAction action : bounded(pageActions, MAX_ACTIONS)) {
            PageAction clean = action(action, cleanTables.size());
            if (!names.add(clean.name())) throw invalid();
            cleanActions.add(clean);
        }
        // Bounded output, so a sanitized snapshot sanitizes to itself (the job service validates twice).
        AiChatPageSnapshot result = new AiChatPageSnapshot(1, value(title, 80), List.copyOf(cleanTables),
                List.copyOf(cleanFields), List.copyOf(cleanBadges), List.copyOf(cleanNotices), List.copyOf(cleanActions),
                focusField == null ? null : label(focusField, 40, false),
                withheldLabels.stream().limit(30).toList());
        if (result.bytes() > MAX_BYTES) throw invalid();
        return result;
    }

    public boolean isEmpty() {
        return empty(tables) && empty(fields) && empty(badges) && empty(notices) && empty(pageActions);
    }

    public int bytes() {
        try { return JSON.writeValueAsBytes(this).length; }
        catch (JsonProcessingException impossible) { throw invalid(); }
    }

    /** Compact model view: same data, no nulls, action schemas as declared. */
    public Map<String, Object> modelView() {
        Map<String, Object> view = new LinkedHashMap<>();
        if (title != null) view.put("pageTitle", title);
        if (!empty(tables)) view.put("tables", tables);
        if (!empty(fields)) view.put("fields", fields);
        if (!empty(badges)) view.put("badges", badges);
        if (!empty(notices)) view.put("notices", notices);
        if (!empty(pageActions)) view.put("pageActions", pageActions.stream().map(action -> {
            Map<String, Object> entry = new LinkedHashMap<>();
            entry.put("name", action.name());
            entry.put("title", action.title());
            entry.put("kind", action.kind());
            entry.put("params", action.params());
            // Row parameters count the screen rows of this table (1-based position in tables[]).
            if (action.table() != null) entry.put("rowsOfTable", action.table());
            return entry;
        }).toList());
        if (focusField != null) view.put("focusField", focusField);
        if (!empty(withheld)) view.put("withheldSensitiveValues", withheld);
        return view;
    }

    /** All visible text and numbers, used by the answer guard as evidence. */
    public String evidenceText() {
        try { return JSON.writeValueAsString(this); }
        catch (JsonProcessingException impossible) { throw invalid(); }
    }

    public List<LegendEntry> allLegend() {
        List<LegendEntry> all = new ArrayList<>();
        for (Table table : nonNull(tables)) all.addAll(nonNull(table.legend()));
        return all;
    }

    public List<FlaggedCell> allFlagged() {
        List<FlaggedCell> all = new ArrayList<>();
        for (Table table : nonNull(tables)) all.addAll(nonNull(table.flaggedCells()));
        return all;
    }

    public java.util.Optional<PageAction> action(String name) {
        return nonNull(pageActions).stream().filter(action -> action.name().equals(name)).findFirst();
    }

    private static Table table(Table table, Set<String> withheldLabels) {
        if (table == null) throw invalid();
        List<Column> columns = new ArrayList<>();
        Set<Integer> secretColumns = new LinkedHashSet<>();
        Set<String> secretLabels = new LinkedHashSet<>();
        int index = 0;
        for (Column column : bounded(table.columns(), MAX_COLUMNS)) {
            if (column == null) throw invalid();
            String columnLabel = label(column.label(), 40, true);
            boolean secret = Boolean.TRUE.equals(column.sensitive()) || sensitiveLabel(columnLabel);
            if (secret) {
                secretColumns.add(index);
                secretLabels.add(columnLabel);
                if (!columnLabel.isEmpty()) withheldLabels.add(columnLabel);
            }
            columns.add(new Column(columnLabel, secret ? null : value(column.info(), 200), secret ? Boolean.TRUE : null));
            index++;
        }
        List<Row> rows = new ArrayList<>();
        Map<Integer, String> rowLabels = new LinkedHashMap<>();
        for (Row row : bounded(table.rows(), MAX_ROWS)) {
            if (row == null || row.cells() == null || row.cells().size() > columns.size()) throw invalid();
            List<String> cells = new ArrayList<>();
            for (int i = 0; i < row.cells().size(); i++) {
                cells.add(secretColumns.contains(i) ? "" : nullToEmpty(value(row.cells().get(i), MAX_VALUE)));
            }
            Integer no = positive(row.no());
            if (no != null) rowLabels.putIfAbsent(no, rowLabel(cells));
            rows.add(new Row(no, List.copyOf(cells), Boolean.TRUE.equals(row.selected()) ? Boolean.TRUE : null,
                    Boolean.TRUE.equals(row.flagged()) ? Boolean.TRUE : null));
        }
        List<LegendEntry> legend = new ArrayList<>();
        for (LegendEntry entry : bounded(table.legend(), MAX_LEGEND)) {
            if (entry == null) throw invalid();
            String column = label(entry.column(), 40, true);
            boolean secret = secretLabels.contains(column) || sensitiveLabel(column);
            if (secret) continue;
            String entryValue = value(entry.value(), MAX_VALUE);
            if (entryValue == null || entryValue.isBlank()) throw invalid();
            legend.add(new LegendEntry(column, entryValue, color(entry.color()), tone(entry.tone()),
                    value(entry.meaning(), 120), count(entry.count())));
        }
        List<FlaggedCell> flagged = new ArrayList<>();
        for (FlaggedCell cell : bounded(table.flaggedCells(), MAX_FLAGGED)) {
            if (cell == null || cell.state() == null || !CELL_STATES.contains(cell.state())) throw invalid();
            String column = cell.column() == null || cell.column().isBlank() ? null : label(cell.column(), 40, true);
            if (credentialLabel(column)) continue;
            boolean secret = column != null && (secretLabels.contains(column) || sensitiveLabel(column));
            Integer rowNo = positive(cell.rowNo());
            // The row text is the server's own (sensitive cells already blank) whenever the row is in the
            // sample; a client label is only kept for a table without withheld columns.
            String label = rowNo != null && rowLabels.containsKey(rowNo) ? rowLabels.get(rowNo)
                    : secretColumns.isEmpty() ? value(cell.rowLabel(), MAX_VALUE) : null;
            flagged.add(new FlaggedCell(rowNo, label == null || label.isEmpty() ? null : label, column,
                    secret ? null : value(cell.value(), MAX_VALUE), cell.state(), secret ? null : value(cell.reason(), 200)));
        }
        Integer total = count(table.totalRows());
        Integer visible = count(table.visibleRows());
        Integer selected = count(table.selectedRows());
        return new Table(value(table.title(), 80), total, visible, selected, List.copyOf(columns), List.copyOf(rows),
                List.copyOf(legend), List.copyOf(flagged), Boolean.TRUE.equals(table.truncated()) ? Boolean.TRUE : null);
    }

    /** Text naming a row on cards and in flagged items: its first two non-blank cells. */
    static String rowLabel(List<String> cells) {
        return String.join(" ", cells.stream().filter(cell -> cell != null && !cell.isBlank()).limit(2).toList());
    }

    private static PageAction action(PageAction action, int tableCount) {
        if (action == null || action.name() == null || !ACTION_NAME.matcher(action.name()).matches()
                || !ACTION_KINDS.contains(action.kind())
                || (action.risk() != null && !Set.of("LOW", "MEDIUM", "HIGH").contains(action.risk()))
                || (action.table() != null && (action.table() < 1 || action.table() > tableCount))) throw invalid();
        String actionTitle = label(action.title(), 40, false);
        Map<String, Object> params = params(action.params());
        return new PageAction(action.name(), actionTitle, action.kind(), effectiveRisk(action.kind(), action.risk()), params,
                action.table());
    }

    /** Kind decides the minimum risk; a page may only raise it. */
    static String effectiveRisk(String kind, String declared) {
        int floor = switch (kind) { case "SAVE" -> 1; case "SUBMIT" -> 2; default -> 0; };
        int stated = declared == null ? 0 : List.of("LOW", "MEDIUM", "HIGH").indexOf(declared);
        return List.of("LOW", "MEDIUM", "HIGH").get(Math.max(floor, stated));
    }

    /** Bounded closed object with scalar properties; every property carries a display title. */
    private static Map<String, Object> params(Map<String, Object> schema) {
        if (schema == null) return Map.of("type", "object", "additionalProperties", false, "properties", Map.of(),
                "required", List.of());
        if (!"object".equals(schema.get("type")) || !Boolean.FALSE.equals(schema.get("additionalProperties"))
                || !(schema.get("properties") instanceof Map<?, ?> properties) || properties.size() > 6
                || !(schema.get("required") instanceof List<?> required)) throw invalid();
        Map<String, Object> cleanProperties = new LinkedHashMap<>();
        for (var entry : properties.entrySet()) {
            if (!(entry.getKey() instanceof String name) || !PARAM_NAME.matcher(name).matches()
                    || !(entry.getValue() instanceof Map<?, ?> property)) throw invalid();
            cleanProperties.put(name, property(property));
        }
        List<String> cleanRequired = new ArrayList<>();
        for (Object name : required) {
            if (!(name instanceof String text) || !cleanProperties.containsKey(text) || cleanRequired.contains(text)) throw invalid();
            cleanRequired.add(text);
        }
        if (cleanProperties.size() - cleanRequired.size() > 3) throw invalid();
        // Declared order is kept: it is the order of the lines on the confirmation card.
        Map<String, Object> clean = new LinkedHashMap<>();
        clean.put("type", "object");
        clean.put("additionalProperties", false);
        clean.put("properties", java.util.Collections.unmodifiableMap(cleanProperties));
        clean.put("required", List.copyOf(cleanRequired));
        return java.util.Collections.unmodifiableMap(clean);
    }

    private static Map<String, Object> property(Map<?, ?> property) {
        Set<String> allowed = Set.of("type", "title", "description", "maxLength", "minLength", "minimum", "maximum", "enum");
        for (Object key : property.keySet()) if (!(key instanceof String text) || !allowed.contains(text)) throw invalid();
        if (!(property.get("type") instanceof String type) || !Set.of("string", "integer", "number", "boolean").contains(type))
            throw invalid();
        Map<String, Object> clean = new LinkedHashMap<>();
        clean.put("type", type);
        clean.put("title", label(property.get("title") instanceof String text ? text : null, 20, false));
        if (property.get("description") instanceof String description) clean.put("description", value(description, 120));
        else if (property.containsKey("description")) throw invalid();
        if ("string".equals(type)) {
            int max = property.get("maxLength") instanceof Number number ? number.intValue() : MAX_VALUE;
            if (max < 1 || max > 200) throw invalid();
            clean.put("maxLength", max);
            if (property.get("minLength") instanceof Number min) {
                if (min.intValue() < 0 || min.intValue() > max) throw invalid();
                clean.put("minLength", min.intValue());
            }
        } else if (property.containsKey("maxLength") || property.containsKey("minLength")) throw invalid();
        if ("integer".equals(type) || "number".equals(type)) {
            for (String key : List.of("minimum", "maximum")) {
                if (property.get(key) instanceof Number number) clean.put(key, number);
                else if (property.containsKey(key)) throw invalid();
            }
        } else if (property.containsKey("minimum") || property.containsKey("maximum")) throw invalid();
        if (property.containsKey("enum")) {
            if (!(property.get("enum") instanceof List<?> options) || options.isEmpty() || options.size() > 60) throw invalid();
            List<Object> cleanOptions = new ArrayList<>();
            for (Object option : options) {
                if ("string".equals(type) && option instanceof String text) cleanOptions.add(label(text, 60, false));
                else if (("integer".equals(type) || "number".equals(type)) && option instanceof Number number) cleanOptions.add(number);
                else throw invalid();
            }
            clean.put("enum", List.copyOf(cleanOptions));
        }
        return Map.copyOf(clean);
    }

    private static <T> List<T> bounded(List<T> values, int max) {
        if (values == null) return List.of();
        if (values.size() > max) throw invalid();
        return values;
    }

    /** Labels name what the user sees. They may not be identifiers, links or control text. */
    private static String label(String raw, int max, boolean allowEmpty) {
        if (raw == null) { if (allowEmpty) return ""; throw invalid(); }
        String text = stripFormat(raw);
        if (text.codePoints().anyMatch(Character::isISOControl)) throw invalid();
        text = text.strip();
        if ((!allowEmpty && text.isEmpty()) || text.length() > max || UUID_TEXT.matcher(text).find()
                || URL_TEXT.matcher(text).find()) throw invalid();
        return text;
    }

    /** Single-line display value; UUIDs and links are replaced, never forwarded. */
    private static String value(String raw, int max) {
        if (raw == null) return null;
        String text = stripFormat(raw).replace('\t', ' ').replace('\r', ' ').replace('\n', ' ');
        if (text.codePoints().anyMatch(Character::isISOControl)) throw invalid();
        text = URL_TEXT.matcher(UUID_TEXT.matcher(text).replaceAll("[编号]")).replaceAll("[链接]").strip();
        if (text.length() > max) throw invalid();
        return text;
    }

    private static String multiline(String raw, int max) {
        if (raw == null) return null;
        String text = stripFormat(raw).replace("\r\n", "\n").replace('\r', '\n').replace('\t', ' ');
        if (text.codePoints().anyMatch(c -> Character.isISOControl(c) && c != '\n')) throw invalid();
        text = URL_TEXT.matcher(UUID_TEXT.matcher(text).replaceAll("[编号]")).replaceAll("[链接]").strip();
        if (text.length() > max) throw invalid();
        return text;
    }

    private static String stripFormat(String value) { return value.replaceAll("\\p{Cf}+", ""); }
    private static String tone(String value) {
        if (value == null || value.isBlank()) return null;
        if (!TONES.contains(value)) throw invalid();
        return value;
    }
    private static String color(String value) {
        if (value == null || value.isBlank()) return null;
        return label(value, 8, false);
    }
    private static Integer count(Integer value) {
        if (value == null) return null;
        if (value < 0 || value > 10_000_000) throw invalid();
        return value;
    }
    private static Integer positive(Integer value) {
        if (value == null) return null;
        if (value < 1 || value > 1_000_000) throw invalid();
        return value;
    }
    private static String nullToEmpty(String value) { return value == null ? "" : value; }
    private static <T> List<T> nonNull(List<T> values) { return values == null ? List.of() : values; }
    private static boolean empty(List<?> values) { return values == null || values.isEmpty(); }
    static ApiException invalid() {
        return new ApiException(ErrorCode.VALIDATION_FAILED,
                "当前页面内容超出 AI 可读取的范围，请关闭页面感知后再问，或稍后重试。");
    }
}
