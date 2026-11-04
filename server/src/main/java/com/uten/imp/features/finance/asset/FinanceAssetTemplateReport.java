package com.uten.imp.features.finance.asset;

import com.uten.imp.features.finance.gl.FinanceTemplateContract;
import com.uten.imp.features.finance.report.*;
import jakarta.persistence.EntityManager;
import java.time.LocalDate;
import java.util.*;

/** September source sheets, including their hidden month columns and blank separators. */
final class FinanceAssetTemplateReport {
    private FinanceAssetTemplateReport() { }

    static ReportTableResponse query(EntityManager em,boolean deferred,boolean completed,LocalDate cutoff,
            int page,int size,FinanceReportColumnOptions options) {
        String template=deferred?"amortization":completed?"depreciationCompleted":"depreciation";
        var fields=fields(deferred,completed,completed?2026:cutoff.getYear());
        List<ReportColumn> columns=new ArrayList<>();
        for(int index=0;index<fields.size();index++) {
            var field=fields.get(index);
            String label=java.util.regex.Pattern.compile("202[3-6]")
                    .matcher(FinanceTemplateContract.header(template,index))
                    .replaceAll(match->Integer.toString(Integer.parseInt(match.group())+(completed?0:cutoff.getYear()-2026)));
            var column=new ReportColumn(field.key,label,field.type,field.type.equals("text")?150:130);
            if(field.type.equals("money"))column=column.withUnitLabel("元");
            columns.add(column.withHeaderGroups(FinanceTemplateContract.headerGroups(template,index)));
        }
        var projected=new ArrayList<>(columns);
        projected.add(ReportColumn.text("__assetId","",1));
        projected.add(ReportColumn.text("__assetType","",1));
        projected.add(ReportColumn.bool("__pending",""));
        projected.add(ReportColumn.text("__basis","",1));
        projected.add(ReportColumn.text("__sourceSheet","",1));
        String selected=String.join(",\n",fields.stream().map(f->f.expression+" AS \""+f.key+"\"").toList());
        String amount=deferred?"a.total_amount":"COALESCE(b.original_value,a.original_value)";
        String opening=deferred?"a.opening_amortized_amount":"COALESCE(b.opening_accumulated_amount,a.opening_accumulated_amount,0)";
        String known=deferred?"s.id IS NOT NULL":"b.id IS NOT NULL";
        String start=deferred?"s.start_period":"COALESCE(b.start_period,a.start_period)";
        String liveFrom=deferred?"CASE WHEN a.opening_as_of IS NOT NULL THEN a.service_start_on ELSE a.recognized_on END":"CASE WHEN a.opening_as_of IS NOT NULL THEN a.acquired_on ELSE a.capitalized_on END";
        String lifecycleEnd=deferred?"a.terminated_on":"a.disposed_on";
        String objectType=deferred?"DEFERRED_EXPENSE":"FIXED_ASSET";
        String join=deferred?"""
                LEFT JOIN LATERAL (SELECT v.* FROM finance_deferral_schedule_versions v WHERE v.deferred_id=a.id
                  AND NOT v.is_deleted AND v.status IN('APPROVED','TERMINATED','SUPERSEDED')
                  AND v.approved_at::date<=:cutoff ORDER BY v.version DESC LIMIT 1) s ON TRUE
                """:"""
                LEFT JOIN finance_asset_books b ON b.asset_id=a.id AND b.book_type='CORPORATE' AND NOT b.is_deleted
                """;
        String pending="(NOT COALESCE(meta.confirmed,false) OR facts.pending OR NOT ("+known+")"+
                " OR EXISTS(SELECT 1 FROM template_facts h WHERE h.object_id=a.id AND h.kind='"+(deferred?"DA":"FA")+"' AND h.fact_kind='HISTORY' AND h.pending)"+
                " OR ("+opening+"<>0 AND NOT EXISTS(SELECT 1 FROM template_facts h WHERE h.object_id=a.id AND h.kind='"+(deferred?"DA":"FA")+"' AND h.fact_kind='HISTORY')))";
        String cumulativeBalance="CASE WHEN a.opening_as_of>:cutoff THEN "+sum(null,null,deferred)+" ELSE "+opening+"+facts.accumulated END";
        String source="""
                WITH template_facts AS MATERIALIZED (SELECT * FROM v_finance_asset_report_facts)
                SELECT %s,a.id AS "__assetId",'%s'::text AS "__assetType",%s AS "__pending",
                  CASE WHEN %s THEN '原表资料、冻结账簿或计提凭证依据待核对；未计提和未取得历史月份保持空白'
                    ELSE '企业账实际有符号计提；原计提、红冲和再次计提按凭证日期合计，计划额不冒充月发生' END AS "__basis",
                  '%s'::text AS "__sourceSheet"
                FROM %s a
                %s
                LEFT JOIN finance_asset_categories category ON category.id=a.category_id
                LEFT JOIN finance_asset_opening_members opening_member ON opening_member.object_id=a.id AND opening_member.object_type='%s' AND opening_member.active
                LEFT JOIN LATERAL (SELECT m.* FROM finance_asset_template_metadata m WHERE m.object_type='%s'
                  AND m.object_id=a.id AND m.valid_from<=:cutoff ORDER BY m.valid_from DESC LIMIT 1) meta ON TRUE
                LEFT JOIN LATERAL (
                  SELECT COALESCE(sum(f.amount_local) FILTER(WHERE NOT f.pending),0) AS accumulated,
                    COALESCE(bool_or(f.pending),false) AS pending
                  FROM v_finance_asset_posting_facts f WHERE f.object_id=a.id AND f.kind='%s' AND f.business_date<=:cutoff
                ) facts ON TRUE
                LEFT JOIN LATERAL (
                  SELECT CASE WHEN facts.pending THEN NULL ELSE %s END AS accumulated,
                    CASE WHEN facts.pending OR NOT(%s) THEN NULL ELSE %s-(%s) END AS remaining,
                    %s AS start_period
                ) balance ON TRUE
                WHERE NOT a.is_deleted AND %s<=:cutoff
                  AND (a.recognition_reversed_on IS NULL OR a.recognition_reversed_on>:cutoff)
                  AND (%s IS NULL OR %s>:cutoff)
                %s
                """.formatted(selected,objectType,pending,pending,
                    FinanceTemplateContract.template(template).path("sourceSheet").asText().replace("'","''"),
                    deferred?"deferred_expenses":"fixed_assets",join,objectType,objectType,deferred?"DA":"FA",cumulativeBalance,known,
                    amount,cumulativeBalance,start,liveFrom,lifecycleEnd,lifecycleEnd,
                    deferred?"":(completed?" AND EXISTS":" AND NOT EXISTS")+"(SELECT 1 FROM finance_asset_opening_members m JOIN finance_asset_opening_groups g ON g.id=m.group_id JOIN finance_template_sources source ON source.id=g.source_import_id WHERE m.object_type='FIXED_ASSET' AND m.object_id=a.id AND m.active AND source.template_key='depreciationCompleted')");
        return FinanceProjectedReportTable.query(em,projected,source,q->q.setParameter("cutoff",cutoff),
                "report.\"assetName\",report.\"__assetId\"",options.filters(),deferred?Set.of("sourceMonth","usage","categoryCaption","expenseCaption"):Set.of("sourceMonth","location","usage","categoryCaption","expenseCaption"),
                page,size,options.sort(),options.order(),false,List.of());
    }

