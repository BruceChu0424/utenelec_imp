package com.uten.imp.features.master.goods.pricing;

import ch.qos.logback.classic.Level;
import ch.qos.logback.classic.Logger;
import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.read.ListAppender;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.MaterialForecastProperties;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.slf4j.LoggerFactory;
import java.nio.file.*;
import java.time.*;
import java.util.List;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class MaterialMarketFeedReaderTest {
    @TempDir Path directory;
    final ObjectMapper json=new ObjectMapper();final Clock clock=Clock.fixed(Instant.parse("2026-10-20T16:30:00Z"),ZoneOffset.UTC);
    final MaterialBenchmarkCatalog catalog=new MaterialBenchmarkCatalog(json);
    MaterialMarketFeedReader reader(){var p=new MaterialForecastProperties();p.setSnapshotDirectory(directory.toString());return new MaterialMarketFeedReader(new MaterialForecastSnapshotReader(p,json,clock),catalog,clock);}
    ObjectNode quote(){return json.createObjectNode().put("schemaVersion",1).put("seriesId","shfe_cu_main_daily").put("contract","cu2611").put("price","80000.25").put("currency","CNY").put("unit","吨").put("marketTime","2026-10-20T16:00:00Z").put("fetchedAt","2026-10-20T16:29:00Z").put("delayMinutes",30).put("provider","SHFE_PUBLIC_DAILY");}
    ObjectNode health(){var n=json.createObjectNode().put("schemaVersion",1).put("workerVersion","SHFE_AUTO_V1").put("generatedAt","2026-10-20T16:29:00Z").put("autoUpdateEnabled",true);n.putArray("series").add(json.createObjectNode().put("seriesId","shfe_cu_main_daily").put("status","IDLE").put("lastAttemptAt","2026-10-20T16:28:00Z").put("lastSuccessAt","2026-10-20T16:29:00Z").put("nextSyncAt","2026-10-20T16:59:00Z").putNull("errorCode"));return n;}
    void write(String name,ObjectNode n)throws Exception{Files.writeString(directory.resolve(name),json.writeValueAsString(n));}
    @Test void packagedCatalogHasThreeFuturesWithTheCorrectSilverUnit(){assertThat(catalog.all()).hasSize(3).allMatch(b->b.provider().equals("SHFE_PUBLIC_DAILY")&&b.market().equals("FUTURES")&&b.selectable());assertThat(catalog.find("shfe_ag_main_daily").unit()).isEqualTo("千克");assertThat(catalog.find("shfe_cu_main_daily").unit()).isEqualTo("吨");}
    @Test void aCorruptPackagedCatalogDisablesTheFeatureWithoutBreakingHistoricalPriceAnalysis() {
        Logger logger = (Logger) LoggerFactory.getLogger(MaterialBenchmarkCatalog.class);
        var captured = new ListAppender<ILoggingEvent>();
        boolean additive = logger.isAdditive();
        captured.start();
        logger.addAppender(captured);
        logger.setAdditive(false);
        try {
            var invalid = new MaterialBenchmarkCatalog(json,
                    new java.io.ByteArrayInputStream("{}".getBytes(java.nio.charset.StandardCharsets.UTF_8)));
            assertThat(invalid.all()).isEmpty();
            assertThat(invalid.find("shfe_cu_main_daily")).isNull();
            assertThat(captured.list).singleElement().satisfies(event -> {
                assertThat(event.getLevel()).isEqualTo(Level.WARN);
                assertThat(event.getFormattedMessage()).isEqualTo("内置市场参考目录暂不可用，原有价格分析继续可用");
                assertThat(event.getThrowableProxy()).isNull();
            });
        } finally {
            logger.detachAppender(captured);
            logger.setAdditive(additive);
            captured.stop();
        }
    }
    @Test void absentHeartbeatNeverClaimsAutomaticCollectionIsRunning(){var state=reader().sync("shfe_cu_main_daily");assertThat(state.status()).isEqualTo("OFFLINE");assertThat(state.autoUpdateEnabled()).isFalse();}
    @Test void freshHeartbeatCarriesIndependentSuccessAndSchedulingState()throws Exception{write("auto-feed-health.json",health());var state=reader().sync("shfe_cu_main_daily");assertThat(state.status()).isEqualTo("IDLE");assertThat(state.autoUpdateEnabled()).isTrue();assertThat(state.lastSuccessAt()).isEqualTo("2026-10-20T16:29:00Z");}
    @Test void malformedOldAndFutureHealthIsOfflineWithoutLeakingRawErrors()throws Exception{
        for(String failure:List.of("old","future","raw-error","unknown-series","duplicate")){var n=health();switch(failure){case "old"->n.put("generatedAt","2026-10-20T16:19:00Z");case "future"->n.put("generatedAt","2026-10-20T16:31:00Z");case "raw-error"->((ObjectNode)n.withArray("series").get(0)).put("errorCode","C:/private/raw-provider-message");case "unknown-series"->((ObjectNode)n.withArray("series").get(0)).put("seriesId","untrusted");default->n.withArray("series").add(n.withArray("series").get(0).deepCopy());}write("auto-feed-health.json",n);var state=reader().sync("shfe_cu_main_daily");assertThat(state.status()).as(failure).isEqualTo("OFFLINE");assertThat(state.errorCode()).isNull();}
    }
    @Test void aOneShotImportCannotClaimTheDaemonIsEnabled()throws Exception{var n=health();n.put("autoUpdateEnabled",false);write("auto-feed-health.json",n);assertThat(reader().sync("shfe_cu_main_daily").autoUpdateEnabled()).isFalse();}
    @Test void validDelayedQuotePreservesItsActualContractAndComputesAnIndependentDeadline()throws Exception{write("shfe_cu_main_daily.quote.json",quote());var q=reader().quote(catalog.find("shfe_cu_main_daily"),null);assertThat(q.status()).isEqualTo("CURRENT");assertThat(q.contract()).isEqualTo("cu2611");assertThat(q.delayMinutes()).isEqualTo(30);assertThat(q.expiresAt()).isEqualTo("2026-10-20T17:29:00Z");}
    @Test void anOldMarketTimestampIsStaleEvenAfterARecentFetch()throws Exception{var n=quote();n.put("marketTime","2026-10-20T13:00:00Z");write("shfe_cu_main_daily.quote.json",n);var q=reader().quote(catalog.find("shfe_cu_main_daily"),null);assertThat(q.status()).isEqualTo("STALE");assertThat(q.price()).isEqualTo("80000.25");}
    @Test void quotesRejectUnknownProvidersWrongUnitsInvalidContractsAndFutureTimestamps()throws Exception{
        for(String field:List.of("provider","unit","currency","delayMinutes","contract","marketTime","fetchedAt")){var n=quote();switch(field){case "provider"->n.put(field,"SINA");case "unit"->n.put(field,"千克");case "currency"->n.put(field,"USD");case "delayMinutes"->n.put(field,0);case "contract"->n.put(field,"cu0");case "marketTime"->n.put(field,"2026-10-20T16:30:01Z");default->n.put(field,"2026-10-20T16:30:01Z");}write("shfe_cu_main_daily.quote.json",n);assertThat(reader().quote(catalog.find("shfe_cu_main_daily"),null)).as(field).isNull();}
    }
    @Test void quoteContractMustMatchTheLatestValidatedDailySnapshot()throws Exception{write("shfe_cu_main_daily.quote.json",quote());var snapshot=mock(MaterialForecastContracts.Snapshot.class);when(snapshot.quoteContract()).thenReturn("cu2612");assertThat(reader().quote(catalog.find("shfe_cu_main_daily"),snapshot)).isNull();}
    @Test void aDelayedPublicationTimestampDoesNotInventAnExtraThirtyMinuteOffset()throws Exception{var n=quote();n.put("marketTime","2026-10-20T16:28:00Z");write("shfe_cu_main_daily.quote.json",n);var q=reader().quote(catalog.find("shfe_cu_main_daily"),null);assertThat(q.marketTime()).isEqualTo("2026-10-20T16:28:00Z");assertThat(q.status()).isEqualTo("CURRENT");}
    @Test void restoredOrForeignManagedHeartbeatCannotClaimAutomaticActivityWithoutTheLiveOwner()throws Exception {
        String revision="a".repeat(64),runId=java.util.UUID.randomUUID().toString();var n=health();n.put("configRevision",revision);n.put("runId",runId);write("auto-feed-health.json",n);
        var properties=new MaterialForecastProperties();properties.setSnapshotDirectory(directory.toString());
        var runtime=mock(com.uten.imp.application.port.MaterialForecastRuntimePort.class);
        var managed=new MaterialMarketFeedReader(new MaterialForecastSnapshotReader(properties,json,clock),catalog,clock,runtime);
        assertThat(managed.sync("shfe_cu_main_daily").status()).isEqualTo("OFFLINE");
        when(runtime.acknowledges(Instant.parse("2026-10-20T16:29:00Z"),revision,runId)).thenReturn(true);
        assertThat(managed.sync("shfe_cu_main_daily").autoUpdateEnabled()).isTrue();
        n.remove("runId");write("auto-feed-health.json",n);assertThat(managed.sync("shfe_cu_main_daily").status()).isEqualTo("OFFLINE");
    }
}
