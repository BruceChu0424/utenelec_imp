package com.uten.imp.security;

/** Version parsing shared by ordinary reads and controlled key maintenance. */
record PgpCipherEnvelope(String version, String body, boolean versioned) {
    @Override public String toString() { return "PgpCipherEnvelope[redacted]"; }
    static PgpCipherEnvelope parse(String cipher, String unversionedVersion) {
        int separator = cipher.indexOf(':');
        if (separator < 0) return new PgpCipherEnvelope(unversionedVersion, cipher, false);
        String version = cipher.substring(0, separator);
        if (!validVersion(version)) throw new IllegalArgumentException("密文版本格式无效，原值未改变");
        return new PgpCipherEnvelope(version, cipher.substring(separator + 1), true);
    }

    static boolean validVersion(String version) {
        return version != null && version.matches("[A-Za-z0-9._-]{1,64}");
    }
}
