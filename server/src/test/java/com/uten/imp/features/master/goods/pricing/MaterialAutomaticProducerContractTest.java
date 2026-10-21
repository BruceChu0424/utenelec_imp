package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.MaterialForecastProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import java.nio.file.*;
import java.time.*;
import static org.assertj.core.api.Assertions.*;

/** Optional local producer smoke: real downloaded prices never enter committed test resources. */
@EnabledIfSystemProperty(named="uten.materialForecast.contractDirectory",matches=".+")
class MaterialAutomaticProducerContractTest {
    @Test void actualAutomaticCollectorFilesInteroperateWithTheProductionReaders()throws Exception {
        Path directory=Path.of(System.getProperty("uten.materialForecast.contractDirectory")).toAbsolutePath().normalize();
        var json=new ObjectMapper();var health=json.readTree(Files.readString(directory.resolve("auto-feed-health.json")));
        Clock clock=Clock.fixed(Instant.parse(health.path("generatedAt").asText()).plusSeconds(1),ZoneOffset.UTC);
        var properties=new MaterialForecastProperties();properties.setSnapshotDirectory(directory.toString());
        var benchmarks=new MaterialBenchmarkCatalog(json);
        var snapshots=new MaterialForecastSnapshotReader(properties,json,clock,benchmarks);
        var feed=new MaterialMarketFeedReader(snapshots,benchmarks,clock);
        assertThat(benchmarks.all()).hasSize(3);
        for(var benchmark:benchmarks.all()) {
            var read=snapshots.read(benchmark.seriesId());
            assertThat(read.status()).as(benchmark.seriesId()+" snapshot").isIn("INSUFFICIENT","BASELINE_ONLY","RESEARCH_ONLY");
            assertThat(read.snapshot()).isNotNull();assertThat(read.snapshot().schemaVersion()).isEqualTo(2);
            assertThat(read.snapshot().historyRecordCount()).isGreaterThanOrEqualTo(1);
            assertThat(read.snapshot().validationBasis()).isEqualTo("LATEST_HISTORY_REPLAY");
            assertThat(read.snapshot().procurementSignal()).isEqualTo("INSUFFICIENT");
            var sync=feed.sync(benchmark.seriesId());
            assertThat(sync.status()).as(benchmark.seriesId()+" health").isEqualTo("IDLE");
            assertThat(sync.autoUpdateEnabled()).as("A real one-shot run is not a live daemon").isFalse();
            var quote=feed.quote(benchmark,read.snapshot());
            assertThat(quote).as(benchmark.seriesId()+" official delayed quote").isNotNull();
            assertThat(quote.status()).isEqualTo("CURRENT");assertThat(quote.delayMinutes()).isEqualTo(30);
        }
    }
}
