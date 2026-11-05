package com.uten.imp.common.finance;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.persistence.EntityManager;
import java.math.BigDecimal;
import java.util.*;

/** Internal save ownership only: callers authorize and lock the parent first.
 * An identity locates a row; only all original operands prove it is the same quantity intent. */
public final class DocumentQuantitySavePlan {
    private static final ObjectMapper JSON=new ObjectMapper();
    private static final List<String> ADOPTION=List.of("charged_base_qty","gift_base_qty","adopted_base_qty",
        "quantity_adoption_version","quantity_precision_policy","quantity_source_proof",
        "receipt_quantity_version","receipt_base_qty","receipt_quantity_proof");
    private DocumentQuantitySavePlan() { }
    public enum Family {
        PURCHASE_ORDER("purchase_order_items","order_id","quantity_semantics","gift_qty","request_item_ids"),
        SUBCONTRACT_ORDER("subcontract_order_items","order_id","application_item_ids"),
        PURCHASE_RECEIPT("purchase_receipt_items","receipt_id","quantity_semantics","gift_qty","order_item_id","replacement_intent","gift_replacement_intent"),
        PURCHASE_RETURN("purchase_return_items","return_id","quantity_semantics","gift_qty","order_item_id","receipt_item_id"),
        SUBCONTRACT_RECEIPT("subcontract_receipt_items","receipt_id","order_item_id","replacement_intent"),
        SUBCONTRACT_MATERIAL_RETURN("subcontract_material_return_items","material_return_id","order_item_id","material_issue_item_id","parent_goods_id","parent_color_id"),
        SALES_RETURN("sales_return_items","return_id","order_item_id","out_item_id");
        final String table,parent;final Set<String> fields;
        Family(String table,String parent,String...extra){this.table=table;this.parent=parent;
            var fields=new LinkedHashSet<>(List.of("goods_id","color_id","unit_id","unit_rate","qty"));fields.addAll(List.of(extra));this.fields=Set.copyOf(fields);}
    }
    public record Intent(int lineNo,UUID identity,Map<String,Object> operands) {
        public Intent units(UUID unit,BigDecimal rate){var normalized=new LinkedHashMap<>(operands);normalized.put("unit_id",unit);normalized.put("unit_rate",rate);return new Intent(lineNo,identity,Collections.unmodifiableMap(normalized));}
    }
    public static Intent intent(int lineNo,UUID identity,Object...pairs){
        if(pairs.length%2!=0)throw new IllegalArgumentException("Quantity operands must be named");
        var values=new LinkedHashMap<String,Object>();for(int i=0;i<pairs.length;i+=2){String key=(String)pairs[i];
            if(values.containsKey(key))throw new IllegalArgumentException("Duplicate quantity operand");values.put(key,pairs[i+1]);}
        return new Intent(lineNo,identity,Collections.unmodifiableMap(values));
    }
    public static UUID identity(UUID business,UUID metadata){
        if(business!=null&&metadata!=null&&!business.equals(metadata))throw invalid("原业务明细与扩展字段明细不一致，请保留输入重新核对");
        return business!=null?business:metadata;
    }
    public static Plan empty(){return new Plan(null,null,Map.of());}
    public static Plan prepare(EntityManager em,Family family,UUID parent,List<Intent> intents){return prepare(em,family,parent,intents,java.util.function.UnaryOperator.identity());}
    public static Plan prepare(EntityManager em,Family family,UUID parent,List<Intent> intents,java.util.function.UnaryOperator<Intent> normalize){
        String source="",join="";
        if(family==Family.PURCHASE_ORDER||family==Family.SUBCONTRACT_ORDER){
            boolean purchase=family==Family.PURCHASE_ORDER;
            String sourceTable=purchase?"purchase_order_item_sources":"subcontract_order_item_sources";
            String sourceColumn=purchase?"request_item_id":"application_item_id";
            String operand=purchase?"request_item_ids":"application_item_ids";
            source=" || jsonb_build_object('"+operand+"',COALESCE((SELECT jsonb_agg(s."+sourceColumn+"::text ORDER BY s."+sourceColumn+") FROM "+sourceTable+" s WHERE s.order_item_id=line.id),'[]'::jsonb),"
                +"'saved_source_splits',COALESCE((SELECT jsonb_agg(jsonb_build_object('source',s."+sourceColumn+",'qty',s.alloc_qty,'gift',"+(purchase?"s.allocated_gift_qty":"0::numeric")+") ORDER BY s.line_no,s."+sourceColumn+") FROM "+sourceTable+" s WHERE s.order_item_id=line.id),'[]'::jsonb))";
        }
        if(family==Family.SUBCONTRACT_ORDER){
            join=" JOIN subcontract_orders saved_header ON saved_header.id=line.order_id";
            source+=" || jsonb_build_object('reference_header',to_jsonb(saved_header))";
        }
        var query=em.createNativeQuery("SELECT (to_jsonb(line)"+source+")::text FROM "+family.table+" line"+join+" WHERE line."+family.parent+"=:parent AND NOT line.is_deleted ORDER BY line.line_no,line.id FOR UPDATE OF line").setParameter("parent",parent);
        var stored=new LinkedHashMap<UUID,Saved>();for(Object raw:query.getResultList()){
            JsonNode row=nativeRow(raw.toString());Saved saved=new Saved(family,row);stored.put(saved.id(),saved);}
        // Reserve every explicit locator before legacy fallback: a new cloned
        // row may precede the original and must not consume its saved decision.
        var identified=new HashSet<UUID>();
        for(Intent input:intents)if(input.identity()!=null){
            if(!stored.containsKey(input.identity()))throw invalid("原明细不属于当前单据，请重新载入后核对");
            if(!identified.add(input.identity()))throw invalid("同一原明细不能重复保存");
        }
        var selected=new LinkedHashMap<Integer,Saved>();var consumed=new HashSet<UUID>();var positions=new HashSet<Integer>();
        for(Intent raw:intents){
            if(!positions.add(raw.lineNo()))throw invalid("明细行号重复，请保留输入核对原明细");
            if(!raw.operands().keySet().equals(family.fields))throw new IllegalArgumentException("Incomplete quantity source operands for "+family);
            Saved explicit=raw.identity()==null?null:stored.get(raw.identity());
            var rawOriginals=explicit!=null?List.of(explicit):stored.values().stream()
                .filter(old->!identified.contains(old.id())&&!consumed.contains(old.id())&&old.matches(raw.operands())).toList();
            // New rows still use the ordinary unit defaults. An existing native
            // v1 row must explicitly repair a component that was never recorded;
            // current master defaults are not evidence of that original basis.
            if(family==Family.PURCHASE_ORDER||family==Family.PURCHASE_RECEIPT||family==Family.PURCHASE_RETURN)
                for(Saved original:rawOriginals)if(original.row.path("quantity_adoption_version").asInt()==1
                    &&((original.text("unit_id")==null&&raw.operands().get("unit_id")==null)
                        ||(original.decimal("unit_rate")==null&&raw.operands().get("unit_rate")==null)))
                    throw invalid("原明细单位/换算率缺少依据，请明确补齐原缺失项后保存");
            Intent input=Objects.requireNonNull(normalize.apply(raw),"Normalized quantity intent");
            if(input.lineNo()!=raw.lineNo()||!Objects.equals(input.identity(),raw.identity())||!input.operands().keySet().equals(family.fields)
                ||raw.operands().entrySet().stream().anyMatch(entry->!Set.of("unit_id","unit_rate").contains(entry.getKey())&&!Objects.equals(entry.getValue(),input.operands().get(entry.getKey()))))
                throw new IllegalArgumentException("Unit normalization cannot change quantity intent identity or sources");
            if(explicit!=null){if(!consumed.add(explicit.id()))throw invalid("同一原明细不能重复保存");
                if(explicit.matches(input.operands()))selected.put(input.lineNo(),explicit);continue;}
            var candidates=stored.values().stream().filter(s->!identified.contains(s.id())&&!consumed.contains(s.id())&&s.matches(input.operands())).toList();
            if(candidates.isEmpty())continue;
            Saved first=candidates.getFirst();
            if(candidates.stream().anyMatch(s->!s.sameAdoption(first)))throw invalid("相同输入存在不同的原数量采用，请重新载入并核对原明细");
            Saved match=candidates.stream().filter(s->s.lineNo()==input.lineNo()).findFirst().orElse(first);
            consumed.add(match.id());selected.put(input.lineNo(),match);
        }
        return new Plan(family,parent,Collections.unmodifiableMap(selected));
    }
    public static final class Plan {
        private final Family family;private final UUID parent;private final Map<Integer,Saved> selected;
        private Plan(Family family,UUID parent,Map<Integer,Saved> selected){this.family=family;this.parent=parent;this.selected=selected;}
        public Saved saved(int lineNo){return selected.get(lineNo);}
        public void deleteReplaced(EntityManager em){
            if(family==null)return;var kept=selected.values().stream().map(Saved::id).toList();
            var delete=em.createNativeQuery("DELETE FROM "+family.table+" WHERE "+family.parent+"=:parent"+(kept.isEmpty()?"":" AND id NOT IN(:kept)"));
            delete.setParameter("parent",parent);if(!kept.isEmpty())delete.setParameter("kept",kept);delete.executeUpdate();
        }
    }
    public static final class Saved {
        private final Family family;private final JsonNode row;private Saved(Family family,JsonNode row){this.family=family;this.row=row;}
        public UUID id(){return UUID.fromString(row.path("id").asText());}
        int lineNo(){return row.path("line_no").asInt();}
        public BigDecimal decimal(String field){JsonNode value=row.get(field);return value==null||value.isNull()?null:value.decimalValue();}
        public String text(String field){JsonNode value=row.get(field);return value==null||value.isNull()?null:value.asText();}
        public boolean matches(String field,Object value){
            JsonNode original=row.get(field);
            // The native receipt API defines an omitted gift intent as its
            // original general replacement intent. Compare that effective input,
            // while retaining the actual stored null in the reused entity.
            if(field.equals("gift_replacement_intent")&&(original==null||original.isNull()))original=row.get("replacement_intent");
            return same(original,value);
        }
        boolean matches(Map<String,Object> values){return values.entrySet().stream().allMatch(v->matches(v.getKey(),v.getValue()));}
        boolean sameAdoption(Saved other){
            if(!ADOPTION.stream().allMatch(field->Objects.equals(row.get(field),other.row.get(field))))return false;
            return family!=Family.PURCHASE_ORDER&&family!=Family.SUBCONTRACT_ORDER
                || List.of("reference_price_precision_policy","total_amount_input","price","extra_columns").stream().allMatch(field->Objects.equals(row.get(field),other.row.get(field)));
        }
        public boolean headerMoneyMatches(UUID supplier,UUID currency,BigDecimal rate,BigDecimal tax,UUID settlement){
            JsonNode header=row.path("reference_header");
            return same(header.get("supplier_id"),supplier)&&same(header.get("currency_id"),currency)&&same(header.get("exchange_rate"),rate)
                &&same(header.get("tax_rate"),tax)&&same(header.get("settlement_method_id"),settlement);
        }
        public <T>T entity(EntityManager em,Class<T> type){T found=em.find(type,id());if(found==null)throw invalid("原数量明细已变化，请保留输入重新核对");return found;}
        public ProcurementQuantities.Amounts procurement(String semantics,BigDecimal quantity,BigDecimal gift,BigDecimal rate){
            return ProcurementQuantities.frozen(semantics,quantity,gift,rate,decimal("charged_base_qty"),decimal("gift_base_qty"));
        }
        public boolean referenceMatches(EntityManager em){return Boolean.TRUE.equals(em.createNativeQuery("SELECT fn_procurement_reference_price_matches(CAST(:item AS jsonb))").setParameter("item",row.toString()).getSingleResult());}
        public List<SourceSplit> sourceSplits(){var out=new ArrayList<SourceSplit>();for(JsonNode source:row.path("saved_source_splits"))
            out.add(new SourceSplit(UUID.fromString(source.path("source").asText()),source.path("qty").decimalValue(),source.path("gift").decimalValue()));return List.copyOf(out);}
    }
    public record SourceSplit(UUID source,BigDecimal quantity,BigDecimal gift) { }
    private static JsonNode nativeRow(String value){
        try{return FinancialJsonResults.tree(JSON,value);}catch(com.fasterxml.jackson.core.JsonProcessingException failure){
            throw new IllegalStateException("Cannot read locked original quantity evidence",failure);
        }
    }
    private static boolean same(JsonNode stored,Object requested){
        if(requested==null)return stored==null||stored.isNull();if(stored==null||stored.isNull())return false;
        if(requested instanceof BigDecimal decimal)return stored.isNumber()&&stored.decimalValue().compareTo(decimal)==0;
        if(requested instanceof Collection<?> items){if(!stored.isArray())return false;
            var expected=items.stream().map(Object::toString).sorted().toList();var actual=new ArrayList<String>();stored.forEach(v->actual.add(v.asText()));actual.sort(String::compareTo);return expected.equals(actual);}
        return stored.asText().equals(requested.toString());
    }
    private static ApiException invalid(String message){return new ApiException(ErrorCode.CONFLICT,message);}
}
