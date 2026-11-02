package com.uten.imp.features.history;

import static com.uten.imp.common.history.RecordHistory.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.application.port.CompanyFileHistoryAccessPort;
import com.uten.imp.security.AuthUser;
import com.uten.imp.security.SecurityContextCurrentUser;
import java.time.*;
import java.util.*;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/** Public projections of retained facts. Filtering and pagination follow authorization. */
@Service
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class ScopedRecordHistoryService {
    private final JdbcTemplate jdbc;
    private final ObjectMapper mapper;
    private final SecurityContextCurrentUser currentUser;
    private final CompanyFileHistoryAccessPort files;

    public enum Area {
        COMPANY_FILES("company-files"), PERMISSIONS("permissions");
        final String entity;
        Area(String entity) { this.entity = entity; }
    }
    public record Filters(String entityType, UUID recordId, Long cursor, String action,
            String actorKeyword, String keyword, String dateFrom, String dateTo,
            String sourceType, String summaryKeyword, int size) {}
    private record Fact(long id, String table, UUID record, JsonNode before, JsonNode after,
            String action, UUID actor, String actorName, OffsetDateTime time, String source) {}

    private static final Map<String,String> FIELDS = Map.ofEntries(
            Map.entry("name","名称"), Map.entry("description","说明"), Map.entry("parent_id","所在文件夹"),
            Map.entry("deleted","回收站状态"), Map.entry("pending","待上传"), Map.entry("size_bytes","文件大小（字节）"),
            Map.entry("content_type","文件类型"), Map.entry("position","排列顺序"),
            Map.entry("inherit_permissions","继承上级权限"), Map.entry("password_protected","密码保护"),
            Map.entry("password_revision","密码修改"), Map.entry("access_rule","访问规则"));

    public Page search(Area area, Filters filters) {
        authorize(area);
        validate(filters);
        int size = Math.clamp(filters.size(), 1, 100);
        long cursor = filters.cursor() == null ? Long.MAX_VALUE : filters.cursor();
        List<Entry> visible = new ArrayList<>(size + 1);
        // Scan in bounded batches. A hidden fact never consumes a visible page slot,
        // contributes a total, or supplies a continuation cursor.
        while (visible.size() <= size) {
            List<Fact> batch = query(area, filters.recordId(), cursor, 200, filters.dateFrom(), filters.dateTo());
            if (batch.isEmpty()) break;
            Set<UUID> readable = readable(area, batch, false);
            Set<UUID> manageable = readable(area, batch, true);
            for (Fact fact : batch) {
                cursor = fact.id();
                if (!authorizedFact(area, fact, readable, manageable)) continue;
                Entry entry = project(area, fact, false, manageable.contains(fact.record()));
                if (matches(entry, filters)) visible.add(entry);
                if (visible.size() > size) break;
            }
            if (batch.size() < 200) break;
        }
        boolean more = visible.size() > size;
        List<Entry> entries = List.copyOf(visible.subList(0, Math.min(size, visible.size())));
        return new Page(entries, more ? entries.getLast().id() : null);
    }

    public Entry detail(Area area, long id) {
        authorize(area);
        List<Fact> facts = jdbc.query(select() + " WHERE h.entity_type=? AND h.id=?", this::fact, area.entity, id);
        if (facts.isEmpty()) throw missing();
        Fact fact = facts.getFirst();
        if (!authorizedFact(area, fact, readable(area, facts, false), readable(area, facts, true))) throw missing();
        return project(area, fact, true, area == Area.PERMISSIONS || files.readableHistoryNodes(List.of(fact.record()),true).contains(fact.record()));
    }

    private void authorize(Area area) {
        AuthUser user = currentUser.get().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        if (!canRead(area,user)) throw new ApiException(ErrorCode.FORBIDDEN);
    }
    public static boolean canRead(Area area, AuthUser user) {
        return !user.isVisitor() && (area == Area.PERMISSIONS
                ? user.isSuperAdmin() && user.getPermissions().contains("authorization:manage")
                : user.isSuperAdmin() || user.getPermissions().contains("company_file:view"));
    }

    private List<Fact> query(Area area, UUID record, long cursor, int limit, String from, String to) {
        StringBuilder sql = new StringBuilder(select()).append(" WHERE h.entity_type=? AND h.id<?");
        List<Object> args = new ArrayList<>(List.of(area.entity, cursor));
        if (record != null) { sql.append(" AND h.record_id=?"); args.add(record); }
        if (present(from)) { sql.append(" AND h.recorded_at>=?"); args.add(boundary(from, false)); }
        if (present(to)) { sql.append(" AND h.recorded_at<?"); args.add(boundary(to, true)); }
        sql.append(" ORDER BY h.id DESC LIMIT ?"); args.add(limit);
        return jdbc.query(sql.toString(), this::fact, args.toArray());
    }
    private String select() {
        return "SELECT h.id,h.source_table,h.record_id,h.before_row::text,h.after_row::text,h.action,h.actor_id,"
                + "CASE WHEN u.id IS NOT NULL THEN coalesce(e.full_name||' ('||e.code||')','管理员') WHEN h.actor_id IS NOT NULL THEN '已停用账号' ELSE '系统' END actor_name,h.recorded_at,h.source_key "
                + "FROM master_record_versions h LEFT JOIN users u ON u.id=h.actor_id LEFT JOIN employees e ON e.id=u.employee_id";
    }
    private Fact fact(java.sql.ResultSet row, int index) throws java.sql.SQLException {
        return new Fact(row.getLong(1), row.getString(2), row.getObject(3,UUID.class), json(row.getString(4)),
                json(row.getString(5)), row.getString(6), row.getObject(7,UUID.class), row.getString(8),
                row.getObject(9,OffsetDateTime.class), row.getString(10));
    }
    private JsonNode json(String value) {
        if (value == null) return mapper.createObjectNode();
        try { return mapper.readTree(value); }
        catch (java.io.IOException ex) { throw new IllegalStateException("Invalid retained history", ex); }
    }
    private Set<UUID> readable(Area area, List<Fact> facts, boolean manage) {
        if (area == Area.PERMISSIONS) return Set.of();
        Set<UUID> ids = new HashSet<>();
        for (Fact fact : facts) {
            ids.add(fact.record());
            for (JsonNode snapshot : List.of(fact.before(),fact.after())) {
                UUID parent = uuid(snapshot.path("parent_id").asText(null));
                if (parent != null && !manage) ids.add(parent);
            }
        }
        return files.readableHistoryNodes(ids, manage);
    }
    private boolean authorizedFact(Area area, Fact fact, Set<UUID> readable, Set<UUID> manageable) {
        if (area == Area.PERMISSIONS) return true;
        if (!readable.contains(fact.record())) return false;
        // Old location names are data too. A move must not disclose a hidden old/new directory.
        for (JsonNode snapshot : List.of(fact.before(),fact.after())) {
            UUID parent = uuid(snapshot.path("parent_id").asText(null));
            if (parent != null && !readable.contains(parent)) return false;
        }
        return !source(fact).equals("ACCESS") && !source(fact).equals("PASSWORD")
                || manageable.contains(fact.record());
    }
    private Entry project(Area area, Fact fact, boolean detail, boolean canManage) {
        JsonNode snapshot = fact.after().isEmpty() ? fact.before() : fact.after();
        String entity = area == Area.COMPANY_FILES ? (snapshot.path("kind").asText().equals("FOLDER") ? "folders" : "files")
                : switch (fact.table()) { case "users" -> "users"; case "departments" -> "departments";
                    case "permission_templates" -> "templates"; default -> fact.source().equals("permission_baseline_change") ? "baseline" : "configuration"; };
        String name = area == Area.COMPANY_FILES ? snapshot.path("name").asText("资料") : targetName(fact, entity);
        List<Change> changes = area == Area.COMPANY_FILES ? fileChanges(fact,canManage,detail) : detail ? permissionChanges(fact) : List.of();
        String summary = fact.source().equals("BASELINE") ? "历史启用时的资料快照"
                : String.join("、", changes.stream().map(Change::label).distinct().toList());
        if (area == Area.PERMISSIONS) summary = permissionSummary(fact);
        else if (summary.isBlank()) summary = actionName(fact.source());
        String source = area == Area.COMPANY_FILES ? source(fact)
                : fact.source().contains("data_scope") ? "SCOPE" : fact.source().contains("template") ? "TEMPLATE" : "ACCESS";
        return new Entry(Long.toString(fact.id()), fact.record(), name, fact.action(), fact.actorName(), fact.time(),
                "", 1, detail ? changes : List.of(), false, false,
                detail ? (area == Area.COMPANY_FILES ? "历史仅供核对；还原已删除资料请使用资料库回收站。" : "历史仅供核对；调整权限请通过当前授权流程保存。") : null,
                entity, source, "", null, "", summary, fact.actor(), name);
    }
    private List<Change> fileChanges(Fact fact, boolean canManage, boolean detail) {
        List<Change> changes = new ArrayList<>();
        for (String field : FIELDS.keySet().stream().sorted().toList()) {
            if (Objects.equals(fact.before().get(field), fact.after().get(field))) continue;
            // Inheritance/password details are authorization metadata even when captured
            // together with a name/description change. Their separate events are gated above.
            if (Set.of("inherit_permissions","password_protected","password_revision","access_rule").contains(field)
                    && !canManage) continue;
            changes.add(new Change(fact.table(),fact.record(),field,FIELDS.get(field),
                    detail ? display(field,fact.before().get(field)) : "",detail ? display(field,fact.after().get(field)) : ""));
        }
        return List.copyOf(changes);
    }
    private String display(String field, JsonNode value) {
        if (value == null || value.isNull()) return "";
        if (field.equals("password_revision")) return "第 " + value.asText() + " 次设置";
        if (field.equals("parent_id")) {
            UUID id = uuid(value.asText());
            return id == null ? "根目录" : jdbc.queryForObject("SELECT name FROM company_file_nodes WHERE id=?",String.class,id);
        }
        if (field.equals("access_rule")) {
            String subject = value.path("subject_type").asText();
            UUID id = uuid(value.path("subject_id").asText());
            String label = subject.equals("ALL") ? "所有人" : lookup(subject.equals("USER")
                    ? "SELECT coalesce(e.full_name,'管理员') FROM users u LEFT JOIN employees e ON e.id=u.employee_id WHERE u.id=?"
                    : "SELECT name FROM departments WHERE id=?",id,"已移除成员");
            return label + " · " + (value.path("effect").asText().equals("DENY") ? "拒绝" : "允许") + " · "
                    + String.join("、", values(value.path("actions")).stream().map(ScopedRecordHistoryService::actionName).toList());
        }
        return value.isBoolean() ? (value.asBoolean() ? "是" : "否") : value.asText();
    }
    private List<Change> permissionChanges(Fact fact) {
        List<Change> result = new ArrayList<>();
        boolean scope = fact.source().equals("user_data_scope_change");
        Map<String,String> catalog = new HashMap<>();
        jdbc.query("SELECT code,name FROM permissions", (org.springframework.jdbc.core.RowCallbackHandler) row -> catalog.put(row.getString(1),row.getString(2)));

        for (String direction : List.of("added","removed")) for (String code : values(fact.after().path(direction))) {
            if (fact.source().equals("permission_configuration_import")) {
                String target = lookup("SELECT coalesce(e.full_name,'管理员') FROM users u LEFT JOIN employees e ON e.id=u.employee_id WHERE u.id=?",uuid(code),"已移除账号");
                result.add(new Change(fact.table(),fact.record(),code,"导入配置 · " + target,"未记录","本次导入配置"));
                continue;
            }
            if (fact.source().equals("permission_template_unbind")) {
                String template = lookup("SELECT name FROM permission_templates WHERE id=?",uuid(code),"历史模板");
                result.add(new Change(fact.table(),fact.record(),code,"模板关联 · " + template,"已关联","已解除（保留当前配置）"));
                continue;
            }
            String label = scope ? lookup("SELECT full_name FROM employees WHERE id=?",uuid(code),"已移除员工")
                    : permissionName(code,catalog);
            boolean added = direction.equals("added");
            result.add(new Change(fact.table(),fact.record(),code,label,added ? "未配置" : "已配置",added ? "已配置" : "未配置"));
        }
        for (String key : List.of("name","description","scope","surfaceKey","templateName","templateId","userCount","departmentCount")) {
            if (fact.after().hasNonNull(key)) result.add(new Change(fact.table(),fact.record(),key,
                    switch(key) { case "name" -> "本次模板名称"; case "description" -> "本次模板说明"; case "templateId" -> "模板关联"; case "userCount" -> "导入员工数"; case "departmentCount" -> "导入部门数"; case "scope" -> "数据范围"; case "surfaceKey" -> "权限页面"; default -> "权限模板"; },
                    "未记录",key.equals("templateId") ? lookup("SELECT name FROM permission_templates WHERE id=?",uuid(fact.after().path(key).asText()),"未绑定模板") : fact.after().path(key).asText()));
        }
        return List.copyOf(result);
    }
    private static String permissionSummary(Fact fact) {
        int added = fact.after().path("added").size(), removed = fact.after().path("removed").size();
        if (fact.source().equals("permission_template_unbind")) return "解除模板关联，保留当前配置";
        if (fact.source().equals("permission_configuration_import")) return "导入权限配置，涉及 " + added + " 个账号";
        String action = fact.source().equals("user_data_scope_change") ? "调整数据范围" : actionName(fact.source());
        return action + (added + removed == 0 ? "" : "：新增或确认 " + added + " 项，移除 " + removed + " 项");
    }
    private String permissionName(String code, Map<String,String> catalog) {
        // Keep grant/revoke semantics and unknown historical codes intact.
        String bare = code.replaceFirst("^(confirm_)?(grant:|revoke:)", "");
        return (code.startsWith("confirm_") ? "重新确认 · " : "") + (code.contains("revoke:") ? "禁止 · " : code.contains("grant:") ? "授予 · " : "")
                + catalog.getOrDefault(bare,bare) + " (" + bare + ")";
    }
    private String targetName(Fact fact, String entity) {
        return switch(entity) {
            case "users" -> lookup("SELECT coalesce(e.full_name||' ('||e.code||')','管理员') FROM users u LEFT JOIN employees e ON e.id=u.employee_id WHERE u.id=?",fact.record(),"已移除账号");
            case "departments" -> lookup("SELECT name FROM departments WHERE id=?",fact.record(),"已移除部门");
            case "templates" -> fact.after().path("name").asText("权限模板");
            case "baseline" -> "全员基础包";
            default -> "权限配置";
        };
    }
    private String lookup(String sql, UUID id, String fallback) {
        if (id == null) return fallback;
        List<String> values = jdbc.queryForList(sql,String.class,id);
        return values.isEmpty() ? fallback : Objects.toString(values.getFirst(),fallback);
    }
    private static String source(Fact fact) {
        if (fact.table().equals("company_file_acl") || changed(fact,"inherit_permissions")) return "ACCESS";
        if (changed(fact,"password_protected") || changed(fact,"password_revision")) return "PASSWORD";
        if (changed(fact,"position")) return "ORDER";
        return "RECORD";
    }
    private static boolean changed(Fact f,String key) {
        return !f.before().isEmpty() && !f.after().isEmpty() && !Objects.equals(f.before().get(key),f.after().get(key));
    }
    private static boolean matches(Entry e, Filters f) {
        return (!present(f.entityType()) || f.entityType().equals("all") || f.entityType().equals(e.entityType()))
                && (!present(f.action()) || f.action().equals(e.action()))
                && (!present(f.sourceType()) || f.sourceType().equals(e.sourceType()))
                && KeywordSearch.matches(f.actorKeyword(),e.actorName())
                && KeywordSearch.matches(f.keyword(),e.recordName()+" "+e.summary())
                && KeywordSearch.matches(f.summaryKeyword(),e.summary());
    }
    private static void validate(Filters f) {
        for (String term : Arrays.asList(f.actorKeyword(),f.keyword(),f.summaryKeyword()))
            if (term != null && term.length()>180) throw new ApiException(ErrorCode.VALIDATION_FAILED,"搜索内容最多 180 个字符");
        OffsetDateTime from = boundary(f.dateFrom(),false), to = boundary(f.dateTo(),true);
        if (from != null && to != null && !from.isBefore(to)) throw new ApiException(ErrorCode.VALIDATION_FAILED,"日期范围无效");
    }
    private static OffsetDateTime boundary(String value, boolean end) {
        if (!present(value)) return null;
        try { return LocalDate.parse(value).plusDays(end ? 1 : 0).atStartOfDay(ZoneId.of("Asia/Shanghai")).toOffsetDateTime(); }
        catch (java.time.DateTimeException ex) { throw new ApiException(ErrorCode.VALIDATION_FAILED,"日期格式无效"); }
    }
    private static boolean present(String value) { return value != null && !value.isBlank(); }
    private static UUID uuid(String value) { try { return value == null ? null : UUID.fromString(value); } catch (IllegalArgumentException ex) { return null; } }
    private static List<String> values(JsonNode array) {
        List<String> result = new ArrayList<>();
        if (array.isArray()) {
            array.forEach(v -> result.add(v.asText()));
        }
        return result;
    }
    private static ApiException missing() { return new ApiException(ErrorCode.NOT_FOUND,"记录不存在，或当前账号无权查看"); }
    private static String actionName(String action) {
        return switch(action) {
            case "view" -> "查看"; case "download" -> "下载"; case "upload" -> "上传"; case "create" -> "新建";
            case "edit" -> "修改"; case "move" -> "移动"; case "delete" -> "删除"; case "restore" -> "还原"; case "manage_permissions" -> "管理权限";
            case "permission_template_apply" -> "应用权限模板"; case "permission_template_unbind" -> "解除模板绑定";
            case "permission_template_sync" -> "同步权限模板"; case "permission_template_update" -> "修改权限模板";
            case "permission_template_create" -> "新增权限模板"; case "permission_template_delete" -> "删除权限模板";
            case "permission_configuration_batch" -> "批量调整权限";
            case "permission_configuration_import" -> "导入权限配置"; case "permission_configuration_copy" -> "复制权限配置";
            default -> "权限配置变更";
        };
    }
}
