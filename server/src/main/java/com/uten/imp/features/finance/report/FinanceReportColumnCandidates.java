package com.uten.imp.features.finance.report;

import com.uten.imp.common.web.*;
import jakarta.persistence.EntityManager;
import jakarta.persistence.Query;
import java.util.*;
import java.util.function.Consumer;

/** One visible text column of the owning completed report projection, before row pagination. */
public final class FinanceReportColumnCandidates implements AutoCloseable {
    private static final ThreadLocal<FinanceReportColumnCandidates> CURRENT=new ThreadLocal<>();
    private final FinanceReportColumnCandidates previous;
    private final String column;
    private final Map<String,Long> records=new LinkedHashMap<>();
    private boolean completed;
    private FinanceReportColumnCandidates(String column) {
        if(column==null||!column.matches("[A-Za-z][A-Za-z0-9]{0,79}"))throw invalid();
        this.column=column;previous=CURRENT.get();CURRENT.set(this);
    }
    public static FinanceReportColumnCandidates open(String column){return new FinanceReportColumnCandidates(column);}
    public static FinanceReportColumnCandidates current(){return CURRENT.get();}
    public String column(){return column;}
    public boolean completed(){return completed;}
    public void requireVisibleText(List<ReportColumn> columns,Set<String> excluded) {
        if(excluded.contains(column)||columns.stream().noneMatch(c->c.key().equals(column)&&c.type().equals("text")))throw invalid();
    }
    public void readSql(EntityManager em,List<ReportColumn> columns,Set<String> excluded,String filtered,
                        Consumer<Query> bind) {
        requireVisibleText(columns,excluded);
        // Build the SQL identifier from the server-owned whitelist entry, never from the request string.
        String resolved=columns.stream().filter(c->c.key().equals(column)&&c.type().equals("text")).map(ReportColumn::key).findFirst().orElseThrow(FinanceReportColumnCandidates::invalid);
        String value="report.\""+resolved+"\"";
        var query=NativeFacets.query(em,"value","SELECT CAST("+value+" AS text),COUNT(*) FROM ("+filtered+") report WHERE "+value+" IS NOT NULL AND btrim(CAST("+value+" AS text))<>'' GROUP BY "+value);
        bind.accept(query);NativeFacets.rowsOf(query);completed=true;
    }
    public void addRecord(Map<String,Object> row){
        Object value=row.get(column);if(value!=null)records.merge(value.toString(),1L,Long::sum);
    }
    public void finishRecords(List<ReportColumn> columns){
        requireVisibleText(columns,Set.of());NativeFacetCandidates.current().completeRecords(records);completed=true;
    }
    public void readComplete(ReportTableResponse report){
        if(completed)return;
        if(report.total()<0||report.total()>report.rows().size())throw new IllegalStateException("Report candidates require the complete owning projection");
        report.rows().forEach(this::addRecord);finishRecords(report.columns());
    }
    @Override public void close(){if(previous==null)CURRENT.remove();else CURRENT.set(previous);}
    private static ApiException invalid(){return new ApiException(ErrorCode.VALIDATION_FAILED,"此报表不支持该文本候选列");}
}
