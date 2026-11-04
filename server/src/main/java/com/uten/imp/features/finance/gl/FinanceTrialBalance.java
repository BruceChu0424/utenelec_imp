package com.uten.imp.features.finance.gl;

import com.uten.imp.features.finance.report.*;
import com.uten.imp.common.web.*;
import jakarta.persistence.EntityManager;
import java.time.LocalDate;
import java.util.*;

/** Original nine-column contract. All amounts here are ledger local amounts, never guessed FX values. */
final class FinanceTrialBalance {
    private FinanceTrialBalance() { }
    static List<ReportColumn> columns() {
        return List.of(ReportColumn.text("styleCode","科目编码",110),ReportColumn.text("styleName","科目名称",240),
                ReportColumn.text("currencyName","外币名称",90),ReportColumn.money("openingDebit","期初借方"),
                ReportColumn.money("openingCredit","期初贷方"),ReportColumn.money("debit","本期发生借方"),
                ReportColumn.money("credit","本期发生贷方"),ReportColumn.money("closingDebit","期末借方"),
                ReportColumn.money("closingCredit","期末贷方"));
    }
    static ReportTableResponse read(EntityManager em,LocalDate from,LocalDate to,int page,int size,FinanceReportColumnOptions options) {
        if(from==null||to==null||from.isAfter(to))throw new ApiException(ErrorCode.VALIDATION_FAILED,"请选择完整且先后正确的会计期间");
        var projected=new ArrayList<>(columns());projected.add(ReportColumn.text("__basis","",1));
        projected.add(new ReportColumn("__order","","int",1));
        projected.add(ReportColumn.bool("__pending","",1));
        projected.add(ReportColumn.text("__classification","",1));
        projected.add(new ReportColumn("__sectionOrder","","int",1));
        projected.add(new ReportColumn("__band","","int",1));
        projected.add(ReportColumn.text("__rowKind","",1));
        boolean opening=FinancialLedgerReadScope.asOf(em,from.minusDays(1)).complete(),closing=FinancialLedgerReadScope.asOf(em,to).complete(),movement=FinancialLedgerReadScope.range(em,from,to).complete();
        // Projection order is the declared nine columns followed by metadata.
        // Putting an order key before the six amounts shifts every numeric cell.
        String guarded="SELECT \"styleCode\",\"styleName\",\"currencyName\","
                +"CASE WHEN :opening THEN \"openingDebit\" END AS \"openingDebit\",CASE WHEN :opening THEN \"openingCredit\" END AS \"openingCredit\","
                +"CASE WHEN :movement THEN debit END AS debit,CASE WHEN :movement THEN credit END AS credit,"
                +"CASE WHEN :closing THEN \"closingDebit\" END AS \"closingDebit\",CASE WHEN :closing THEN \"closingCredit\" END AS \"closingCredit\","
                +"concat_ws('；',\"__basis\",CASE WHEN NOT :opening THEN '期初依据尚未完整核对' END,CASE WHEN NOT :movement THEN '期间发生额尚未完整核对' END,CASE WHEN NOT :closing THEN '期末依据尚未完整核对' END) AS \"__basis\","
                +"\"__order\",\"__pending\" OR NOT(:opening AND :movement AND :closing) AS \"__pending\",\"__classification\" FROM ("+sql()+") source";
        return FinanceProjectedReportTable.query(em,projected,presentationSql(guarded),q->{q.setParameter("from",from);q.setParameter("to",to);q.setParameter("opening",opening);q.setParameter("movement",movement);q.setParameter("closing",closing);},
                "report.\"__sectionOrder\",report.\"__band\",report.\"__order\",report.\"styleCode\",report.\"styleName\"",options.filters(),Set.of(),page,size,options.sort(),options.order(),true,List.of());
    }

