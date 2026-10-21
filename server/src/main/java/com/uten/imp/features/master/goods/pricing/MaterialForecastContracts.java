package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.core.JsonToken;
import com.fasterxml.jackson.databind.DeserializationContext;
import com.fasterxml.jackson.databind.JsonDeserializer;
import com.fasterxml.jackson.databind.annotation.JsonDeserialize;
import java.io.IOException;
import java.util.List;

/** Exact decimal text and explicit market identity; no implicit currency or quantity conversion. */
public final class MaterialForecastContracts {
    private MaterialForecastContracts() {}
    public record Validation(boolean passed,String baselineMAE,String modelMAE,int folds,String coverage80,
            String backtestStart,String backtestEnd) {}
    public record Forecast(int horizon,String price,String lower80,String upper80,String direction) {}
    public record Snapshot(int schemaVersion,String seriesId,String name,String commodity,String market,
            String grade,String region,String currency,String unit,String priceBasis,String sourceName,
            String sourceUrl,boolean authorized,String rollPolicy,String dataAsOf,String generatedAt,
            String latestPrice,String status,List<String> reasonCodes,String modelVersion,String libraryVersion,
            String datasetDigest,Validation validation,List<Forecast> forecasts,String procurementSignal,
            String validationBasis,String modelPriceBasis,String quoteContract,String sourceFetchedAt,Integer historyRecordCount) {}
    public record Benchmark(String seriesId,String name,String commodity,String market,String grade,String region,
            String currency,String unit,String priceBasis,String sourceName,String sourceUrl,String rollPolicy,
            String provider,String symbol,boolean autoUpdate,boolean selectable) {}
    public record Sync(String status,boolean autoUpdateEnabled,String lastAttemptAt,String lastSuccessAt,
            String nextSyncAt,String errorCode) {}
    public record LatestQuote(int schemaVersion,String seriesId,String contract,String price,String currency,String unit,
            String marketTime,String fetchedAt,int delayMinutes,String provider,String status,String expiresAt) {}
    public record Envelope(String status,String seriesId,long bindingVersion,Snapshot current,
            boolean canManage,List<String> reasonCodes,String expiresAt,Benchmark benchmark,Sync sync,
            LatestQuote latestQuote,int refreshAfterSeconds) {}
    public record BindingRequest(String seriesId,@JsonDeserialize(using=VersionDeserializer.class) Long expectedVersion) {}
    public static final class VersionDeserializer extends JsonDeserializer<Long> {
        @Override public Long deserialize(JsonParser p,DeserializationContext context)throws IOException {
            if(p.currentToken()!=JsonToken.VALUE_NUMBER_INT)
                return (Long)context.handleUnexpectedToken(Long.class,p);
            return p.getLongValue();
        }
    }
}
