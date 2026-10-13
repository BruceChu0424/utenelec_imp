package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.common.web.FacetBucket;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Map;
import static com.uten.imp.features.master.goods.pricing.GoodsPriceContracts.*;

/** Server-owned whole-history query. The older keyset HistoryQuery remains unchanged. */
public final class GoodsPriceHistoryTableContracts {
    private GoodsPriceHistoryTableContracts() {}
    public record TableQuery(Query context,LocalDate from,LocalDate to,Integer page,Integer size,
            String sort,Boolean ascending,Map<String,String> filters) {}
    public record TablePage(List<Observation> observations,int page,int size,long total,int totalPages,
            Map<String,List<FacetBucket>> facets,Map<String,Long> nullCounts,
            Map<String,Long> facetTotals,Map<String,Boolean> facetsHasMore,int facetPageSize,
            OffsetDateTime dataAsOf) {}
    public record FacetQuery(TableQuery table,String column,String search,Integer page,Integer size) {}
    public record FacetPage(String column,List<FacetBucket> buckets,int page,int size,long total,
            int totalPages,long nullCount,boolean hasMore,OffsetDateTime dataAsOf) {}
}
