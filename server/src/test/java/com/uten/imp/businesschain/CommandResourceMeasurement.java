package com.uten.imp.businesschain;

import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.ThreadMXBean;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import org.testcontainers.containers.GenericContainer;

/**
 * Optional resource evidence around one synchronous test command. It never
 * enables JVM counters or forces collection. Thread allocation measures all
 * allocated bytes, including short-lived objects; heap samples are JVM-wide
 * snapshots and cannot establish retained size or a live-memory peak.
 */
public final class CommandResourceMeasurement {
    private static final ThreadMXBean THREADS = ManagementFactory.getThreadMXBean();

    private CommandResourceMeasurement() {}

    public static Sample begin() { return begin(null); }

    /** Container probes run outside the caller's elapsed command window. */
    public static Sample begin(GenericContainer<?> database) {
        ContainerSnapshot container = containerSnapshot(database);
        return new Sample(Thread.currentThread().threadId(), snapshot(), database, container);
    }

    public static final class Sample {
        private final long thread;
        private final Snapshot before;
        private final GenericContainer<?> database;
        private final ContainerSnapshot containerBefore;
        private boolean finished;

        private Sample(long thread, Snapshot before, GenericContainer<?> database, ContainerSnapshot containerBefore) {
            this.thread = thread; this.before = before; this.database = database; this.containerBefore = containerBefore;
        }

        public Map<String, Object> finish() {
            if (finished) throw new IllegalStateException("Command resource sample was already finished");
            if (Thread.currentThread().threadId() != thread)
                throw new IllegalStateException("Command resources must finish on their originating thread");
            Snapshot after = snapshot();
            ContainerSnapshot containerAfter = containerSnapshot(database);
            finished = true;
            Map<String, Object> result = new LinkedHashMap<>();
            result.put("testJvmMaxHeapBytes", Runtime.getRuntime().maxMemory());
            result.put("testJvmAvailableProcessors", Runtime.getRuntime().availableProcessors());
            Long cpu = delta(before.cpuNanos(), after.cpuNanos());
            Long allocated = delta(before.allocatedBytes(), after.allocatedBytes());
            result.put("threadCpuAvailable", cpu != null);
            result.put("threadAllocatedBytesAvailable", allocated != null);
            if (cpu != null) result.put("threadCpuMillis", cpu / 1_000_000.0);
            if (allocated != null) result.put("threadAllocatedBytes", allocated);
            result.put("heapSnapshotsAvailable", before.heapUsedBytes() != null && after.heapUsedBytes() != null);
            if (before.heapUsedBytes() != null && after.heapUsedBytes() != null) {
                result.put("heapUsedBeforeBytes", before.heapUsedBytes());
                result.put("heapUsedAfterBytes", after.heapUsedBytes());
                result.put("heapUsedDeltaBytes", after.heapUsedBytes() - before.heapUsedBytes());
            }
            List<Map<String, Object>> collectors = new ArrayList<>();
            long count = 0, millis = 0;
            boolean complete = !before.collectors().isEmpty() && before.collectors().keySet().equals(after.collectors().keySet());
            for (var entry : before.collectors().entrySet()) {
                GcCounter end = after.collectors().get(entry.getKey());
                Long collectionCount = end == null ? null : delta(entry.getValue().count(), end.count());
                Long collectionMillis = end == null ? null : delta(entry.getValue().millis(), end.millis());
                if (collectionCount == null || collectionMillis == null) { complete = false; continue; }
                collectors.add(Map.of("collector", entry.getKey(), "collectionsDelta", collectionCount,
                        "collectionMillisDelta", collectionMillis));
                count += collectionCount;
                millis += collectionMillis;
            }
            result.put("gcCountersComplete", complete);
            result.put("gcCollectors", List.copyOf(collectors));
            if (complete) { result.put("gcCollectionsDelta", count); result.put("gcMillisDelta", millis); }
            Long databaseCpu = delta(containerBefore.cpuMicros(), containerAfter.cpuMicros());
            boolean databaseAvailable = databaseCpu != null && containerBefore.memoryBytes() != null && containerAfter.memoryBytes() != null;
            result.put("dbContainerMetricsAvailable", databaseAvailable);
            if (databaseAvailable) {
                result.put("dbContainerCpuMillis", databaseCpu / 1000.0);
                result.put("dbContainerMemoryBeforeBytes", containerBefore.memoryBytes());
                result.put("dbContainerMemoryAfterBytes", containerAfter.memoryBytes());
                result.put("dbContainerMemoryDeltaBytes", containerAfter.memoryBytes() - containerBefore.memoryBytes());
            } else {
                result.put("dbContainerUnavailableReason", containerBefore.failure() != null
                        ? containerBefore.failure() : containerAfter.failure() != null ? containerAfter.failure() : "counters_reset");
            }
            result.put("scope", "CPU/allocation: calling command thread, excludes asynchronous workers. Heap/GC: whole test JVM, may include other threads.");
            result.put("limitations", "Allocated bytes include reclaimed objects. Heap delta is two snapshots, not retained size or live-memory peak; a GC can make it negative. No forced GC or counter enabling.");
            result.put("dbContainerScope", "Read-only cgroup v2 usage_usec/memory.current of the isolated test container. CPU includes PostgreSQL background work and lightweight read probes; memory includes cache. Two snapshots are not a command memory peak. Docker exec is outside command elapsed time and JVM thread counters.");
            return result;
        }
    }

