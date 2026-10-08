package com.uten.imp.application.port;

import java.time.Instant;
import java.util.List;

/** Operational security counts only; audit rows and raw IP addresses stay in the audit module. */
public interface LoginFailureObservationPort {
    record FailureWindow(String sourceFingerprint, long attempts) {}
    List<FailureWindow> recentFailures(Instant since);
}