    /** Source subtotals only sum detail, never previously calculated totals. */
    static String presentationSql(String detailSql) {
        var template=FinanceTemplateContract.template("trialBalance");
        var classes=new ArrayList<String>();int section=0;
        for(var item:template.required("classifications"))classes.add("("+literal(item.required("id").asText())+","+(++section)+","+literal(item.required("totalLabel").asText())+")");
        var currencyRows=new ArrayList<String>();
        for(var row:template.path("currencyRows")){
            int after=row.required("after").asText().equals("GRAND_TOTAL")?7:1;
            currencyRows.add("SELECT "+aggregateColumns(literal(row.required("label").asText()),"'CURRENCY'",Integer.toString(after),"2")
                    +" FROM detail WHERE \"currencyName\"="+literal(row.required("label").asText())
                    +(after==1?" AND \"__classification\"='ASSET'":"")+" HAVING count(*)>0");
        }
        return "WITH detail AS ("+detailSql+"), classes(classification,ordinal,label) AS (VALUES "+String.join(",",classes)+") "
                +"SELECT detail.*,COALESCE(classes.ordinal,6) AS \"__sectionOrder\",0 AS \"__band\",'DETAIL'::text AS \"__rowKind\" FROM detail LEFT JOIN classes ON classes.classification=detail.\"__classification\" "
                +"UNION ALL SELECT "+aggregateColumns("classes.label","'SUBTOTAL'","classes.ordinal","1")+" FROM detail JOIN classes ON classes.classification=detail.\"__classification\" GROUP BY classes.classification,classes.ordinal,classes.label "
                +"UNION ALL SELECT "+aggregateColumns(literal(template.required("totalLabel").asText()),"'TOTAL'","7","1")+" FROM detail HAVING count(*)>0 "
                +(currencyRows.isEmpty()?"":"UNION ALL "+String.join(" UNION ALL ",currencyRows));
    }
    private static String aggregateColumns(String label,String kind,String section,String band){
        var amounts=new ArrayList<String>();for(String key:List.of("openingDebit","openingCredit","debit","credit","closingDebit","closingCredit"))
            amounts.add("CASE WHEN count(*) FILTER(WHERE detail.\""+key+"\" IS NULL)>0 THEN NULL ELSE sum(detail.\""+key+"\") END");
        return "''::text,"+label+",''::text,"+String.join(",",amounts)+",'原表所列科目本币金额；分类小计、合计及美元行分别从科目明细归集，不重复相加'::text,2147483647,bool_or(detail.\"__pending\"),NULL::text,"+section+","+band+","+kind;
    }
    private static String literal(String text){return "'"+text.replace("'","''")+"'";}
    static String sql() {
        return """
                WITH entries AS (
                    SELECT style_id,
                        SUM(CASE WHEN entry_date<:from THEN direction*amount ELSE 0 END) AS opening_net,
                        SUM(CASE WHEN entry_date>=:from AND direction=1 THEN amount ELSE 0 END) AS debit,
                        SUM(CASE WHEN entry_date>=:from AND direction=-1 THEN amount ELSE 0 END) AS credit
                    FROM gl_entries e JOIN gl_vouchers voucher ON voucher.id=e.voucher_id AND fn_finance_gl_voucher_is_booked(voucher.id)
                    WHERE NOT e.is_deleted AND entry_date<=:to GROUP BY style_id
                ), accounts AS (
                    SELECT c.code,c.name,c.currency_name,c.sort_order,c.classification,
                        count(m.style_id)>0 AS known,
                        SUM(COALESCE(e.opening_net,0)) AS opening_net,
                        SUM(COALESCE(e.debit,0)) AS debit,SUM(COALESCE(e.credit,0)) AS credit,
                        CASE WHEN count(m.style_id)=0 THEN '待对应系统科目，金额未知'
                             ELSE '按已对应系统科目UUID归集本币总账' END AS basis
                    FROM finance_chart_codes c LEFT JOIN finance_chart_code_styles m ON m.code=c.code
                    LEFT JOIN entries e ON e.style_id=m.style_id
                    GROUP BY c.code,c.name,c.currency_name,c.sort_order,c.classification
                    UNION ALL
                    SELECT s.code,s.name,''::text,2147483647,CASE WHEN s.category IN('INCOME','EXPENSE') THEN 'PROFIT' WHEN s.category IN('LIABILITY','EQUITY') THEN s.category END,true,e.opening_net,e.debit,e.credit,
                        '尚未对应财务代码；保留系统科目本币事实，不能遗漏'
                    FROM entries e JOIN payment_styles s ON s.id=e.style_id
                    WHERE NOT EXISTS(SELECT 1 FROM finance_chart_code_styles m WHERE m.style_id=s.id)
                )
                SELECT code AS "styleCode",name AS "styleName",currency_name AS "currencyName",
                    CASE WHEN known THEN GREATEST(opening_net,0) END AS "openingDebit",
                    CASE WHEN known THEN GREATEST(-opening_net,0) END AS "openingCredit",
                    CASE WHEN known THEN debit END AS debit,CASE WHEN known THEN credit END AS credit,
                    CASE WHEN known THEN GREATEST(opening_net+debit-credit,0) END AS "closingDebit",
                    CASE WHEN known THEN GREATEST(-opening_net-debit+credit,0) END AS "closingCredit",
                    basis AS "__basis",sort_order AS "__order",NOT known AS "__pending",classification AS "__classification"
                FROM accounts
                """;
    }
}
