package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.color.Color;
import com.uten.imp.features.master.unit.Unit;
import jakarta.persistence.criteria.*;
import org.hibernate.query.criteria.JpaExpression;
import org.hibernate.query.criteria.JpaRoot;
import java.util.UUID;

/** Read-only identity projection: canonical UUID wins; only its absence permits exact legacy fallback. */
final class GoodsReferenceFacet {
    private GoodsReferenceFacet() { }
    record Projection(Expression<String> value, Expression<String> label) { }
    static boolean supports(String field) { return "colorRef".equals(field) || "unitRef".equals(field); }
    static Predicate matches(Root<Goods> root, CriteriaBuilder cb, String field, String raw) {
        // Existing saved table queries used bare integer snapshot values. Preserve that exact
        // snapshot query; new candidates always return a UUID or an explicit unresolved legacy token.
        if (raw != null && raw.trim().matches("[0-9]+")) {
            int legacyId = exactLegacyId(raw.trim());
            String relation = "colorRef".equals(field) ? "color" : "unit";
            return cb.equal(root.get(relation + "LegacyId"), legacyId);
        }
        String normalized = normalize(raw);
        return cb.equal(projection(root, cb, field).value(), normalized);
    }
    static Projection projection(Root<Goods> root, CriteriaBuilder cb, String field) {
        String relation = "colorRef".equals(field) ? "color" : "unit";
        Expression<UUID> canonicalId = root.get(relation).get("id");
        var canonical = root.join(relation, JoinType.LEFT);
        canonical.on(cb.isFalse(canonical.get("deleted")));
        Class<?> targetType = "color".equals(relation) ? Color.class : Unit.class;
        var legacy = ((JpaRoot<Goods>) root).join(targetType, JoinType.LEFT);
        legacy.on(cb.isNull(canonicalId), cb.equal(legacy.get("legacyId"), root.get(relation + "LegacyId")),
                cb.isFalse(legacy.get("deleted")));
        Expression<String> rawLegacy = ((JpaExpression<?>) root.get(relation + "LegacyId")).cast(String.class);
        Expression<String> uuid = ((JpaExpression<?>) canonicalId).cast(String.class);
        Expression<String> legacyUuid = ((JpaExpression<?>) legacy.get("id")).cast(String.class);
        Expression<String> unresolved = cb.<String>selectCase().when(cb.isNotNull(rawLegacy),
                cb.concat("legacy:", rawLegacy)).otherwise(cb.nullLiteral(String.class));
        Expression<String> value = cb.<String>selectCase().when(cb.isNotNull(canonicalId), uuid)
                .when(cb.isNotNull(legacy.get("id")), legacyUuid).otherwise(unresolved);
        Expression<String> label = cb.<String>selectCase().when(cb.isNotNull(canonicalId),
                        cb.coalesce(canonical.<String>get("name"), cb.concat("#", uuid)))
                .when(cb.isNotNull(legacy.get("id")), legacy.<String>get("name"))
                .when(cb.equal(rawLegacy, "0"), "(空)").otherwise(cb.concat("#", rawLegacy));
        return new Projection(value, label);
    }
    static String normalize(String raw) {
        if (raw == null || raw.isBlank()) return null;
        String value = raw.trim();
        try {
            UUID id = UUID.fromString(value);
            if (id.toString().equalsIgnoreCase(value)) return id.toString();
        } catch (IllegalArgumentException ignored) { }
        String legacy = value.startsWith("legacy:") ? value.substring(7) : value;
        return "legacy:" + exactLegacyId(legacy);
    }

    private static int exactLegacyId(String value) {
        try {
            int id = Integer.parseInt(value);
            if (id >= 0 && Integer.toString(id).equals(value)) return id;
        } catch (NumberFormatException ignored) { }
        throw new ApiException(ErrorCode.VALIDATION_FAILED, "颜色或单位筛选必须为资料UUID或精确历史主键");
    }
}
