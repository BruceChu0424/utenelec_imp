package com.uten.imp.features.rbac.directory;

import com.uten.imp.application.port.AiChatToolPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.rbac.directory.AiChatFeatureDirectory.Feature;
import com.uten.imp.features.rbac.directory.AiFeatureAccess.Page;
import com.uten.imp.features.rbac.directory.AiFeatureAccess.Reader;
import org.springframework.stereotype.Component;

import java.text.Collator;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.TreeSet;

/**
 * 「在哪里、哪个页面、怎么进、有哪些功能」 (SPEC P1-1): up to eight directory pages matching the user's words, the
 * ones the reader can open first with their menu path, then the ones the reader cannot open with the missing
 * permissions by Chinese name. Without a keyword it lists the modules the reader can open. Only words leave the
 * server; a route never does. When every page found opens, the titles, modules, purposes and menu words may go to
 * the model to compose the answer; an answer that names missing access is deterministic and stays in the application.
 */
@Component
public class FeatureDirectoryAiChatTool implements AiChatToolPort {
    static final int MAX_PAGES = 8;
    private static final String FACTS = "_modelFacts";
    private final AiFeatureAccess access;

    FeatureDirectoryAiChatTool(AiFeatureAccess access) {
        this.access = access;
    }

    @Override public String name() { return "feature_directory"; }
    @Override public String title() { return "功能与页面目录"; }
    @Override public String domain() { return "SELF"; }

    @Override
    public String description() {
        return "按当前账号的权限，查平台有哪些功能页面、某个功能或单据在哪里、怎么进入。keyword 填用户说的功能、页面或单据名称，"
                + "例如即时库存、采购订货单、报销、工资条；不填时列出本人能打开的模块。只回答页面名称和进入方法，不查业务数据；"
                + "打不开的页面会说明缺少哪项权限。";
    }

    @Override
    public Map<String, Object> parameters() {
        return Map.of("type", "object", "additionalProperties", false,
                "properties", Map.of("keyword", Map.of("type", "string", "maxLength", 50)),
                "required", List.of());
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
        String keyword = keyword(arguments);
        Reader reader = access.reader();
        if (AiChatFeatureDirectory.terms(keyword).isEmpty()) return modules(reader);
        List<Feature> found = access.directory().search(keyword).stream().limit(MAX_PAGES).toList();
        if (found.isEmpty()) {
            return Map.of("reply", "功能目录里没找到相关的页面。可以换个说法，说出页面或单据上的名称；也可以问我「我能打开哪些功能」。",
                    "actions", List.of());
        }
        List<Page> pages = new ArrayList<>(access.pages(reader, found));
        pages.sort((a, b) -> Boolean.compare(b.opens(), a.opens()));
        StringBuilder reply = new StringBuilder("找到这些相关页面：");
        boolean locked = false;
        for (Page page : pages) {
            Feature feature = page.feature();
            reply.append("\n• ").append(feature.title());
            if (!feature.module().equals(feature.title())) reply.append("(").append(feature.module()).append(")");
            if (page.opens()) {
                if (!page.feature().purpose().isBlank()) reply.append("：").append(trimEnd(page.feature().purpose()));
                reply.append("。进入：").append(page.how()).append("。");
            } else {
                locked = true;
                reply.append("：你暂时打不开，").append(page.lack()).append("。");
            }
        }
        if (locked) reply.append("\n打不开的页面").append(AiFeatureAccess.ASK_ADMIN);
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("reply", reply.toString());
        result.put("actions", List.of());
        if (!locked) {
            result.put(FACTS, Map.of("pages", pages.stream().map(page -> Map.of("title", page.feature().title(),
                    "module", page.feature().module(), "purpose", page.feature().purpose(), "howToOpen", page.how())).toList()));
        }
        return result;
    }

    /** Titles, modules, purposes and menu words of pages the reader opens; nothing about missing access. */
    @Override
    @SuppressWarnings("unchecked")
    public Map<String, Object> modelFacts(Map<String, Object> result) {
        return result.get(FACTS) instanceof Map<?, ?> facts ? (Map<String, Object>) facts : Map.of();
    }

    private Map<String, Object> modules(Reader reader) {
        Set<String> modules = new TreeSet<>(Collator.getInstance(Locale.CHINA));
        for (Feature feature : access.directory().features()) {
            boolean menu = feature.paths().stream().anyMatch(path -> !path.isEmpty() && "工作台".equals(path.getFirst()));
            if (menu && access.directory().opens(feature, reader.granted(), reader.superAdmin())) modules.add(feature.module());
        }
        if (modules.isEmpty()) {
            return Map.of("reply", "工作台上暂时没有你能打开的业务模块。需要哪项功能，" + AiFeatureAccess.ASK_ADMIN,
                    "actions", List.of());
        }
        List<String> names = List.copyOf(modules);
        return Map.of("reply", "你现在能在工作台打开这些模块：" + String.join("、", names)
                        + "。说出功能或单据的名称，我可以告诉你在哪里、怎么进去。",
                "actions", List.of(), FACTS, Map.of("modules", names));
    }

    static String keyword(Map<String, Object> arguments) {
        if (arguments == null || !Set.of("keyword").containsAll(arguments.keySet())) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "查功能目录只需要一个功能或页面名称");
        }
        Object raw = arguments.get("keyword");
        if (raw == null) return "";
        if (!(raw instanceof String value) || value.length() > 50) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "功能或页面名称最多 50 个字");
        }
        return value.strip();
    }

    private static String trimEnd(String text) {
        String value = text.strip();
        return value.endsWith("。") ? value.substring(0, value.length() - 1) : value;
    }
}
