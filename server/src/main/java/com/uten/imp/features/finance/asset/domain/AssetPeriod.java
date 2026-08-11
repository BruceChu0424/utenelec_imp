package com.uten.imp.features.finance.asset.domain;

import java.time.DateTimeException;
import java.time.YearMonth;
import java.time.format.DateTimeFormatter;
import java.time.format.ResolverStyle;
import java.util.Objects;
import java.util.regex.Pattern;

/** Canonical, calendar-valid accounting month used by the asset subledger. */
public record AssetPeriod(YearMonth value) implements Comparable<AssetPeriod> {

    private static final Pattern CANONICAL = Pattern.compile("\\d{4}-(?:0[1-9]|1[0-2])");
    private static final DateTimeFormatter FORMATTER =
            DateTimeFormatter.ofPattern("uuuu-MM").withResolverStyle(ResolverStyle.STRICT);

    public AssetPeriod {
        Objects.requireNonNull(value, "value");
        if (value.getYear() < 1900 || value.getYear() > 9999) {
            throw new IllegalArgumentException("period year must be between 1900 and 9999");
        }
    }

    public static AssetPeriod parse(String text) {
        if (text == null || !CANONICAL.matcher(text).matches()) {
            throw new IllegalArgumentException("period must use YYYY-MM");
        }
        try {
            return new AssetPeriod(YearMonth.parse(text, FORMATTER));
        } catch (DateTimeException exception) {
            throw new IllegalArgumentException("period must be a valid calendar month", exception);
        }
    }

    public AssetPeriod next() {
        return new AssetPeriod(value.plusMonths(1));
    }

    public void requireImmediatelyAfter(AssetPeriod previous) {
        Objects.requireNonNull(previous, "previous");
        if (!equals(previous.next())) {
            throw new IllegalArgumentException(
                    "period must be continuous: expected " + previous.next() + " but was " + this);
        }
    }

    @Override
    public int compareTo(AssetPeriod other) {
        return value.compareTo(other.value);
    }

    @Override
    public String toString() {
        return value.format(FORMATTER);
    }
}