    record Field(String key,String type,String expression) { }
    private static List<Field> fields(boolean deferred,boolean completed,int year) {
        List<Field> f=new ArrayList<>();
        add(f,"sourceMonth","text","NULLIF(meta.source_month,'')");
        if(deferred) {
            add(f,"partyName","text","NULLIF(meta.party_name,'')");
            add(f,"assetName","text","a.name");
            add(f,"usage","text","NULLIF(meta.usage_caption,'')");
            add(f,"categoryCaption","text","COALESCE(NULLIF(meta.category_caption,''),category.name)");
            add(f,"documentDate","date","COALESCE(meta.document_date,a.source_document_date)");
            add(f,"totalAmount","money","a.total_amount");
            add(f,"usefulYears","number","a.useful_months/12.0");
            add(f,"monthlyAmt","money","CASE WHEN s.method='STRAIGHT_LINE' THEN COALESCE(opening_member.nominal_monthly_amount,s.nominal_monthly_amount) END");
            months(f,year,12,1,true);add(f,"expenseCaption","text","NULLIF(meta.first_level_caption,'')");
            add(f,"secondLevelCaption","text","NULLIF(meta.second_level_caption,'')");
            add(f,"accumAmt","money",rangeSum(year-1,year,true));
            add(f,"remain","money","balance.remaining");
            add(f,"dueDate","date","(COALESCE(meta.document_date,a.source_document_date)+a.useful_months*interval '1 month')::date");
            add(f,"acceptance","text","NULLIF(meta.acceptance_caption,'')");
            add(f,"separator1","text","NULL::text");add(f,"separator2","text","NULL::text");
            months(f,year-1,12,1,true);add(f,"priorYearAccum","money",rangeSum(year-1,year-1,true));
        } else {
            add(f,"location","text","CASE WHEN meta.id IS NOT NULL THEN meta.location_caption ELSE a.location_text END");
            add(f,"partyName","text","NULLIF(meta.party_name,'')");
            add(f,"usage","text","NULLIF(meta.usage_caption,'')");
            add(f,"categoryCaption","text","COALESCE(NULLIF(meta.category_caption,''),category.name)");
            add(f,"assetName","text","a.name");
            add(f,"unitSpecification","text","NULLIF(meta.unit_specification,'')");
            add(f,"acquiredOn","date","a.acquired_on");
            add(f,"originalValue","money","COALESCE(b.original_value,a.original_value)");
            add(f,"usefulYears","number","a.useful_months/12.0");
            add(f,"monthlyDep","money","CASE WHEN b.method='STRAIGHT_LINE' THEN COALESCE(opening_member.nominal_monthly_amount,b.regular_monthly_amount) END");
            months(f,completed?year-1:year,12,1,false);months(f,completed?year-2:year-1,12,1,false);
            add(f,"accumDep","money",rangeSum(year-2,completed?year-1:year,false));
            add(f,"expenseCaption","text","NULLIF(meta.first_level_caption,'')");
            add(f,"dueDate","date","(a.acquired_on+a.useful_months*interval '1 month')::date");
            add(f,"acceptance","text","NULLIF(meta.acceptance_caption,'')");
            if(!completed) {
                add(f,"netValue","money","balance.remaining");add(f,"separator1","text","NULL::text");
                months(f,year-2,12,1,false);add(f,"priorYearAccum","money",rangeSum(year-2,year-2,false));
                add(f,"olderAccum","money",sum(null,(year-3)+"-12",false));
            }
        }
        return List.copyOf(f);
    }
    private static void add(List<Field> f,String key,String type,String expression){f.add(new Field(key,type,expression));}
    private static void months(List<Field> f,int year,int first,int last,boolean deferred) {
        for(int m=first;m>=last;m--) {
            String period=String.format(Locale.ROOT,"%04d-%02d",year,m);
            // A missing posting is blank, and an opening total never invents a historical month.
            add(f,"month"+year+String.format(Locale.ROOT,"%02d",m),"money",
                    "CASE WHEN DATE '"+period+"-01'>:cutoff THEN NULL "+
                    "ELSE "+sum(period,period,deferred)+" END");
        }
    }
    private static String rangeSum(int first,int last,boolean deferred) {
        return sum(first+"-01",last+"-12",deferred);
    }
    private static String sum(String from,String to,boolean deferred) {
        String upper=to==null?"to_char(CAST(:cutoff AS date),'YYYY-MM')":"LEAST('"+to+"',to_char(CAST(:cutoff AS date),'YYYY-MM'))";
        String full=(from==null?"TRUE":"f.period_from IS NOT NULL AND f.period_from>='"+from+"'")+" AND f.period_to<="+upper;
        String overlap=(from==null?"TRUE":"f.period_to>='"+from+"'")+" AND (f.period_from IS NULL OR f.period_from<="+upper+")";
        String base="f.object_id=a.id AND f.kind='"+(deferred?"DA":"FA")+"'";
        String opening=deferred?"a.opening_amortized_amount":"a.opening_accumulated_amount";
        String unknown="("+opening+"<>0 AND NOT EXISTS(SELECT 1 FROM template_facts h WHERE h.object_id=a.id AND h.kind='"+(deferred?"DA":"FA")+"' AND h.fact_kind='HISTORY'))";
        return "CASE WHEN "+unknown+" THEN NULL ELSE (SELECT CASE WHEN bool_or(f.pending OR NOT("+full+") OR (f.fact_kind='HISTORY' AND f.fact_date>:cutoff)) THEN NULL ELSE "+
                (Objects.equals(from,to)&&from!=null?"sum(f.amount_local)":"COALESCE(sum(f.amount_local),0)")+" END FROM template_facts f WHERE "+base+" AND "+overlap+" AND (f.fact_kind='HISTORY' OR f.fact_date<=:cutoff)) END";
    }
}
