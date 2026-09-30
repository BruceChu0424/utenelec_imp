package com.uten.imp.common.export;

import com.uten.imp.common.platformcolumns.PlatformColumnService;
import com.uten.imp.common.platformcolumns.PlatformColumnContracts;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import java.math.BigDecimal;
import java.util.*;

/** Applies only authorized server columns and stable resource identities to an export. */
@Service
@RequiredArgsConstructor
public class ExportTableProjectionService {
    private final PlatformColumnService platform;
    private static final Map<String,List<String>> ALIASES=Map.ofEntries(
        Map.entry("goods",List.of("goodsName","name")),Map.entry("nameEn",List.of("goodsNameEn")),
        Map.entry("color",List.of("colorName")),Map.entry("unit",List.of("unitName")),
        Map.entry("price",List.of("listPrice")),Map.entry("amount",List.of("amountOriginal")),
        Map.entry("colorLegacyId",List.of("colorName")),Map.entry("unitLegacyId",List.of("unitName")),
        Map.entry("owningWarehouse",List.of("owningWarehouseName")),Map.entry("owningWorkshop",List.of("owningWorkshopName")),
        Map.entry("currencyId",List.of("currencyName")),Map.entry("parent",List.of("parentName")));

    public ExportPayload project(List<ExportColumn> available,List<Map<String,Object>> source,
                                 TableColumnProjection request,String allowedScope) {
        if(request==null)return new ExportPayload(available,source,source.size());
        if(request.columns()==null||request.columns().isEmpty()||request.columns().size()>160)
            throw invalid("请至少选择一列导出，最多 160 列");
        Map<String,ExportColumn> known=new LinkedHashMap<>();
        available.forEach(column->known.put(column.key(),column));
        Set<String> selected=new HashSet<>();List<UUID> customIds=new ArrayList<>();
        for(var column:request.columns()) {
            if(column==null||column.key()==null||!selected.add(column.key()))throw invalid("导出列重复或无效");
            if(column.key().startsWith("platform:"))customIds.add(uuid(column.key().substring(9)));
        }
        if(!customIds.isEmpty() && !Objects.equals(allowedScope,request.scope()))
            throw invalid("导出表头与当前业务类型不一致，请刷新页面");
        Map<UUID,PlatformColumnContracts.Definition> definitions=new HashMap<>();
        if(!customIds.isEmpty()) for(var definition:platform.definitionsByIds(allowedScope,customIds))definitions.put(definition.id(),definition);
        List<ExportColumn> columns=new ArrayList<>();
        for(var requested:request.columns()) {
            String key=requested.key();ExportColumn original;
            if(key.startsWith("platform:")) {
                var definition=definitions.get(uuid(key.substring(9)));
                if(definition==null)throw new ApiException(ErrorCode.FORBIDDEN,"没有该扩展列的导出权限");
                original=new ExportColumn(key,definition.name(),"TEXT".equals(definition.type())?ExportColumn.TEXT:ExportColumn.QTY);
            }else{
                String actual=known.containsKey(key)?key:ALIASES.getOrDefault(key,List.of()).stream().filter(known::containsKey).findFirst().orElse(null);
                if(actual==null)throw new ApiException(ErrorCode.FORBIDDEN,"列不存在或不在可导出范围："+key);
                original=known.get(actual);
            }
            String label=requested.label()==null||requested.label().isBlank()?original.label():requested.label().strip();
            if(label.length()>200)throw invalid("导出表头过长");
            Double width=requested.width();
            if(width!=null&&(!Double.isFinite(width)||width<1||width>2000))throw invalid("导出列宽无效");
            columns.add(new ExportColumn(original.key(),label,original.type(),width));
        }
        if(customIds.isEmpty())return new ExportPayload(columns,source,source.size());
        List<Map<String,Object>> rows=source.stream().map(row->(Map<String,Object>)new LinkedHashMap<>(row)).toList();
        if(allowedScope.startsWith("view_")) {
            Set<String> requiredFacts=new LinkedHashSet<>();
            for(var definition:definitions.values()) if(definition.formula()!=null) {
                var formula=definition.formula();
                if(formula.base().fact()!=null)requiredFacts.add(formula.base().fact());
                if(formula.steps()!=null)for(var step:formula.steps())
                    if(step.operand().fact()!=null)requiredFacts.add(step.operand().fact());
            }
            for(int start=0;start<rows.size();start+=2000) {
                List<Map<String,Object>> part=rows.subList(start,Math.min(start+2000,rows.size()));
                List<Map<String,BigDecimal>> facts=part.stream().map(row->numericFacts(row,known,requiredFacts)).toList();
                var calculated=platform.evaluateDisplayRows(allowedScope,customIds,facts);
                for(int index=0;index<part.size();index++)for(var value:calculated.get(index).entrySet())
                    part.get(index).put("platform:"+value.getKey(),value.getValue());
            }
        }else{
            for(int start=0;start<rows.size();start+=200) {
                List<Map<String,Object>> part=rows.subList(start,Math.min(start+200,rows.size()));
                List<UUID> ids=part.stream().map(row->uuid(Objects.toString(row.get("_platformRecordId"),""))).toList();
                Map<UUID,PlatformColumnContracts.Row> values=new HashMap<>();
                platform.read(allowedScope,new PlatformColumnContracts.BatchRead(ids.stream().distinct().toList(),customIds))
                        .forEach(row->values.put(row.recordId(),row));
                for(int index=0;index<part.size();index++) {
                    var projected=values.get(ids.get(index));
                    if(projected==null)throw invalid("扩展字段来源已变化，请重新读取后导出");
                    for(var cell:projected.cells()) if(customIds.contains(cell.columnId())) {
                        if(cell.masked())throw new ApiException(ErrorCode.FORBIDDEN,"没有该扩展列的导出权限");
                        if(cell.error()!=null)throw invalid(cell.error());
                        part.get(index).put("platform:"+cell.columnId(),cell.value());
                    }
                }
            }
        }
        return new ExportPayload(columns,rows,rows.size());
    }

    private static Map<String,BigDecimal> numericFacts(Map<String,Object> row,Map<String,ExportColumn> available,Set<String> required) {
        Map<String,BigDecimal> facts=new LinkedHashMap<>();
        for(String key:required) {
            String actual=available.containsKey(key)?key:ALIASES.getOrDefault(key,List.of()).stream()
                .filter(available::containsKey).findFirst().orElse(null);
            if(actual==null)continue;
            String type=available.get(actual).type();
            if(type==null||!Set.of(ExportColumn.NUMBER,ExportColumn.MONEY,ExportColumn.QTY).contains(type))continue;
            Object value=row.get(actual);
            if(!(value instanceof Number)&&!(value instanceof String))continue;
            try{facts.put(key,new BigDecimal(value.toString()));}catch(NumberFormatException ignored){}
        }
        return facts;
    }
    private static UUID uuid(String value){try{return UUID.fromString(value);}catch(IllegalArgumentException invalid){throw invalid("导出缺少有效记录身份或列编号");}}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
