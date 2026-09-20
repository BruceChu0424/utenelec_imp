package com.uten.imp.common.concurrency;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

/** Ordered ownership checkpoints for Spring-managed JDBC savepoints. */
public final class SavepointSnapshots<T> {
    private final Map<Object, T> snapshots = new LinkedHashMap<>();

    public void record(Object savepoint, T snapshot) {
        snapshots.put(savepoint, Objects.requireNonNull(snapshot));
    }

    /** Null means the resource was created after that savepoint: it proves no retained ownership. */
    public T rollback(Object savepoint) {
        T snapshot = snapshots.get(savepoint);
        if (snapshot == null) { snapshots.clear(); return null; }
        boolean later = false;
        var iterator = snapshots.keySet().iterator();
        while (iterator.hasNext()) {
            Object key = iterator.next();
            if (later) iterator.remove();
            else if (Objects.equals(key, savepoint)) later = true;
        }
        return snapshot;
    }

    public void clear() { snapshots.clear(); }
}