    private static Snapshot snapshot() {
        Long cpu = null, allocated = null, heap = null;
        try {
            if (THREADS.isCurrentThreadCpuTimeSupported() && THREADS.isThreadCpuTimeEnabled())
                cpu = nonnegative(THREADS.getCurrentThreadCpuTime());
        } catch (RuntimeException unavailable) { /* Counter availability is evidence, never a test prerequisite. */ }
        try {
            if (THREADS instanceof com.sun.management.ThreadMXBean allocations
                    && allocations.isThreadAllocatedMemorySupported() && allocations.isThreadAllocatedMemoryEnabled())
                allocated = nonnegative(allocations.getThreadAllocatedBytes(Thread.currentThread().threadId()));
        } catch (RuntimeException unavailable) { /* Disabled/restricted JVMs omit this counter. */ }
        try { heap = nonnegative(ManagementFactory.getMemoryMXBean().getHeapMemoryUsage().getUsed()); }
        catch (RuntimeException unavailable) { /* Do not substitute zero for an unavailable heap sample. */ }
        Map<String, GcCounter> collectors = new LinkedHashMap<>();
        try {
            for (GarbageCollectorMXBean collector : ManagementFactory.getGarbageCollectorMXBeans()) {
                collectors.put(collector.getName(), new GcCounter(nonnegative(collector.getCollectionCount()),
                        nonnegative(collector.getCollectionTime())));
            }
        } catch (RuntimeException unavailable) { collectors.clear(); }
        return new Snapshot(cpu, allocated, heap, Map.copyOf(collectors));
    }

    private static Long nonnegative(long value) { return value < 0 ? null : value; }
    private static Long delta(Long before, Long after) {
        return before == null || after == null || after < before ? null : after - before;
    }
    private record Snapshot(Long cpuNanos, Long allocatedBytes, Long heapUsedBytes, Map<String, GcCounter> collectors) {}
    private record GcCounter(Long count, Long millis) {}
    private record ContainerSnapshot(Long cpuMicros, Long memoryBytes, String failure) {}

    private static ContainerSnapshot containerSnapshot(GenericContainer<?> database) {
        if (database == null) return new ContainerSnapshot(null, null, "not_requested");
        try {
            var read = database.execInContainer("cat", "/sys/fs/cgroup/cpu.stat", "/sys/fs/cgroup/memory.current");
            if (read.getExitCode() != 0) return new ContainerSnapshot(null, null, "cgroup_v2_read_failed_exit_" + read.getExitCode());
            var cpu = java.util.regex.Pattern.compile("(?m)^usage_usec[\\t ]+(\\d+)[\\t ]*$").matcher(read.getStdout());
            var memory = java.util.regex.Pattern.compile("(?m)^(\\d+)[\\t ]*$").matcher(read.getStdout());
            if (!cpu.find() || !memory.find()) return new ContainerSnapshot(null, null, "cgroup_v2_counters_missing");
            return new ContainerSnapshot(Long.parseLong(cpu.group(1)), Long.parseLong(memory.group(1)), null);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            return new ContainerSnapshot(null, null, "container_probe_interrupted");
        } catch (Exception unavailable) {
            return new ContainerSnapshot(null, null, "container_probe_" + unavailable.getClass().getSimpleName());
        }
    }
}
