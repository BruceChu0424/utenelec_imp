package com.uten.imp.businesschain;

import java.util.Arrays;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Caller limits are validated again inside the container; defaults are a short diagnostic. */
record ControlledLoadRunPlan(List<String> scenarios, Background background, int durationSeconds,
                             int warmupSeconds, double arrivalsPerSecond, int maxInFlight,
                             int maxSamples, int minimumMeasuredSamples, int readyCapacity,
                             int drainSeconds, int databaseLimitMiB) {
    enum Background { QUIET, MIXED }
    static final Set<String> SCENARIOS = Set.of("daily-report-1", "daily-report-3", "daily-report-11",
            "fqc-20-plain", "fqc-20-prestock", "fqc-20-mixed", "draw-1", "draw-3", "draw-10");

    ControlledLoadRunPlan {
        scenarios = List.copyOf(scenarios);
        if (scenarios.isEmpty() || scenarios.size() > 9 || scenarios.stream().anyMatch(s -> !SCENARIOS.contains(s))
                || scenarios.stream().distinct().count() != scenarios.size()) throw new IllegalArgumentException("Invalid or duplicate scenario list");
        if (background == null) throw new IllegalArgumentException("Background profile is required");
        bound(durationSeconds, 10, 3600, "durationSeconds");
        bound(warmupSeconds, 0, 120, "warmupSeconds");
        if (!Double.isFinite(arrivalsPerSecond) || arrivalsPerSecond < 0.05 || arrivalsPerSecond > 2)
            throw new IllegalArgumentException("arrival rate must be 0.05..2/s");
        bound(maxInFlight, 1, 8, "maxInFlight"); bound(maxSamples, 1, 2000, "maxSamples");
        bound(minimumMeasuredSamples, 1, maxSamples, "minimumMeasuredSamples");
        if (minimumMeasuredSamples > Math.ceil(durationSeconds * arrivalsPerSecond))
            throw new IllegalArgumentException("minimumMeasuredSamples exceeds the number of scheduled measured arrivals");
        bound(readyCapacity, maxInFlight, 16, "readyCapacity");
        bound(drainSeconds, 10, 120, "drainSeconds"); bound(databaseLimitMiB, 256, 4096, "databaseLimitMiB");
    }

    static ControlledLoadRunPlan from(Map<String, String> env) {
        var plan = new ControlledLoadRunPlan(Arrays.stream(value(env, "SCENARIOS", "daily-report-1").split(","))
                .map(String::strip).toList(), Background.valueOf(value(env, "BACKGROUND", "QUIET")),
                integer(env, "DURATION_SECONDS", 60), integer(env, "WARMUP_SECONDS", 5),
                Double.parseDouble(value(env, "RATE", "0.2")), integer(env, "MAX_IN_FLIGHT", 1),
                integer(env, "MAX_SAMPLES", 12), integer(env, "MIN_SAMPLES", 3),
                integer(env, "READY_CAPACITY", 4), integer(env, "DRAIN_SECONDS", 60),
                integer(env, "DATABASE_LIMIT_MIB", 1024));
        if ((plan.durationSeconds > 120 || plan.maxSamples > 30 || plan.maxInFlight > 2)
                && !"true".equals(env.get("UTEN_WINDOW_ALLOW_EXTENDED")))
            throw new IllegalArgumentException("Extended sampling requires explicit UTEN_WINDOW_ALLOW_EXTENDED=true");
        return plan;
    }

    Map<String, Object> describe() {
        var fields = new java.util.LinkedHashMap<String, Object>();
        fields.put("scenarios", scenarios); fields.put("background", background.name());
        fields.put("durationSeconds", durationSeconds); fields.put("warmupSeconds", warmupSeconds);
        fields.put("arrivalsPerSecond", arrivalsPerSecond); fields.put("maxInFlight", maxInFlight);
        fields.put("maxSamples", maxSamples); fields.put("minimumMeasuredSamples", minimumMeasuredSamples);
        fields.put("readyCapacity", readyCapacity); fields.put("drainSeconds", drainSeconds);
        fields.put("databaseLimitMiB", databaseLimitMiB); fields.put("maximumPreparedInputs", maxSamples + readyCapacity + maxInFlight);
        return fields;
    }
    private static String value(Map<String, String> env, String key, String fallback) { return env.getOrDefault("UTEN_WINDOW_" + key, fallback); }
    private static int integer(Map<String, String> env, String key, int fallback) { return Integer.parseInt(value(env, key, Integer.toString(fallback))); }
    private static void bound(int value, int minimum, int maximum, String key) {
        if (value < minimum || value > maximum) throw new IllegalArgumentException(key + " must be " + minimum + ".." + maximum);
    }
}
