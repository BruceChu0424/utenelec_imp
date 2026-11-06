package com.uten.imp.features.master.goods;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.readsnapshot.MasterSummaryReadSupport;
import com.uten.imp.common.readsnapshot.VersionedSummaryPages;
import com.uten.imp.features.master.goods.dto.GoodsListItem;
import com.uten.imp.features.master.goods.dto.GoodsSearchRequest;
import org.springframework.stereotype.Service;
import java.util.List;

/** The original goods predicate and DTO use the shared complete-master transport owner. */
@Service
public final class GoodsSummaryReadService {
    public static final String DATA_DOMAIN = "goods-master-list";
    public static final int READ_BATCH_SIZE = MasterSummaryReadSupport.READ_BATCH_SIZE;
    /** Retain the existing Java/JSON payload contract while the shared owner validates metadata. */
    public record Payload(List<GoodsListItem> items, int page, int size, long total, int totalPages) {
        public Payload { items = List.copyOf(items); }
    }
    private final GoodsService goods;
    private final MasterSummaryReadSupport summaries;
    @org.springframework.beans.factory.annotation.Autowired
    public GoodsSummaryReadService(GoodsService goods, MasterSummaryReadSupport summaries) {
        this.goods = goods; this.summaries = summaries;
    }
    /** Compatibility for focused callers that supply the current proof framework explicitly. */
    public GoodsSummaryReadService(GoodsService goods, VersionedSummaryPages summaries, ObjectMapper json) {
        this(goods, new MasterSummaryReadSupport(summaries, json));
    }
    public VersionedSummaryPages.Snapshot<Payload> read(GoodsSearchRequest query, String revision) {
        MasterSummaryReadSupport.Query<com.uten.imp.features.master.goods.dto.GoodsQueryFilter> request = query == null
                ? null : new MasterSummaryReadSupport.Query<>(query.filter(), query.requestedPage(), query.requestedSize(), query.sort(), query.order());
        var snapshot = summaries.read(DATA_DOMAIN, "master_goods", "goods:view", request, revision, goods::list);
        var value = snapshot.value();
        return new VersionedSummaryPages.Snapshot<>(new Payload(value.items(), value.page(), value.size(), value.total(), value.totalPages()),
                snapshot.readScopeVersion(), snapshot.readSnapshotRevision(), snapshot.readDataVersion());
    }
    public void stream(GoodsSearchRequest query, String revision, jakarta.servlet.http.HttpServletResponse response)
            throws java.io.IOException {
        MasterSummaryReadSupport.Query<com.uten.imp.features.master.goods.dto.GoodsQueryFilter> request = query == null
                ? null : new MasterSummaryReadSupport.Query<>(query.filter(), query.requestedPage(), query.requestedSize(), query.sort(), query.order());
        summaries.stream(DATA_DOMAIN, "master_goods", "goods:view", request, revision, goods::list, response);
    }
}
