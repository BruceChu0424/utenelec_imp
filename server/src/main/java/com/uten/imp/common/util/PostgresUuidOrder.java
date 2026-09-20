package com.uten.imp.common.util;

import java.util.Comparator;
import java.util.UUID;

/** PostgreSQL uuid ORDER BY uses unsigned bytes, unlike UUID.compareTo's signed longs. */
public enum PostgresUuidOrder implements Comparator<UUID> {
    INSTANCE;

    @Override
    public int compare(UUID left, UUID right) {
        int high = Long.compareUnsigned(left.getMostSignificantBits(), right.getMostSignificantBits());
        return high != 0 ? high
                : Long.compareUnsigned(left.getLeastSignificantBits(), right.getLeastSignificantBits());
    }
}
