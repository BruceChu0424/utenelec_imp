package com.uten.imp.features.rbac.directory;

import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.rbac.directory.AiChatFeatureDirectory.Feature;
import com.uten.imp.features.rbac.directory.AiFeatureAccess.Page;
import com.uten.imp.features.rbac.directory.AiFeatureAccess.PermissionName;
import com.uten.imp.features.rbac.directory.AiFeatureAccess.Reader;
import org.springframework.stereotype.Component;

import java.text.Normalizer;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * 「为什么我打不开、看不到、点不了」 and a pasted 「缺少操作权限：…」 (SPEC P1-4): whether the reader can open the page or
 * holds the permission, the missing permissions by Chinese name, and 「请联系管理员开通」. It explains the reader's own
 * access only, never names who administers access and never grants anything. The answer is deterministic: nothing
 * about the reader's access goes to the model.
 */
@Component
public class MyAccessAiChatTool implements AiChatToolPort {
    static final int MAX_PAGES = 5;
    static final int MAX_OPERATIONS = 3;
    static final int MAX_CODES = 5;
    /**
     * Everything asked about is already open to the reader: the question still came from something that would not open,
     * so the answer says what to try next instead of stopping at "you can open it".
     */
    static final String STILL_BLOCKED = "按你现在的权限是可以的。如果还是打不开、看不到或点不了，先刷新页面或重新登录再试；"
            + "仍然不行，请把页面上的提示原文和所在页面告诉管理员。";
    /** A permission code as the platform's own error text prints it ("缺少操作权限：sales_order:approve"). */
    private static final Pattern CODE = Pattern.compile("(?<![A-Za-z0-9_])[a-z][a-z0-9_]*(?::[a-z0-9_\\-]+)+");
    private final AiFeatureAccess access;

    MyAccessAiChatTool(AiFeatureAccess access) {
        this.access = access;
    }

    @Override public String name() { return "my_access"; }
    @Override public String title() { return "我的权限说明"; }
    @Override public String domain() { return "SELF"; }

    @Override
    public String description() {
        return "说明当前账号能不能打开某个页面、能不能做某项操作、缺少哪些权限。用户问为什么打不开、看不到、点不了、没权限，"
                + "或贴出「缺少操作权限：…」这类报错时用。target 填页面、功能或操作的名称，或报错原文。只说明本人的权限，"
                + "不查别人，也不能开通权限。";
    }

