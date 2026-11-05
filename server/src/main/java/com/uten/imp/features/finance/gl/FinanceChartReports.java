package com.uten.imp.features.finance.gl;

import com.uten.imp.features.finance.report.*;
import jakarta.persistence.EntityManager;
import java.util.*;

/** Both chart exports use the existing protected, snapshot-bound finance export pipeline. */
public final class FinanceChartReports {
    private FinanceChartReports() { }

    /** The directory keeps its displayed category and ordered mapping captions, rather than the audit-code schema. */
    public static ReportTableResponse directory(EntityManager em,int page,int size,FinanceReportColumnOptions options,String keyword) {
        var columns=List.of(ReportColumn.text("code","科目编码"),ReportColumn.text("name","科目名称"),
                ReportColumn.text("currencyName","外币名称"),ReportColumn.text("classification","类别"),
                ReportColumn.text("targets","对应科目"));
        var classification=new StringBuilder("CASE c.classification ");
        for(var group:FinanceTemplateContract.template("chartCodes").path("classifications")) {
            classification.append("WHEN '").append(group.path("id").asText().replace("'","''"))
                    .append("' THEN '").append(group.path("label").asText().replace("'","''")).append("' ");
        }
        classification.append("ELSE '待维护' END");
        boolean searched=keyword!=null&&!keyword.isBlank();
        String source="SELECT c.code,c.name,NULLIF(c.currency_name,'') AS \"currencyName\","
                +classification+" AS classification,"
                +" string_agg(s.code||' '||s.name,'；' ORDER BY s.path,s.id) FILTER (WHERE s.id IS NOT NULL) AS targets,c.sort_order"
                +" FROM finance_chart_codes c LEFT JOIN finance_chart_code_styles m ON m.code=c.code"
                +" LEFT JOIN payment_styles s ON s.id=m.style_id"
                +(searched?" WHERE "+com.uten.imp.common.util.TaskKeywordSearch.conditionParameter("directoryKeyword","c.code","c.name"):"")
                +" GROUP BY c.code,c.name,c.currency_name,c.classification,c.sort_order";
        return FinanceProjectedReportTable.query(em,columns,source,
                query->{if(searched)query.setParameter("directoryKeyword",com.uten.imp.common.util.KeywordSearch.phrase(keyword));},
                "report.sort_order,report.code",options.filters(),Set.of("code","name","currencyName","classification","targets"),
                page,size,options.sort(),options.order(),false,List.of());
    }
    public static ReportTableResponse read(EntityManager em,boolean template,int page,int size,FinanceReportColumnOptions options) {
        if(template) {
            var columns=List.of(ReportColumn.text("code","科目编码"),ReportColumn.text("name","科目名称"),
                    ReportColumn.text("currency","外币名称"),ReportColumn.money("d0","期初借方"),ReportColumn.money("c0","期初贷方"),
                    ReportColumn.money("d","本期发生借方"),ReportColumn.money("c","本期发生贷方"),
                    ReportColumn.money("d1","期末借方"),ReportColumn.money("c1","期末贷方"));
            return new ReportTableResponse(columns,List.of(),Map.of(),1,1,0,0);
        }
        var columns=List.of(ReportColumn.text("code","科目编码"),ReportColumn.text("name","科目名称"),
                ReportColumn.text("currency","外币名称"),ReportColumn.text("styleIds","系统科目UUID"),
                ReportColumn.text("styleCodes","系统科目编号"),ReportColumn.text("styleNames","系统科目名称"),
                ReportColumn.text("status","对应状态"));
        return FinanceProjectedReportTable.query(em,columns,"""
                SELECT c.code,c.name,c.currency_name AS currency,
                    string_agg(s.id::text,'、' ORDER BY s.id) AS "styleIds",
                    string_agg(s.code,'、' ORDER BY s.id) AS "styleCodes",
                    string_agg(s.name,'、' ORDER BY s.id) AS "styleNames",
                    CASE WHEN count(s.id)>0 THEN '已对应' ELSE '未对应' END AS status,c.sort_order
                FROM finance_chart_codes c LEFT JOIN finance_chart_code_styles m ON m.code=c.code
                LEFT JOIN payment_styles s ON s.id=m.style_id
                GROUP BY c.code,c.name,c.currency_name,c.sort_order
                """,q->{},"report.sort_order,report.code",options.filters(),Set.of("status"),page,size,options.sort(),options.order(),false,List.of());
    }
}
