package com.uten.imp.audit;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.json.JsonMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.time.OffsetDateTime;
import java.util.Locale;
import java.util.Set;
import org.springframework.beans.BeanUtils;

/** Audit access is not permission to read the original book values or private review text. */
final class StockMeasurementHoldAuditProjection {
    private static final Set<String> TARGETS=Set.of("stock_measurement_holds");
    private static final Set<String> IDS=Set.of("id","stock_balance_id","warehouse_id","goods_id","color_id","verified_unit_id","verified_by");
    private static final Set<String> TIMES=Set.of("captured_at","released_at");
    private static final Set<String> PRIVATE_TEXT=Set.of("evidence_reference","resolution_note");
    private static final JsonMapper JSON=JsonMapper.builder().build();
    private static final String NOTICE="仅展示计量核验状态与关联；原数量、金额、重量及依据说明原文不进入通用审计";
    private StockMeasurementHoldAuditProjection() { }

    static boolean applies(String target) {
        return target!=null&&TARGETS.contains(target.strip().toLowerCase(Locale.ROOT));
    }

    static String snapshot(String target,String raw) {
        if(!applies(target)||raw==null)return raw;
        try {
            JsonNode input=JSON.readTree(raw);
            if(!input.isObject())return null;
            ObjectNode safe=JSON.createObjectNode();
            IDS.forEach(key->{
                JsonNode value=input.get(key);
                if(value!=null&&(value.isNull()||value.isTextual()&&value.asText().matches(
                        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")))safe.set(key,value);
            });
            TIMES.forEach(key->{
                JsonNode value=input.get(key);
                if(value!=null&&value.isNull())safe.set(key,value);
                else if(value!=null&&value.isTextual()) {
                    try { OffsetDateTime.parse(value.asText());safe.set(key,value); }
                    catch(java.time.format.DateTimeParseException invalid) { /* Never emit unexpected payload text. */ }
                }
            });
            JsonNode reason=input.get("reason");
            if(reason!=null&&"LEGACY_QUANTITY_BASIS_UNPROVEN".equals(reason.asText()))safe.set("reason",reason);
            JsonNode sha=input.get("evidence_sha256");
            if(sha!=null&&(sha.isNull()||sha.isTextual()&&sha.asText().matches("[a-f0-9]{64}")))safe.set("evidence_sha256",sha);
            JsonNode flags=input.get("_redacted_changes");
            if(flags!=null&&flags.isArray()) {
                var selected=JSON.createArrayNode();
                PRIVATE_TEXT.stream().sorted().filter(key->{
                    for(JsonNode item:flags)if(item.isTextual()&&key.equals(item.asText()))return true;
                    return false;
                }).forEach(selected::add);
                if(!selected.isEmpty())safe.set("_redacted_changes",selected);
            }
            return JSON.writeValueAsString(safe);
        } catch(Exception invalid) { return null; }
    }

    static AuditLog presentation(AuditLog original) {
        if(!applies(original.getTargetType()))return original;
        var safe=new AuditLog();
        BeanUtils.copyProperties(original,safe);
        safe.setBefore(snapshot(original.getTargetType(),original.getBefore()));
        safe.setAfter(snapshot(original.getTargetType(),original.getAfter()));
        return safe;
    }

    static String changeSummary(String target,String summary) {
        if(!applies(target))return summary;
        return summary==null||summary.isBlank()?NOTICE:summary+"；"+NOTICE;
    }
}