    @Override
    public Map<String, Object> parameters() {
        return Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("target", Map.of("type", "string", "minLength", 1, "maxLength", 300)),
                "required", List.of("target"));
    }

    @Override
    public boolean available() {
        if (access.directory().features().isEmpty()) return false;
        try {
            access.reader();
            return true;
        } catch (ApiException denied) {
            return false;
        }
    }

    @Override
    public Map<String, Object> execute(Map<String, Object> arguments) {
        String target = target(arguments);
        Reader reader = access.reader();
        Set<String> codes = codes(target);
        List<String> lines = codes.isEmpty() ? byName(reader, target) : byCode(reader, codes);
        return Map.of("reply", String.join("\n", lines), "actions", List.of());
    }

    /** The pasted error names the codes: say for each whether the reader holds it. */
    private List<String> byCode(Reader reader, Set<String> codes) {
        Map<String, PermissionName> names = access.names(codes);
        List<String> lines = new ArrayList<>();
        boolean missing = false;
        boolean unknown = false;
        for (String code : codes) {
            PermissionName name = names.get(code);
            if (name == null) {
                unknown = true;
                continue;
            }
            boolean held = reader.superAdmin() || reader.granted().contains(code);
            boolean nameable = AiFeatureAccess.nameable(reader, code);
            missing |= !held;
            if (held) {
                lines.add(nameable ? "你已经有" + AiFeatureAccess.quoted(name.name()) + "权限。" : "这项人事相关的权限你已经有了。");
            } else {
                String where = place(name);
                lines.add(nameable ? "你还没有" + AiFeatureAccess.quoted(name.name()) + "权限"
                        + (where.isEmpty() ? "" : "(属于" + where + ")") + "。"
                        : "这项属于人事相关的权限，你还没有开通，" + AiFeatureAccess.GENERIC + "。");
            }
        }
        if (unknown) lines.add("报错里有一项权限在系统的权限目录里找不到，请把完整的报错和所在页面告诉管理员。");
        if (!missing && !lines.isEmpty() && !unknown) {
            lines.add("如果操作时仍然提示缺少这项权限，请把完整的报错和所在页面告诉管理员。");
        }
        if (missing) lines.add(AiFeatureAccess.ASK_ADMIN);
        return lines;
    }

    /** A page or operation named in words: matching directory pages, then matching catalog operations. */
    private List<String> byName(Reader reader, String target) {
        List<Feature> found = access.directory().search(target).stream().limit(MAX_PAGES).toList();
        List<PermissionName> operations = operations(target);
        if (found.isEmpty() && operations.isEmpty()) {
            return List.of("没找到和你说的页面或操作对应的权限。可以说出页面的名称或按钮上的字，或者把报错的原文贴给我。");
        }
        List<String> lines = new ArrayList<>();
        boolean missing = false;
        Map<String, List<String>> locked = new LinkedHashMap<>();
        for (Page page : access.pages(reader, found)) {
            if (page.opens()) {
                lines.add(AiFeatureAccess.quoted(page.feature().title()) + "：你可以打开。进入：" + page.how() + "。");
            } else {
                missing = true;
                locked.computeIfAbsent(page.lack(), lack -> new ArrayList<>()).add(AiFeatureAccess.quoted(page.feature().title()));
            }
        }
        locked.forEach((lack, titles) -> lines.add(String.join("", titles) + "：你暂时打不开，" + lack + "。"));
        boolean hiddenMissing = false;
        for (PermissionName operation : operations) {
            boolean held = reader.superAdmin() || reader.granted().contains(operation.code());
            if (!AiFeatureAccess.nameable(reader, operation.code())) {
                hiddenMissing |= !held;
                continue;
            }
            missing |= !held;
            lines.add(AiFeatureAccess.quoted(operation.name()) + (held ? "：你已经有这项权限。" : "：你还没有这项权限。"));
        }
        // A personnel operation is never named; it is mentioned only when no page line already covers it.
        if (hiddenMissing && lines.isEmpty()) {
            missing = true;
            lines.add("这项属于人事相关的操作，你还没有开通，" + AiFeatureAccess.GENERIC + "。");
        }
        if (missing) lines.add(AiFeatureAccess.ASK_ADMIN);
        else if (!hiddenMissing) lines.add(STILL_BLOCKED);
        return List.copyOf(new LinkedHashSet<>(lines));
    }

    /** Catalog operations whose name matches the user's words (「审批报销」), best first. */
    private List<PermissionName> operations(String target) {
        List<String> terms = AiChatFeatureDirectory.terms(target);
        if (terms.isEmpty()) return List.of();
        record Scored(PermissionName name, int score) {}
        List<Scored> scored = new ArrayList<>();
        for (PermissionName name : access.catalog()) {
            String folded = AiChatFeatureDirectory.fold(name.name());
            int best = 0;
            for (String term : terms) {
                // Two characters (「采购」) name a whole area, not one operation.
                if (term.length() < 3) continue;
                if (folded.equals(term)) best = Math.max(best, 100);
                else if (folded.contains(term)) best = Math.max(best, 80);
                else if (term.contains(folded) && folded.length() >= 3) best = Math.max(best, 75);
                else {
                    double share = AiChatFeatureDirectory.bigramShare(term, folded);
                    if (share >= 0.75) best = Math.max(best, (int) Math.round(60 * share));
                }
            }
            if (best >= 45) scored.add(new Scored(name, best));
        }
        return scored.stream()
                .sorted(Comparator.comparingInt(Scored::score).reversed()
                        .thenComparingInt(item -> item.name().name().length())
                        .thenComparing(item -> item.name().code()))
                .limit(MAX_OPERATIONS).map(Scored::name).toList();
    }

    static Set<String> codes(String text) {
        Set<String> codes = new LinkedHashSet<>();
        Matcher matcher = CODE.matcher(Normalizer.normalize(text, Normalizer.Form.NFKC));
        while (matcher.find() && codes.size() < MAX_CODES) codes.add(matcher.group());
        return codes;
    }

    private static String place(PermissionName name) {
        String module = name.module() == null ? "" : name.module().strip();
        String category = name.category() == null ? "" : name.category().strip();
        if (module.isEmpty()) return category.isEmpty() ? "" : "「" + category + "」";
        if (category.isEmpty() || category.equals(module)) return "「" + module + "」";
        return "「" + module + " · " + category + "」";
    }

    static String target(Map<String, Object> arguments) {
        if (arguments == null || !Set.of("target").equals(arguments.keySet())
                || !(arguments.get("target") instanceof String value) || value.isBlank() || value.length() > 300) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "请说明是哪个页面或哪项操作，或者把报错的原文贴给我");
        }
        return value.strip();
    }
}
