package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.JsonNode;
import com.uten.imp.application.port.MaterialForecastRuntimePort;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;
import java.io.IOException;
import java.time.*;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.MaterialForecastContracts.*;
import static com.uten.imp.features.master.goods.pricing.MaterialForecastSnapshotReader.*;

/** Validates only fixed local collector files. The ERP never invokes a collector or an HTTP client. */
@Component
public class MaterialMarketFeedReader {
    private static final Set<String> HEALTH_FIELDS=Set.of("schemaVersion","workerVersion","generatedAt","autoUpdateEnabled","series");
    private static final Set<String> SERIES_FIELDS=Set.of("seriesId","status","lastAttemptAt","lastSuccessAt","nextSyncAt","errorCode");
    private static final Set<String> QUOTE_FIELDS=Set.of("schemaVersion","seriesId","contract","price","currency","unit","marketTime","fetchedAt","delayMinutes","provider");
    private static final Set<String> STATES=Set.of("FETCHING","BACKFILLING","MODEL","IDLE","ERROR");
    private static final Set<String> ERRORS=Set.of("NETWORK_ERROR","RATE_LIMITED","INVALID_SOURCE","MODEL_FAILED");
    private final MaterialForecastSnapshotReader files;
    private final MaterialBenchmarkCatalog benchmarks;
    private final Clock clock;
    private final MaterialForecastRuntimePort runtime;
    @Autowired public MaterialMarketFeedReader(MaterialForecastSnapshotReader files,MaterialBenchmarkCatalog benchmarks,MaterialForecastRuntimePort runtime){this(files,benchmarks,Clock.systemUTC(),runtime);}
    MaterialMarketFeedReader(MaterialForecastSnapshotReader files,MaterialBenchmarkCatalog benchmarks,Clock clock){this(files,benchmarks,clock,null);}
    MaterialMarketFeedReader(MaterialForecastSnapshotReader files,MaterialBenchmarkCatalog benchmarks,Clock clock,MaterialForecastRuntimePort runtime){this.files=files;this.benchmarks=benchmarks;this.clock=clock;this.runtime=runtime;}
    public Sync offline(){return new Sync("OFFLINE",false,null,null,null,null);}
    public Sync sync(String seriesId) {
        if(!files.enabled()||benchmarks.find(seriesId)==null)return offline();
        try {
            JsonNode n=files.localJson("auto-feed-health.json");fields(n,HEALTH_FIELDS,Set.of("configRevision","runId"));version(n);
            text(n,"workerVersion",128,false);Instant generated=utcInstant(n,"generatedAt",false);
            if(generated.isAfter(clock.instant())||!generated.isAfter(clock.instant().minus(Duration.ofMinutes(10)))||!n.path("autoUpdateEnabled").isBoolean())bad();
            if(n.has("configRevision")!=n.has("runId"))bad();
            String revision=n.has("configRevision")?text(n,"configRevision",64,false):null,runId=n.has("runId")?text(n,"runId",36,false):null;
            if(revision!=null&&(!revision.matches("[0-9a-f]{64}")||!java.util.UUID.fromString(runId).toString().equals(runId)))bad();
            if(runtime!=null&&(n.path("autoUpdateEnabled").booleanValue()||revision!=null)&&!runtime.acknowledges(generated,revision,runId))return offline();
            JsonNode rows=n.get("series");if(!rows.isArray()||rows.size()>3)bad();
            Set<String> found=new HashSet<>();Sync selected=null;
            for(JsonNode row:rows) {
                fields(row,SERIES_FIELDS,Set.of());String id=text(row,"seriesId",64,false),state=text(row,"status",32,false);
                if(benchmarks.find(id)==null||!found.add(id)||!STATES.contains(state))bad();
                Instant attempt=utcInstant(row,"lastAttemptAt",true),success=utcInstant(row,"lastSuccessAt",true),next=utcInstant(row,"nextSyncAt",true);
                if(attempt!=null&&attempt.isAfter(generated)||success!=null&&success.isAfter(generated)||next!=null&&next.isAfter(generated.plus(Duration.ofDays(7))))bad();
                String error=row.get("errorCode").isNull()?null:text(row,"errorCode",32,false);
                if(error!=null&&!ERRORS.contains(error)||state.equals("ERROR")&&error==null)bad();
                if(id.equals(seriesId))selected=new Sync(state,n.path("autoUpdateEnabled").booleanValue(),instant(attempt),instant(success),instant(next),error);
            }
            return selected==null?offline():selected;
        }catch(IOException|RuntimeException invalid){return offline();}
    }
    public LatestQuote quote(Benchmark benchmark,Snapshot current) {
        if(!files.enabled()||benchmark==null)return null;
        try {
            JsonNode n=files.localJson(benchmark.seriesId()+".quote.json");fields(n,QUOTE_FIELDS,Set.of());version(n);
            if(!benchmark.seriesId().equals(text(n,"seriesId",64,false))||!benchmark.currency().equals(text(n,"currency",16,false))
                    ||!benchmark.unit().equals(text(n,"unit",32,false))||!"SHFE_PUBLIC_DAILY".equals(text(n,"provider",32,false)))bad();
            String contract=text(n,"contract",16,false);
            if(!MaterialBenchmarkCatalog.validContract(benchmark,contract)||current!=null&&!contract.equals(current.quoteContract()))bad();
            if(!n.path("delayMinutes").isIntegralNumber()||!n.path("delayMinutes").canConvertToInt()||n.path("delayMinutes").intValue()!=30)bad();
            decimal(n,"price",true,false);String price=text(n,"price",80,false);
            Instant market=utcInstant(n,"marketTime",false),fetched=utcInstant(n,"fetchedAt",false);
            if(market.isAfter(fetched)||fetched.isAfter(clock.instant()))bad();
            Instant marketExpiry=market.plus(Duration.ofHours(2)),fetchExpiry=fetched.plus(Duration.ofHours(1));
            Instant expires=marketExpiry.isBefore(fetchExpiry)?marketExpiry:fetchExpiry;
            return new LatestQuote(1,benchmark.seriesId(),contract,price,benchmark.currency(),benchmark.unit(),market.toString(),fetched.toString(),30,"SHFE_PUBLIC_DAILY",clock.instant().isBefore(expires)?"CURRENT":"STALE",expires.toString());
        }catch(IOException|RuntimeException invalid){return null;}
    }
    private static String instant(Instant value){return value==null?null:value.toString();}
    private static void version(JsonNode n){if(!n.path("schemaVersion").isIntegralNumber()||!n.path("schemaVersion").canConvertToInt()||n.path("schemaVersion").intValue()!=1)bad();}
}
