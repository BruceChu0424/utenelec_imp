package com.uten.imp.features.master.goods.costing;

import com.uten.imp.common.util.*;
import com.uten.imp.common.web.*;
import java.math.BigDecimal;
import java.time.OffsetDateTime;
import java.util.*;
import static com.uten.imp.features.master.goods.costing.GoodsCostContracts.VersionSummary;

/** Exact predicates over an already-authorized, stored calculation summary. */
final class GoodsCostVersionQuery {
    static final Set<String> KEYS=Set.of("name","version","batchQty","knownTotal","updatedAt","currencyName","unitName");
    private final Map<String,String> searches;
    private final String status,currency;
    private final UUID currencyId;
    private final Map<String,NumericColumnFilter> numeric=new LinkedHashMap<>();
    private final JpaColumnSearch.DateBounds updated;
    private final String ordering;
    GoodsCostVersionQuery(Map<String,String> input,String status,String currency,String sort,String order) {
        searches=ColumnKeywordSearch.validate(input,KEYS);
        this.status=status==null||status.isBlank()?null:status;
        if(this.status!=null&&!Set.of("DRAFT","CONFIRMED").contains(this.status))throw invalid("成本方案状态无效");
        this.currency=currency==null||currency.isBlank()?null:currency;
        UUID parsed=null;
        if(this.currency!=null&&!this.currency.equals("__null__")) {
            try {parsed=UUID.fromString(this.currency);}catch(IllegalArgumentException error){throw invalid("币别筛选无效");}
        }
        currencyId=parsed;
        if((searches.containsKey("knownTotal")||"knownTotal".equals(sort))&&currencyId==null)
            throw invalid("请先选择币别，再比较或排序已知合计");
        for(String key:List.of("version","batchQty","knownTotal"))if(searches.containsKey(key))numeric.put(key,NumericColumnFilter.parse(searches.get(key)));
        updated=searches.containsKey("updatedAt")?JpaColumnSearch.businessDateBounds(searches.get("updatedAt")):null;
        if(order!=null&&!Set.of("asc","desc").contains(order))throw invalid("排序方向无效");
        Map<String,String> fields=Map.of("name","lower(s.input->>'name') COLLATE \"C\"","version","s.row_version",
                "batchQty",decimalSql("s.input->>'batchQty'"),"knownTotal",decimalSql("s.calculation->'totals'->>'knownTotal'"),
                "updatedAt","s.updated_at");
        if(sort==null||sort.isBlank())ordering="s.updated_at DESC,s.id";
        else {if(!fields.containsKey(sort))throw invalid("成本方案排序列无效");ordering=fields.get(sort)+("desc".equals(order)?" DESC":" ASC")+" NULLS LAST,s.updated_at DESC,s.id";}
    }
    String ordering(){return ordering;}
    boolean matches(VersionSummary row,boolean currencyFacet) {
        if(status!=null&&!status.equals(row.status()))return false;
        if(!currencyFacet&&currency!=null&&(currency.equals("__null__")?row.currencyId()!=null:!currencyId.equals(row.currencyId())))return false;
        if(!KeywordSearch.matches(searches.get("name"),row.name())||!KeywordSearch.matches(searches.get("unitName"),row.unitName()))return false;
        if(!currencyFacet&&!KeywordSearch.matches(searches.get("currencyName"),row.currencyName()))return false;
        for(var entry:numeric.entrySet()) {
            if(currencyFacet&&entry.getKey().equals("knownTotal"))continue;
            BigDecimal value=switch(entry.getKey()){case "version"->BigDecimal.valueOf(row.version());case "batchQty"->decimal(row.batchQty());default->decimal(row.knownTotal());};
            if(!entry.getValue().matches(value))return false;
        }
        OffsetDateTime at=row.updatedAt();
        return updated==null||at!=null&&!at.isBefore(updated.from())&&at.isBefore(updated.toExclusive());
    }
    private static BigDecimal decimal(String value){if(value==null||value.isBlank()||value.length()>256)return null;try{return new BigDecimal(value);}catch(NumberFormatException error){return null;}}
    private static String decimalSql(String source){return "CASE WHEN ("+source+") ~ '^[+-]?[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?$' THEN ("+source+")::numeric END";}
    private static ApiException invalid(String message){return new ApiException(ErrorCode.VALIDATION_FAILED,message);}
}
