package com.uten.imp.audit;

import com.fasterxml.jackson.databind.json.JsonMapper;
import java.util.Set;

/** Audit permission never substitutes for the original business row and price permissions. */
final class PlatformFieldAuditProjection {
    private static final Set<String> TABLES=Set.of("platform_record_fields","platform_record_field_versions","platform_column_definitions");
    private static final Set<String> METADATA=Set.of("id","scope","record_id","version","operation","actor_id",
            "created_by","updated_by","created_at","updated_at","recorded_at","owner_user_id","value_type","price_protected");
    private static final JsonMapper JSON=JsonMapper.builder().build();
    private PlatformFieldAuditProjection(){}
    static boolean applies(String table){return TABLES.contains(table==null?"":table);}
    static String snapshot(String table,String raw){
        if(!applies(table)||raw==null)return raw;
        try {
            var input=JSON.readTree(raw);if(!input.isObject())return null;
            var safe=JSON.createObjectNode();
            METADATA.forEach(key->{if(input.has(key)&&!input.get(key).isContainerNode())safe.set(key,input.get(key));});
            return JSON.writeValueAsString(safe);
        } catch(Exception unreadable){return null;}
    }
    static AuditLog presentation(AuditLog original){
        if(!applies(original.getTargetType())||AuditEventInterpreter.isDetailViewMetadata(original))return original;
        var safe=new AuditLog();org.springframework.beans.BeanUtils.copyProperties(original,safe);
        safe.setBefore(snapshot(original.getTargetType(),original.getBefore()));
        safe.setAfter(snapshot(original.getTargetType(),original.getAfter()));
        return safe;
    }
}
