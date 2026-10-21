package com.uten.imp.testsupport;

/** Rejects malformed or out-of-range numeric fixture facts with an explicit assertion failure. */
public final class FixtureNumbers {
    private FixtureNumbers() { }

    public static int integer(String value) {
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException invalid) {
            throw new AssertionError("Fixture must contain a whole number in the signed 32-bit range", invalid);
        }
    }

    public static long longInteger(String value) {
        try {
            return Long.parseLong(value);
        } catch (NumberFormatException invalid) {
            throw new AssertionError("Fixture must contain a whole number in the signed 64-bit range", invalid);
        }
    }

    public static double finiteDouble(String value) {
        if (value == null) {
            throw new AssertionError("Fixture decimal must be present");
        }
        try {
            double parsed = Double.parseDouble(value);
            if (!Double.isFinite(parsed)) {
                throw new AssertionError("Fixture decimal must be finite and representable as a double");
            }
            return parsed;
        } catch (NumberFormatException invalid) {
            throw new AssertionError("Fixture must contain a valid decimal", invalid);
        }
    }
}
