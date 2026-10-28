package com.uten.imp.features.finance.arap;

import com.uten.imp.common.util.ColumnKeywordSearch;
import com.uten.imp.common.util.JpaColumnSearch;
import com.uten.imp.common.util.KeywordSearch;
import com.uten.imp.common.util.NameRefKeyword;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.finance.arap.dto.ArApLedgerQueryFilter;
import jakarta.persistence.criteria.*;
import java.math.BigDecimal;
import java.util.*;

/** Fixed ledger facts; source references match as complete groups and never replace hydrated evidence. */
public final class ArApLedgerHeaderQuery {
    private ArApLedgerHeaderQuery() {}
    public static final Map<Short,String> SETTLEMENT_STYLES=Map.of(
            (short)1,"现金",(short)2,"提货",(short)3,"代付",(short)4,"支票",
            (short)6,"月结",(short)7,"垫付",(short)8,"汇款",(short)10,"代收");
    private static final Map<String,String> RESOLUTIONS=Map.of(
            "EXACT_SOURCE","原单唯一匹配","AMBIGUOUS_SOURCE","原单有多个匹配",
            "MISSING_OR_CONFLICTING_SOURCE","找不到原单，或原单对应关系有矛盾","UNVERIFIED_SOURCE_KIND","来源类型待核验");
    private static final Set<String> OPEN_KINDS=Set.of("RECEIVABLE","PAYABLE","CREDIT","CLAIM_CREDIT","PREPAYMENT","CUSTOMER_PREPAYMENT","LEGACY_UNVERIFIED");
    private static final Set<String> ORIGINAL_AMOUNTS=Set.of("amountOriginal","amountReceivedOriginal","amountWriteOffOriginal","amountBalanceOriginal","prepaymentAppliedOriginal");
    private static final Map<String,JpaColumnSearch.Field> FIELDS=Map.ofEntries(
            Map.entry("billNo",JpaColumnSearch.Field.text("billNo")),Map.entry("sourceDocNo",JpaColumnSearch.Field.text("sourceDocNo")),
            Map.entry("party",JpaColumnSearch.Field.text((root,query,cb)->{
                var client=JpaColumnSearch.Field.referenceText("clientId",com.uten.imp.features.master.client.Client.class,"name").expression().build(root,query,cb);
                var supplier=JpaColumnSearch.Field.referenceText("supplierId",com.uten.imp.features.master.supplier.Supplier.class,"name").expression().build(root,query,cb);
                return cb.<String>selectCase().when(cb.equal(root.get("direction"),"AR"),client.as(String.class))
                        .when(cb.equal(root.get("direction"),"AP"),supplier.as(String.class)).otherwise("—");
            })),
            Map.entry("billDate",JpaColumnSearch.Field.calendarDate("billDate")),Map.entry("dueDate",JpaColumnSearch.Field.calendarDate("dueDate")),
            Map.entry("exchangeRate",JpaColumnSearch.Field.decimal("exchangeRate")),
            Map.entry("amountOriginal",JpaColumnSearch.Field.decimal("amountOriginal")),
            Map.entry("amountReceivedOriginal",JpaColumnSearch.Field.decimal("amountReceivedOriginal")),
            Map.entry("amountWriteOffOriginal",JpaColumnSearch.Field.decimal("amountWriteOffOriginal")),
            Map.entry("amountBalanceOriginal",JpaColumnSearch.Field.decimal("amountBalanceOriginal")),
            Map.entry("prepaymentAppliedOriginal",JpaColumnSearch.Field.decimal((root,query,cb)->cb.<BigDecimal>selectCase()
                    .when(cb.equal(root.get("direction"),"AR"),root.get("amountOffsetOriginal")).otherwise(cb.nullLiteral(BigDecimal.class)))),
            Map.entry("amountBalance",JpaColumnSearch.Field.decimal("amountBalance")),Map.entry("remark",JpaColumnSearch.Field.text("remark")),
            Map.entry("settlementStyleLegacy",JpaColumnSearch.Field.text((root,query,cb)->{
                var result=cb.<String>selectCase();SETTLEMENT_STYLES.forEach((code,label)->result.when(cb.equal(root.get("settlementStyleLegacy"),code),label));
                return result.otherwise("未设置");
            })),
            Map.entry("legacySourceResolution",JpaColumnSearch.Field.text((root,query,cb)->{
                var status=resolution(root,cb);var result=cb.<String>selectCase();RESOLUTIONS.forEach((code,label)->result.when(cb.equal(status,code),label));
                return result.otherwise("—");
            })));
    public static String settlementLabel(Short code){return code==null?"未设置":SETTLEMENT_STYLES.getOrDefault(code,"未设置");}
    public static void requireMonetaryScope(ArApLedgerQueryFilter filter,String sort) {
        Map<String,String> columns=filter.columnQuery();
        boolean original=columns.entrySet().stream().anyMatch(entry->entry.getKey().startsWith("search.")
                &&ORIGINAL_AMOUNTS.contains(entry.getKey().substring(7))&&entry.getValue()!=null&&!entry.getValue().isBlank());
        if(filter.currencyId()==null&&(original||sort!=null&&ORIGINAL_AMOUNTS.contains(sort)))
            throw invalid("按原币金额筛选或排序前，请先选择币种");
        if("AP".equals(filter.direction())&&has(columns,"search.prepaymentAppliedOriginal"))
            throw invalid("预收已抵列只适用于应收台账");
        if("prepaymentAppliedOriginal".equals(sort)&&!"AR".equals(filter.direction()))
            throw invalid("预收已抵排序前，请先选择应收台账");
    }
    public static Predicate predicate(Root<ArApLedger> root,CriteriaQuery<?> query,CriteriaBuilder cb,ArApLedgerQueryFilter filter) {
        requireMonetaryScope(filter,null);
        var columns=filter.columnQuery();var input=new LinkedHashMap<String,String>();
        columns.forEach((key,value)->{if(key.startsWith("search."))input.put(key.substring(7),value);});
        var allowed=new HashSet<>(FIELDS.keySet());allowed.add("salesOrderNos");
        var searches=new LinkedHashMap<>(ColumnKeywordSearch.validate(input,allowed));
        String orders=searches.remove("salesOrderNos");List<Predicate> predicates=new ArrayList<>();
        predicates.add(JpaColumnSearch.predicate(root,query,cb,searches,FIELDS));
        for(String term:KeywordSearch.terms(orders)) {
            var match=query.subquery(Integer.class);var source=match.from(ArApSourceRef.class);
            match.select(cb.literal(1)).where(cb.equal(source.get("ledgerId"),root.get("id")),
                    cb.equal(source.get("sourceType"),"SALES_ORDER"),NameRefKeyword.text(cb,source.get("sourceNo"),NameRefKeyword.like(term)));
            predicates.add(cb.exists(match));
        }
        String kind=choice(columns.get("openItemKind"),OPEN_KINDS);if(kind!=null)predicates.add(cb.equal(root.get("openItemKind"),kind));
        String style=trim(columns.get("settlementStyleLegacy"));
        if(style!=null) {
            if(style.equals("UNSET"))predicates.add(cb.or(cb.isNull(root.get("settlementStyleLegacy")),cb.not(root.get("settlementStyleLegacy").in(SETTLEMENT_STYLES.keySet()))));
            else {
                Short code;
                try{code=Short.valueOf(style);}catch(NumberFormatException failure){throw invalid("结账方式选项无效");}
                if(!SETTLEMENT_STYLES.containsKey(code))throw invalid("结账方式选项无效");
                predicates.add(cb.equal(root.get("settlementStyleLegacy"),code));
            }
        }
        String resolved=trim(columns.get("legacySourceResolution"));
        if(resolved!=null) {
            var status=resolution(root,cb);
            if(resolved.equals("UNSET"))predicates.add(cb.or(cb.isNull(status),cb.not(status.in(RESOLUTIONS.keySet()))));
            else predicates.add(cb.equal(status,choice(resolved,RESOLUTIONS.keySet())));
        }
        return cb.and(predicates.toArray(new Predicate[0]));
    }
    private static Expression<String> resolution(Root<?> root,CriteriaBuilder cb){return cb.function("jsonb_extract_path_text",String.class,root.get("legacySourceResolution"),cb.literal("status"));}
    private static boolean has(Map<String,String> values,String key){return trim(values.get(key))!=null;}
    private static String trim(String value){return value==null||value.isBlank()?null:value.strip();}
    private static String choice(String raw,Set<String> allowed){String value=trim(raw);if(value!=null&&!allowed.contains(value))throw invalid("台账候选条件无效");return value;}
    private static ApiException invalid(String text){return new ApiException(ErrorCode.VALIDATION_FAILED,text);}
}
