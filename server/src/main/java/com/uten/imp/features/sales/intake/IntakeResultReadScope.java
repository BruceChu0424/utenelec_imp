package com.uten.imp.features.sales.intake;

import com.uten.imp.application.port.MasterIntakeLookupPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Candidate names are business facts too; recheck every source reference before exposing stored recognition. */
final class IntakeResultReadScope {
    private IntakeResultReadScope() {}
    static void requireVisible(Map<String,Object> result, MasterIntakeLookupPort lookup) {
        if (result == null) return;
        Set<UUID> clients = new LinkedHashSet<>(); Set<UUID> goods = new LinkedHashSet<>();
        Map<?,?> client = object(result.get("client"));
        add(client.get("selectedClientId"), clients);
        for (Map<?,?> candidate : objects(client.get("candidates"))) add(candidate.get("clientId"), clients);
        for (Map<?,?> line : objects(result.get("lines"))) collectLine(line, goods, 0);
        for (UUID id : clients) {
            var profile = lookup.clientProfile(id);
            if (profile == null || !"使用".equals(profile.status())) throw changed();
        }
        if (!goods.isEmpty()) {
            Set<UUID> visible = lookup.goodsByIds(goods).stream().map(MasterIntakeLookupPort.GoodsRow::id)
                    .collect(java.util.stream.Collectors.toSet());
            if (!visible.containsAll(goods)) throw changed();
        }
        List<Map<?,?>> duplicates = objects(result.get("duplicates"));
        if (!duplicates.isEmpty()) {
            UUID selected = parse(client.get("selectedClientId"));
            if (selected == null) throw changed();
            Set<String> visibleDocs = lookup.recentDocs(selected, SalesIntakePipeline.DUPLICATE_DAYS).stream()
                    .map(doc -> doc.docType() + ":" + doc.docId()).collect(java.util.stream.Collectors.toSet());
            for (Map<?,?> duplicate : duplicates) {
                if (!visibleDocs.contains(String.valueOf(duplicate.get("docType")) + ":" + parse(duplicate.get("id")))) throw changed();
            }
        }
    }
    /** Only server-defined references; extraValues/header/file content is arbitrary customer text. */
    private static void collectLine(Map<?,?> line, Set<UUID> goods, int depth) {
        if (depth > 8 || goods.size() > 50000) throw changed();
        add(line.get("selectedGoodsId"), goods);
        for (Map<?,?> candidate : objects(line.get("candidates"))) add(candidate.get("goodsId"), goods);
        add(object(line.get("aiSuggestion")).get("goodsId"), goods);
        for (Map<?,?> part : objects(line.get("bundleParts"))) collectLine(part, goods, depth + 1);
    }
    private static Map<?,?> object(Object value) {
        if (value == null) return Map.of();
        if (!(value instanceof Map<?,?> map)) throw changed();
        return map;
    }
    private static List<Map<?,?>> objects(Object value) {
        if (value == null) return List.of();
        if (!(value instanceof List<?> list)) throw changed();
        return list.stream().map(IntakeResultReadScope::object).toList();
    }
    private static void add(Object value, Set<UUID> target) {
        UUID id = parse(value); if (id != null) target.add(id);
    }
    private static UUID parse(Object value) {
        if (value == null) return null;
        try { return UUID.fromString(String.valueOf(value)); }
        catch (IllegalArgumentException malformed) { throw changed(); }
    }
    private static ApiException changed() {
        return new ApiException(ErrorCode.FORBIDDEN, "文件中的客户或货品已不在你当前可用范围内，请重新识别并核对");
    }
}
