package com.uten.imp.businesschain;

import org.springframework.test.util.ReflectionTestUtils;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;

/** Adds table/function identifiers after timing; never emits SQL, parameters or result rows. */
final class WarehouseIqcSqlRelations {
    private static final Pattern RELATION = Pattern.compile("(?i)\\b(?:from|join|update|into)\\s+(?:public\\.)?([a-z_][a-z0-9_]*)");
    private WarehouseIqcSqlRelations() {}

    static Map<String,List<String>> forSample(ProductionJdbcMeasurement.Sample sample) throws Exception {
        Object metadata = ReflectionTestUtils.getField(ProductionJdbcMeasurement.class,"METADATA");
        if (!(metadata instanceof Map<?,?> statements)) throw new IllegalStateException("Expected shared test SQL metadata");
        Map<String,List<String>> result = new LinkedHashMap<>();
        for (Object key : statements.keySet()) {
            String sql = (String)key;
            String normalized = sql.replaceAll("\\s+"," ").trim();
            String fingerprint = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256")
                    .digest(normalized.getBytes(StandardCharsets.UTF_8))).substring(0,16);
            if (!sample.fingerprints.containsKey(fingerprint)) continue;
            LinkedHashSet<String> identifiers = new LinkedHashSet<>();
            var matcher = RELATION.matcher(normalized);
            while (matcher.find() && identifiers.size()<12) identifiers.add(matcher.group(1).toLowerCase(java.util.Locale.ROOT));
            if (normalized.contains("pg_advisory_xact_lock")) identifiers.add("pg_advisory_xact_lock");
            if (normalized.contains("set_config")) identifiers.add("set_config");
            result.put(fingerprint,List.copyOf(identifiers));
        }
        return result;
    }
}
