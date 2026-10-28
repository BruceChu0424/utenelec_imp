package com.uten.imp.features.finance.report;

import java.util.Map;

/** Immutable explicit read conditions shared by finance report adapters and export dispatch. */
public record FinanceReportColumnOptions(Map<String,String> filters,String sort,String order) {
    public static final FinanceReportColumnOptions NONE=new FinanceReportColumnOptions(Map.of(),null,null);
    public FinanceReportColumnOptions { filters=filters==null?Map.of():Map.copyOf(filters); }
    public static FinanceReportColumnOptions from(Map<String,String> parameters,String sort,String order){
        return new FinanceReportColumnOptions(FinanceReportHeaderRequest.filters(parameters==null?Map.of():parameters),sort,order);
    }
    public static FinanceReportColumnOptions current(){var values=FinanceReportHeaderRequest.current();return from(values,values.get("sort"),values.get("order"));}
}
