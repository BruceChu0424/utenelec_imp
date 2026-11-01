package com.uten.imp.features.sales;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.sales.order.dto.SalesOrderFinanceReviewDto;
import com.uten.imp.features.sales.quote.dto.QuoteFinanceReviewDto;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** Stage-neutral transport over the shared review renderer. Management approval is never named finance approval. */
@Component
@RequiredArgsConstructor
public class SalesManagerReviewProjection {
    private final ObjectMapper mapper;

    public Map<String,Object> quote(QuoteFinanceReviewDto review) {
        Map<String,Object> result=base(review);
        rename(result,Map.ofEntries(
                Map.entry("status","reviewStatus"),Map.entry("statusBucket","reviewStatusBucket"),
                Map.entry("financeActions","reviewActions"),Map.entry("financeRemark","reviewRemark"),
                Map.entry("financeReturnReason","reviewRejectReason"),Map.entry("financeReturnedAt","reviewRejectedAt"),
                Map.entry("financeReturnedByName","reviewRejectedByName"),Map.entry("financeConfirmedAt","reviewApprovedAt"),
                Map.entry("financeConfirmedByName","reviewApprovedByName")));
        result.put("reviewStatusBucket", switch(String.valueOf(result.get("reviewStatusBucket"))) {
            case "PENDING_FINANCE" -> "PENDING"; case "FINANCE_REJECTED" -> "REJECTED";
            default -> result.get("reviewStatusBucket");
        });
        if(result.get("lines") instanceof List<?> lines) for(Object row:lines) {
            if(row instanceof Map<?,?> raw) {
                @SuppressWarnings("unchecked") Map<String,Object> line=(Map<String,Object>)raw;
                rename(line,Map.of("financePriceByName","reviewPriceByName","financePriceAt","reviewPriceAt"));
            }
        }
        return result;
    }
    public Map<String,Object> order(SalesOrderFinanceReviewDto review) {
        Map<String,Object> result=base(review);
        rename(result,Map.ofEntries(
                Map.entry("financeConfirmed","reviewApproved"),Map.entry("financeConfirmedAt","reviewApprovedAt"),
                Map.entry("financeConfirmedByName","reviewApprovedByName"),Map.entry("financeConfirmRemark","reviewRemark"),
                Map.entry("financeRejected","reviewRejected"),Map.entry("financeRejectedReason","reviewRejectReason"),
                Map.entry("financeRejectedAt","reviewRejectedAt"),Map.entry("financeRejectedByName","reviewRejectedByName"),
                Map.entry("financeReviewRevision","reviewRevision")));
        return result;
    }
    private Map<String,Object> base(Object value) {
        Map<String,Object> result=mapper.convertValue(value,new TypeReference<LinkedHashMap<String,Object>>(){});
        result.put("reviewStage","SALES_MANAGER");
        result.put("reviewContractVersion",1);
        return result;
    }
    private static void rename(Map<String,Object> value,Map<String,String> names) {
        names.forEach((from,to) -> value.put(to,value.remove(from)));
    }
}
