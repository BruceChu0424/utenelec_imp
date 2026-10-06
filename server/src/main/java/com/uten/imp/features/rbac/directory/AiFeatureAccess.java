package com.uten.imp.features.rbac.directory;

import com.uten.imp.features.rbac.directory.AiChatFeatureDirectory.Feature;
import com.uten.imp.features.rbac.directory.AiChatFeatureDirectory.Lack;
import com.uten.imp.security.AiChatAccessPolicy;
import com.uten.imp.security.AuthUser;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

/**
 * The reader's own access to directory pages and permission codes, in plain Chinese (SPEC P1-1, P1-4). Permission
 * names come from the permission catalog; codes never appear in a reply. Who administers access is never named.
 * Names of personnel and payroll permissions are shown only to readers who already work in the personnel domain;
 * everyone else reads 「需要管理员开通相关权限」.
 */
@Component
class AiFeatureAccess {
    /** Personnel and payroll permission codes (employee files, departments, positions, payroll, profile review). */
    private static final List<String> PERSONNEL = List.of("employee:", "department:", "position:", "payroll:",
            "profile:review", "attendance:", "leave:");
    static final String ASK_ADMIN = "请联系管理员开通。";
    static final String GENERIC = "需要管理员开通相关权限";

    /** The current chat user's permissions; whether names of personnel permissions may be shown. */
    record Reader(Set<String> granted, boolean superAdmin, boolean personnel) {}

    /** One catalog permission as the permission management page names it. */
    record PermissionName(String code, String name, String module, String category) {}

    /** A directory page as this reader sees it: {@code lack} is null when the reader can open it. */
    record Page(Feature feature, boolean opens, String how, String lack) {}

    private final AiChatFeatureDirectory directory;
    private final AiChatAccessPolicy access;
    private final JdbcTemplate jdbc;

    AiFeatureAccess(AiChatFeatureDirectory directory, AiChatAccessPolicy access, JdbcTemplate jdbc) {
        this.directory = directory;
        this.access = access;
        this.jdbc = jdbc;
    }

    AiChatFeatureDirectory directory() {
        return directory;
    }

    Reader reader() {
        AuthUser actor = access.requireChat();
        return new Reader(Set.copyOf(actor.getPermissions()), actor.isSuperAdmin(), access.domains().contains("HR"));
    }

    static boolean personnel(String code) {
        return PERSONNEL.stream().anyMatch(code::startsWith);
    }

    /** Whether this reader may read the name of [code]. */
    static boolean nameable(Reader reader, String code) {
        return reader.superAdmin() || reader.personnel() || !personnel(code);
    }

    /** The pages as this reader sees them, with one catalog read for every missing code. */
    List<Page> pages(Reader reader, List<Feature> features) {
        Set<String> missing = new LinkedHashSet<>();
        for (Feature feature : features) {
            if (!feature.hub() && !directory.opens(feature, reader.granted(), reader.superAdmin())) {
                missing.addAll(directory.lack(feature, reader.granted()).codes());
            }
        }
        Map<String, PermissionName> names = names(missing);
        List<Page> pages = new ArrayList<>();
        for (Feature feature : features) {
            boolean opens = directory.opens(feature, reader.granted(), reader.superAdmin());
            pages.add(new Page(feature, opens, directory.howToOpen(feature), opens ? null : lackText(reader, feature, names)));
        }
        return List.copyOf(pages);
    }

    /** Why the reader cannot open the page, naming the missing permissions ("缺少「查看仓库报表」权限"). */
    String lackText(Reader reader, Feature feature, Map<String, PermissionName> names) {
        if (feature.route().startsWith("/admin/")) return "这是系统管理页面，" + GENERIC;
        if (feature.hub()) return "这个模块里的页面你都还没有开通";
        Lack lack = directory.lack(feature, reader.granted());
        for (String code : lack.codes()) {
            if (!nameable(reader, code) || !names.containsKey(code)) return GENERIC;
        }
        StringBuilder text = new StringBuilder();
        if (!lack.anyOf().isEmpty()) {
            List<String> any = lack.anyOf().stream().map(code -> quoted(names.get(code).name())).toList();
            text.append(any.size() == 1 ? "缺少" + any.getFirst() + "权限"
                    : "需要" + String.join("或", any) + "其中一项权限");
        }
        if (!lack.allOf().isEmpty()) {
            text.append(text.isEmpty() ? "缺少" : "，还需要")
                    .append(String.join("、", lack.allOf().stream().map(code -> quoted(names.get(code).name())).toList()))
                    .append("权限");
        }
        return text.toString();
    }

    /** Catalog names of the given codes; unknown codes are simply absent. */
    Map<String, PermissionName> names(Collection<String> codes) {
        if (codes.isEmpty()) return Map.of();
        Map<String, PermissionName> names = new LinkedHashMap<>();
        for (PermissionName row : jdbc.query(
                "SELECT code, name, module, category FROM permissions WHERE code = ANY (?)",
                statement -> statement.setArray(1, statement.getConnection().createArrayOf("text", codes.toArray())),
                (rs, i) -> new PermissionName(rs.getString("code"), rs.getString("name"), rs.getString("module"),
                        rs.getString("category")))) {
            names.put(row.code(), row);
        }
        return names;
    }

    /** The whole permission catalog (a few hundred rows), for matching an operation by its name. */
    List<PermissionName> catalog() {
        return jdbc.query("SELECT code, name, module, category FROM permissions ORDER BY code",
                (rs, i) -> new PermissionName(rs.getString("code"), rs.getString("name"), rs.getString("module"),
                        rs.getString("category")));
    }

    static String quoted(String name) {
        return "「" + name + "」";
    }
}
