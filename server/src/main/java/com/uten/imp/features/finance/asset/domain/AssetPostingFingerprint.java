package com.uten.imp.features.finance.asset.domain;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Comparator;
import java.util.HexFormat;
import java.util.List;
import java.util.UUID;

/** Canonical SHA-256 fingerprint used to detect changes between preview and posting. */
public final class AssetPostingFingerprint {

    private AssetPostingFingerprint() {}

    public static String calculate(String runType, String bookType, AssetPeriod period, List<Input> inputs) {
        StringBuilder canonical = new StringBuilder()
                .append(runType).append('|').append(bookType).append('|').append(period).append('\n');
        inputs.stream()
                .sorted(Comparator.comparing(input -> input.objectId().toString()))
                .forEach(input -> canonical
                        .append(input.objectId()).append('|')
                        .append(input.versionId()).append('|')
                        .append(normalize(input.originalAmount())).append('|')
                        .append(normalize(input.accumulatedAmount())).append('|')
                        .append(normalize(input.currentAmount())).append('|')
                        .append(input.expenseStyleId()).append('|')
                        .append(input.creditStyleId()).append('|')
                        .append(input.departmentId()).append('|')
                        .append(input.rowVersion()).append('\n'));
        try {
            return HexFormat.of().formatHex(
                    MessageDigest.getInstance("SHA-256")
                            .digest(canonical.toString().getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException exception) {
            throw new IllegalStateException("SHA-256 is unavailable", exception);
        }
    }

    private static String normalize(BigDecimal value) {
        return value == null ? "" : value.stripTrailingZeros().toPlainString();
    }

    public record Input(
            UUID objectId,
            UUID versionId,
            BigDecimal originalAmount,
            BigDecimal accumulatedAmount,
            BigDecimal currentAmount,
            UUID expenseStyleId,
            UUID creditStyleId,
            UUID departmentId,
            long rowVersion) {}
}
