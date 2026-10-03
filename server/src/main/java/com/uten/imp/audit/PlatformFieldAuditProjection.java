package com.uten.imp.audit;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.json.JsonMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.Set;

/** Audit permission never substitutes for the original business row and price permissions. */
final class PlatformFieldAuditProjection {
    private static final Set<String> TABLES=Set.of("platform_record_fields","platform_record_field_versions","platform_column_definitions");
    private static final Set<String> LEGACY_ITEM_TABLES = Set.of(
            "sales_quote_items", "sales_order_items", "purchase_order_items", "subcontract_order_items");
    private static final Set<String> LEGACY_VALUE_KEYS = Set.of("extra_columns", "extraColumns");
    private static final Set<String> METADATA=Set.of("id","scope","record_id","version","operation","actor_id",
            "created_by","updated_by","created_at","updated_at","recorded_at","owner_user_id","value_type","price_protected");
    private static final JsonMapper JSON=JsonMapper.builder()
            .enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS).build();
    private PlatformFieldAuditProjection(){}
    static boolean applies(String table){return TABLES.contains(table==null?"":table)||legacyItems(table);}
    private static boolean legacyItems(String table) {
        return LEGACY_ITEM_TABLES.contains(table == null ? "" : table);
    }
    static String snapshot(String table,String raw){
        if(!applies(table)||raw==null)return raw;
        try {
            var input=JSON.readTree(raw);if(!input.isObject())return null;
            if (legacyItems(table)) {
                // FULL audit rows remain immutable. Remove the entire legacy value branch,
                // including user-defined names/formulas, before any generic interpretation.
                removeLegacyValues(input);
                return JSON.writeValueAsString(input);
            }
            var safe=JSON.createObjectNode();
            METADATA.forEach(key->{if(input.has(key)&&!input.get(key).isContainerNode())safe.set(key,input.get(key));});
            return JSON.writeValueAsString(safe);
        } catch(Exception unreadable){return null;}
    }
    private static void removeLegacyValues(JsonNode node) {
        if (node.isObject()) {
            ((ObjectNode) node).remove(LEGACY_VALUE_KEYS);
        }
        if (node.isContainerNode()) {
            node.forEach(PlatformFieldAuditProjection::removeLegacyValues);
        }
    }

    static String changeSummary(String table, String summary) {
        if (!applies(table)) return summary;
        String notice = legacyItems(table)
                ? "旧扩展字段原值已隐藏；受控读取需校验当前业务范围与价格权限，旧快照不代表完整字段版本"
                : "扩展字段原值已隐藏；受控读取需校验当前业务范围与价格权限";
        return summary == null || summary.isBlank() ? notice : summary + "；" + notice;
    }

    static AuditLog presentation(AuditLog original){
        if(!applies(original.getTargetType()))return original;
        // Existing platform detail-view metadata is safe metadata, but it must never
        // exempt a legacy item snapshot from pruning merely because it has that marker.
        if(!legacyItems(original.getTargetType())&&AuditEventInterpreter.isDetailViewMetadata(original))return original;
        var safe=new AuditLog();org.springframework.beans.BeanUtils.copyProperties(original,safe);
        safe.setBefore(snapshot(original.getTargetType(),original.getBefore()));
        safe.setAfter(snapshot(original.getTargetType(),original.getAfter()));
        return safe;
    }
}
