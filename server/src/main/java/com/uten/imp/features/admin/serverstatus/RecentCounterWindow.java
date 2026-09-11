package com.uten.imp.features.admin.serverstatus;

/**
 * Fixed-size ring of monotonic counter readings; {@link #record(double)} returns the growth
 * since the oldest retained reading. With 60 slots at one reading per 15-second sample the
 * window covers the last 15 minutes. Non-finite readings (counter unavailable) are not
 * stored and yield null, never zero.
 */
final class RecentCounterWindow {
    private final double[] readings;
    private int size;
    private int next;

    RecentCounterWindow(int slots) {
        if (slots < 2) throw new IllegalArgumentException("window needs at least two slots");
        this.readings = new double[slots];
    }

    /** Stores the reading and returns the delta against the oldest retained one (0 for the first). */
    Double record(double total) {
        if (!Double.isFinite(total) || total < 0) return null;
        readings[next] = total;
        next = (next + 1) % readings.length;
        if (size < readings.length) size++;
        double oldest = readings[size < readings.length ? 0 : next];
        return Math.max(0, total - oldest);
    }

    int size() { return size; }
}
