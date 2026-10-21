package com.uten.imp.application.port;

import java.nio.file.Path;
import java.time.Instant;

/** Neutral company-policy/host boundary. No operational path is an employee setting. */
public interface MaterialForecastRuntimePort {
    record Policy(boolean enabled,int intervalMinutes,int historyDays,int backfillBudget,String revision) {}
    record State(String state,boolean available,boolean processRunning,String desiredRevision,String appliedRevision,
            boolean configurationApplied,String startedAt,String lastExitAt,Integer lastExitCode,String lastErrorCode) {}
    Policy configuration();
    Path snapshotDirectory();
    State runtime();
    default State runtime(Policy desired){return runtime();}
    default Instant confirmationExpiresAt(Policy desired){return null;}
    boolean acknowledges(Instant generatedAt,String revision,String runId);
}
