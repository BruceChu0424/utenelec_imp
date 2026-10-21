package com.uten.imp.application.port;

import java.util.List;

/** Built-in public market status only, never goods/partners or ERP prices. */
public interface MaterialForecastMarketReadPort {
    record Sync(String status,boolean autoUpdateEnabled,String lastAttemptAt,String lastSuccessAt,String nextSyncAt,String errorCode) {}
    record Quote(int schemaVersion,String seriesId,String contract,String price,String currency,String unit,String marketTime,
                 String fetchedAt,int delayMinutes,String provider,String status,String expiresAt) {}
    record Feed(String seriesId,String name,Sync sync,Quote latestQuote,String snapshotStatus,String dataAsOf,Integer historyRecordCount) {}
    List<Feed> feeds();
}
