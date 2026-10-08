package com.uten.imp.features.master.goods.costing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.uten.imp.application.port.MasterReferenceValidationPort;
import com.uten.imp.common.storage.ImmutableDocumentStore;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.CurrentAuthorityGuard;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import lombok.RequiredArgsConstructor;
import org.springframework.jdbc.core.namedparam.MapSqlParameterSource;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.annotation.Isolation;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.Set;
import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.*;
import static com.uten.imp.features.master.goods.costing.GoodsCostImportContracts.*;

@Service
@RequiredArgsConstructor
public class GoodsCostImportService {
    private final NamedParameterJdbcTemplate db;
    private final ObjectMapper json;
    private final ImmutableDocumentStore files;
    private final SecurityContextCurrentUser current;
    private final MasterReferenceValidationPort references;
    private final CostImportEvidenceGuard guard;
    private final GoodsCostSheetService sheets;
    private final TxSessionVars tx;

    @Transactional
    public Preview preview(UUID goodsId, String sourceName, byte[] bytes) {
        CurrentAuthorityGuard.requireAll("goods:cost:view", "goods:cost:edit");
        references.requireVisibleGoods(goodsId); tx.bind();
        UUID actor = current.id().orElseThrow(() -> new ApiException(ErrorCode.UNAUTHORIZED));
        String hash = ImmutableDocumentStore.digest(bytes);
        var args = new MapSqlParameterSource().addValue("goods", goodsId).addValue("actor", actor).addValue("hash", hash);
        db.query("SELECT pg_advisory_xact_lock(hashtextextended(CAST(:goods AS text)||CAST(:actor AS text)||:hash,755))", args, r -> null);
        var old = db.queryForList("SELECT preview::text FROM goods_cost_imports WHERE goods_id=:goods AND actor_id=:actor AND storage_sha256=:hash", args, String.class);
        if (!old.isEmpty()) {
            files.checkLegacy("GOODS_COST_IMPORT_REPLAY",bytes);
            return decode(old.getFirst());
        }
        String name = sourceName == null ? "cost.xlsx" : sourceName.replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]", "_");
        if (name.isBlank() || name.length() > 240) throw invalid("文件名称过长或无效");
        UUID id = UUID.randomUUID();
        Preview preview = GoodsCostWorkbookParser.parse(id, name, hash, bytes);
        var stored = files.save("GOODS_COST_IMPORT", "source.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", bytes);
        args.addValue("id", id).addValue("name", name).addValue("provider", stored.provider()).addValue("key", stored.key())
                .addValue("version", stored.version()).addValue("size", stored.size()).addValue("preview", encode(preview));
        db.update("""
                INSERT INTO goods_cost_imports(id,goods_id,actor_id,source_name,storage_provider,storage_key,storage_version,storage_size,storage_sha256,preview)
                VALUES(:id,:goods,:actor,:name,:provider,:key,:version,:size,:hash,CAST(:preview AS jsonb))
                """, args);
        db.update("""
                INSERT INTO attachment_object_outbox(operation,storage_provider,storage_key,storage_version,dedupe_key)
                VALUES('DELETE_STAGING',:provider,:key,:version,:provider||'|DELETE_STAGING|'||:key||'|'||COALESCE(CAST(:version AS text),'<local>'))
                ON CONFLICT(dedupe_key) DO NOTHING
                """, args);
        return preview;
    }

    @Transactional(isolation = Isolation.REPEATABLE_READ)
    public Applied apply(Apply request) {
        CurrentAuthorityGuard.requireAll("goods:cost:view", "goods:cost:edit");
        if (request == null || request.input() == null || request.importId() == null) throw invalid("请选择导入文件和成本单");
        sheets.requireInputScope(request.input());
        guard.requireReadable(request.importId(), request.input().goodsId());
        tx.bind();
        var stored = db.queryForMap("SELECT actor_id,preview::text FROM goods_cost_imports WHERE id=:id", Map.of("id", request.importId()));
        if (!Objects.equals(stored.get("actor_id"), current.id().orElse(null))) throw new ApiException(ErrorCode.FORBIDDEN, "只能应用本人上传的原始成本文件");
        Preview preview = decode((String) stored.get("preview"));
        Block block = preview.blocks().stream().filter(b -> b.key().equals(request.blockKey())).findFirst().orElseThrow(() -> invalid("请选择产品区块"));
        if (request.mappings() == null || request.mappings().size() != block.rows().size()) throw invalid("每条来源行都需要匹配或明确跳过");
        DraftInput base = detachPreviousImport(request.input());
        Calculation currentCalculation = sheets.preview(base);
        Map<String, CostLine> targets = new HashMap<>(); currentCalculation.lines().forEach(line -> targets.put(line.path(), line));
        Map<String, ImportRow> sourceRows = new HashMap<>(); block.rows().forEach(row -> sourceRows.put(row.key(), row));
        Map<String, LineOverride> overrides = new LinkedHashMap<>();
        if (base.lineOverrides() != null) base.lineOverrides().forEach(row -> overrides.put(row.path(), row));
        List<FeeInput> fees = new ArrayList<>(base.fees() == null ? List.of() : base.fees());
        var mappedRows = new HashSet<String>(); var mappedPaths = new HashSet<String>();
        for (Mapping mapping : request.mappings()) {
            ImportRow row = sourceRows.get(mapping.rowKey());
            if (row == null || !mappedRows.add(mapping.rowKey())) throw invalid("来源行重复或不存在");
            if (!mapping.reviewed()) throw invalid("请确认来源行: " + row.name());
            String evidence = preview.sourceName() + " / " + row.key() + " / " + preview.sha256().substring(0, 12);
            if ("SKIP".equals(mapping.kind())) {
                if (mapping.skipReason() == null || mapping.skipReason().isBlank()) throw invalid("跳过来源行需要原因: " + row.name());
                continue;
            }
            if ("FEE".equals(mapping.kind())) {
                String amount = mapping.unitPrice() == null ? row.amount() : mapping.unitPrice();
                if (amount == null) throw invalid("费用金额缺失: " + row.name());
                String key = "import-" + UUID.nameUUIDFromBytes((request.importId() + row.key()).getBytes(java.nio.charset.StandardCharsets.UTF_8));
                fees.removeIf(f -> key.equals(f.key()));
                fees.add(new FeeInput(key, mapping.feeName() == null || mapping.feeName().isBlank() ? row.name() : mapping.feeName(),
                        "PER_UNIT", "PROCESS", null, amount, null, List.of(), "IMPORT_REVIEWED", evidence));
                continue;
            }
            if (!"MATERIAL".equals(mapping.kind()) || mapping.targetPath() == null) throw invalid("请选择材料匹配或费用类型");
            CostLine target = targets.get(mapping.targetPath());
            if (target == null || !target.included() || !mappedPaths.add(target.path())) throw invalid("材料匹配重复或不是计价明细: " + row.name());
            String rate = mapping.priceUnitRate();
            if (!row.unit().isBlank() && !row.unit().equals(target.unitName()) && (rate == null || rate.isBlank()))
                throw invalid("计价单位不同，请明确换算率: " + row.name());
            String price = mapping.unitPrice() == null ? row.unitPrice() : mapping.unitPrice();
            if (price == null) throw invalid("材料单价缺失: " + row.name());
            LineOverride previous = overrides.get(target.path());
            overrides.put(target.path(), new LineOverride(target.path(), mapping.adoptedQty() == null
                    ? previous == null ? null : previous.adoptedQty() : mapping.adoptedQty(),
                    previous == null ? null : previous.route(), price, rate == null ? "1" : rate,
                    base.exchangeRateToLocal(), null, "AS_RECORDED", null, "MANUAL", "已核定导入: " + evidence));
        }
        Map<String, String> fields = new LinkedHashMap<>(base.extraFields() == null ? Map.of() : base.extraFields());
        fields.put("importId", request.importId().toString()); fields.put("sourceName", preview.sourceName()); fields.put("sourceHash", preview.sha256());
        // The immutable mapping receipt includes explicit skips and corrections without putting the workbook into the draft.
        String mappingHash = ImmutableDocumentStore.digest(encode(request.mappings()).getBytes(java.nio.charset.StandardCharsets.UTF_8));
        UUID mappingId = UUID.randomUUID();
        fields.put("importMappingHash", mappingHash);
        fields.put("importMappingId", mappingId.toString());
        DraftInput old = base;
        DraftInput input = new DraftInput(old.goodsId(), old.clientId(), old.name(), old.batchQty(), old.currencyId(), old.exchangeRateToLocal(),
                old.effectiveDate(), old.usageStrategy(), old.priceStrategy(), old.templateId(), new ArrayList<>(overrides.values()),
                fees, old.priceColumns(), old.priceCells(), fields, old.notes());
        db.update("""
                INSERT INTO goods_cost_import_mappings(id,import_id,goods_id,actor_id,block_key,mapping_hash,mappings,base_input,result_input)
                VALUES(:id,:importId,:goods,:actor,:block,:hash,CAST(:mappings AS jsonb),CAST(:base AS jsonb),CAST(:input AS jsonb))
                """, new MapSqlParameterSource().addValue("id", mappingId).addValue("importId", request.importId())
                .addValue("goods", input.goodsId()).addValue("actor", current.id().orElseThrow())
                .addValue("block", request.blockKey()).addValue("hash", mappingHash)
                .addValue("mappings", encode(request.mappings())).addValue("base",encode(base)).addValue("input", encode(input)));
        Calculation calculated = sheets.preview(input);
        return new Applied(input, calculated, preview.warnings());
    }

    /** Undo only the previous receipt's still-owned changes, then apply the new mapping to that clean baseline. */
    private DraftInput detachPreviousImport(DraftInput currentInput) {
        Map<String,String> fields=currentInput.extraFields()==null?Map.of():currentInput.extraFields();
        String previousId=fields.get("importMappingId");
        if(previousId==null) {
            boolean hasOwnedFees=currentInput.fees()!=null&&currentInput.fees().stream().anyMatch(f->"IMPORT_REVIEWED".equals(f.source()));
            boolean hasOwnedOverrides=currentInput.lineOverrides()!=null&&currentInput.lineOverrides().stream()
                    .anyMatch(o->o.reason()!=null&&o.reason().startsWith("已核定导入: "));
            if(hasOwnedFees||hasOwnedOverrides)throw conflict("现有导入项缺少对应的导入记录，请先恢复原草稿或明确改为手工项后再导入");
            return withRows(currentInput,currentInput.lineOverrides(),currentInput.fees(),withoutImportFields(fields));
        }
        UUID mappingId;
        try{mappingId=UUID.fromString(previousId);}catch(IllegalArgumentException invalidId){throw invalid("原成本匹配记录的编号格式不正确");}
        guard.validate(currentInput.goodsId(),fields);
        var rows=db.queryForList("""
                SELECT goods_id,import_id,base_input::text base_input,result_input::text result_input
                FROM goods_cost_import_mappings WHERE id=:id AND goods_id=:goods
                """,Map.of("id",mappingId,"goods",currentInput.goodsId()));
        if(rows.size()!=1)throw new ApiException(ErrorCode.NOT_FOUND,"原成本匹配记录不存在");
        var row=rows.getFirst();
        if(!Objects.equals(Objects.toString(row.get("import_id")),fields.get("importId")))throw invalid("原文件与成本匹配记录不匹配");
        DraftInput before=decodeInput((String)row.get("base_input")),after=decodeInput((String)row.get("result_input"));
        if(!currentInput.goodsId().equals(before.goodsId())||!currentInput.goodsId().equals(after.goodsId()))throw invalid("原成本匹配记录的货品不匹配");
        sheets.requireInputScope(before);sheets.requireInputScope(after);
        List<LineOverride> overrides=restoreRows(currentInput.lineOverrides(),before.lineOverrides(),after.lineOverrides(),
                LineOverride.class,"path","物料覆盖");
        List<FeeInput> fees=restoreRows(currentInput.fees(),before.fees(),after.fees(),FeeInput.class,"key","费用");
        return withRows(currentInput,overrides,fees,withoutImportFields(fields));
    }

    private static final Set<String> NUMERIC_FIELDS=Set.of("adoptedQty","unitPrice","priceUnitRate","priceExchangeRateToLocal","taxRate","value","quantity");
    private <T> List<T> restoreRows(List<T> currentRows,List<T> beforeRows,List<T> afterRows,Class<T> type,String identity,String label) {
        Map<String,ObjectNode> currentMap=rowsByIdentity(currentRows,identity),beforeMap=rowsByIdentity(beforeRows,identity),afterMap=rowsByIdentity(afterRows,identity);
        Set<String> owned=new java.util.LinkedHashSet<>(beforeMap.keySet());owned.addAll(afterMap.keySet());
        for(String key:owned) {
            ObjectNode before=beforeMap.get(key),after=afterMap.get(key),now=currentMap.get(key);
            if(Objects.equals(before,after)||now==null)continue; // Explicit user deletion is retained, never resurrected.
            if(after==null)throw conflict("原导入曾删除"+label+"，请核对后重新导入");
            ObjectNode restored=now.deepCopy();
            Set<String> fields=new java.util.LinkedHashSet<>();after.fieldNames().forEachRemaining(fields::add);
            if(before!=null)before.fieldNames().forEachRemaining(fields::add);
            for(String field:fields) {
                if(identity.equals(field))continue;
                JsonNode original=before==null?null:before.get(field),applied=after.get(field),present=now.get(field);
                if(equivalent(field,original,applied))continue;
                if(equivalent(field,present,applied)) {
                    if(original==null)restored.putNull(field);else restored.set(field,original);
                } else if(!equivalent(field,present,original)) {
                    throw conflict("上次导入后的"+label+"已被手工修改，请先核对再重新映射 ("+fieldLabel(field)+")");
                }
            }
            boolean empty=true;var remaining=restored.fieldNames();
            while(remaining.hasNext()){String field=remaining.next();if(!identity.equals(field)&&!restored.get(field).isNull()){empty=false;break;}}
            if(before==null&&empty)currentMap.remove(key);else currentMap.put(key,restored);
        }
        return currentMap.values().stream().map(node->json.convertValue(node,type)).toList();
    }
    private <T> Map<String,ObjectNode> rowsByIdentity(List<T> rows,String identity) {
        Map<String,ObjectNode> result=new LinkedHashMap<>();
        if(rows!=null)for(T row:rows) {
            if(row==null)throw invalid("成本输入包含空明细");
            ObjectNode node=json.valueToTree(row);String key=node.path(identity).asText();
            if(key.isBlank()||result.putIfAbsent(key,node)!=null)throw invalid("成本输入身份重复或缺失");
        }
        return result;
    }
    private boolean equivalent(String field,JsonNode a,JsonNode b) {
        if(a==null||a.isNull())return b==null||b.isNull();
        if(b==null||b.isNull())return false;
        if(NUMERIC_FIELDS.contains(field))try{return new java.math.BigDecimal(a.asText()).compareTo(new java.math.BigDecimal(b.asText()))==0;}
            catch(NumberFormatException ignored){return a.equals(b);}
        return a.equals(b);
    }
    private static Map<String,String> withoutImportFields(Map<String,String> fields) {
        Map<String,String> result=new LinkedHashMap<>(fields);
        for(String key:List.of("importId","importMappingId","importMappingHash","sourceName","sourceHash"))result.remove(key);
        return result;
    }
    private static String fieldLabel(String field) {
        return switch(field) {
            case "unitPrice","value" -> "单价或费用";
            case "adoptedQty","quantity" -> "采用数量";
            case "priceUnitRate" -> "单位换算率";
            case "priceExchangeRateToLocal" -> "汇率";
            case "taxRate","taxMode" -> "税口径";
            case "reason" -> "说明";
            case "name" -> "费用名称";
            case "category","type" -> "费用规则";
            case "baseKeys" -> "计费基数";
            default -> "来源或计价设置";
        };
    }
    private static DraftInput withRows(DraftInput input,List<LineOverride> overrides,List<FeeInput> fees,Map<String,String> fields) {
        return new DraftInput(input.goodsId(),input.clientId(),input.name(),input.batchQty(),input.currencyId(),input.exchangeRateToLocal(),
                input.effectiveDate(),input.usageStrategy(),input.priceStrategy(),input.templateId(),overrides,fees,input.priceColumns(),input.priceCells(),fields,input.notes());
    }
    private DraftInput decodeInput(String value) {
        try{return json.readValue(value,DraftInput.class);}catch(Exception failure){throw new IllegalStateException("原成本映射基线无法读取",failure);}
    }
    private static ApiException conflict(String message){return new ApiException(ErrorCode.CONFLICT,message);}

    private Preview decode(String value) {
        try { return json.readValue(value, Preview.class); }
        catch (Exception error) { throw new IllegalStateException("成本来源证据无法读取", error); }
    }
    private String encode(Object value) {
        try { return json.writeValueAsString(value); }
        catch (Exception error) { throw new IllegalStateException("成本来源证据无法保存", error); }
    }
    private static ApiException invalid(String message) { return new ApiException(ErrorCode.VALIDATION_FAILED, message); }
}
