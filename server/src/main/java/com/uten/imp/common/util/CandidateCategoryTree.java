package com.uten.imp.common.util;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

/** Picker-only category identities and cycle-safe assembly shared by scoped inventory candidates. */
public final class CandidateCategoryTree {
    public static final UUID UNCATEGORIZED = UUID.fromString("00000000-0000-0000-0000-00000000c076");

    private CandidateCategoryTree() {}

    public static List<Map<String, Object>> fromRows(List<Map<String, Object>> categories) {
        Map<UUID, Map<String, Object>> nodes = new LinkedHashMap<>();
        Map<UUID, List<Map<String, Object>>> children = new LinkedHashMap<>();
        for (var category : categories) {
            UUID id = (UUID) category.get("id");
            Map<String, Object> node = new LinkedHashMap<>();
            node.put("id", id);
            node.put("code", category.get("code"));
            node.put("name", category.get("name"));
            node.put("parentId", category.get("parent_id"));
            node.put("level", category.get("level"));
            node.put("sortOrder", category.get("sort_order"));
            var childNodes = new ArrayList<Map<String, Object>>();
            children.put(id, childNodes);
            node.put("children", childNodes);
            nodes.put(id, node);
        }
        List<Map<String, Object>> roots = new ArrayList<>();
        for (var node : nodes.values()) {
            UUID id = (UUID) node.get("id"), parent = (UUID) node.get("parentId");
            if (parent != null && nodes.containsKey(parent) && !categoryCycle(id, parent, nodes)) {
                children.get(parent).add(node);
            } else {
                roots.add(node);
            }
        }
        return roots;
    }

    private static boolean categoryCycle(UUID id, UUID parent, Map<UUID, Map<String, Object>> nodes) {
        Set<UUID> seen = new HashSet<>();
        seen.add(id);
        UUID current = parent;
        while (current != null && nodes.containsKey(current)) {
            if (!seen.add(current)) return true;
            current = (UUID) nodes.get(current).get("parentId");
        }
        return false;
    }
}
