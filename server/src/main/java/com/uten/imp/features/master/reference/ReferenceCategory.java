package com.uten.imp.features.master.reference;

import java.util.List;
import java.util.UUID;
import java.util.function.Function;

/** Shared category hierarchy projection, without master editing metadata. */
public record ReferenceCategory(UUID id, String code, String codePrefix, String name, Integer level,
        UUID parentId, Integer legacyId, List<ReferenceCategory> children) {
    public static <T> List<ReferenceCategory> project(List<T> rows, Function<T,UUID> id,
            Function<T,String> code, Function<T,String> prefix, Function<T,String> name,
            Function<T,Integer> level, Function<T,UUID> parent, Function<T,Integer> legacy,
            Function<T,List<T>> children) {
        return rows.stream().map(row -> new ReferenceCategory(id.apply(row), code.apply(row), prefix.apply(row),
                name.apply(row), level.apply(row), parent.apply(row), legacy.apply(row),
                project(children.apply(row) == null ? List.of() : children.apply(row),
                        id, code, prefix, name, level, parent, legacy, children))).toList();
    }
}
