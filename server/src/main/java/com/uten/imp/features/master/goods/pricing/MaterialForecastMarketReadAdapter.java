package com.uten.imp.features.master.goods.pricing;

import com.uten.imp.application.port.MaterialForecastMarketReadPort;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Component;
import java.util.List;

@Component
@RequiredArgsConstructor
public class MaterialForecastMarketReadAdapter implements MaterialForecastMarketReadPort {
    private final MaterialBenchmarkCatalog benchmarks;
    private final MaterialForecastSnapshotReader snapshots;
    private final MaterialMarketFeedReader feed;
    @Override public List<Feed> feeds() {
        return benchmarks.all().stream().map(b->{
            var read=snapshots.read(b.seriesId());var s=feed.sync(b.seriesId());var q=feed.quote(b,read.snapshot());
            var sync=new Sync(s.status(),s.autoUpdateEnabled(),s.lastAttemptAt(),s.lastSuccessAt(),s.nextSyncAt(),s.errorCode());
            Quote quote=q==null?null:new Quote(q.schemaVersion(),q.seriesId(),q.contract(),q.price(),q.currency(),q.unit(),q.marketTime(),q.fetchedAt(),q.delayMinutes(),q.provider(),q.status(),q.expiresAt());
            return new Feed(b.seriesId(),b.name(),sync,quote,read.status(),read.snapshot()==null?null:read.snapshot().dataAsOf(),read.snapshot()==null?null:read.snapshot().historyRecordCount());
        }).toList();
    }
}
