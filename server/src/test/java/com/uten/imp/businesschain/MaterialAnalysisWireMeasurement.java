package com.uten.imp.businesschain;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import com.uten.imp.features.production.analysis.MaterialAnalysisResponseProjection;
import com.uten.imp.features.production.analysis.MaterialAnalysisSparseProjection;

import java.io.OutputStream;
import java.lang.management.ManagementFactory;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/** Streaming serialization measurement; response bytes are counted, never retained as a second tree. */
final class MaterialAnalysisWireMeasurement {
    @FunctionalInterface interface Recorder { void record(Map<String, Object> row) throws Exception; }

    private MaterialAnalysisWireMeasurement() {}

    static Map<String,Object> generatedResponse(ObjectMapper json,
            com.uten.imp.features.production.analysis.MaterialAnalysisContracts.GenerateResult value) throws Exception {
        long started=System.nanoTime();
        var sink=new ByteCounter();
        json.writeValue(sink,new MaterialAnalysisSparseProjection.SparseGenerateResult(
                MaterialAnalysisSparseProjection.project(value.analysis()),value.replayed(),value.plans()));
        return Map.of("sparseResponseBytes",sink.bytes,"sparseSerializationMillis",(System.nanoTime()-started)/1_000_000.0);
    }

    static void compare(ObjectMapper json, AnalysisView view, int products, int samples, Recorder recorder) throws Exception {
        var sampler = Executors.newSingleThreadScheduledExecutor(task -> {
            Thread thread = new Thread(task, "material-wire-heap-sample");
            thread.setDaemon(true);
            return thread;
        });
        try {
            for (int sample = 0; sample < samples; sample++) {
                for (String version : sample % 2 == 0
                        ? java.util.List.of(MaterialAnalysisResponseProjection.VERSION, MaterialAnalysisSparseProjection.VERSION)
                        : java.util.List.of(MaterialAnalysisSparseProjection.VERSION, MaterialAnalysisResponseProjection.VERSION)) {
                    long heapBefore = usedHeap();
                    AtomicLong peak = new AtomicLong(heapBefore);
                    var poll = sampler.scheduleAtFixedRate(() -> peak.accumulateAndGet(usedHeap(), Math::max), 0, 5, TimeUnit.MILLISECONDS);
                    var sink = new ByteCounter();
                    long allocatedBefore = allocatedBytes();
                    long started = System.nanoTime();
                    try {
                        Object projected = version.equals(MaterialAnalysisSparseProjection.VERSION)
                                ? MaterialAnalysisSparseProjection.project(view)
                                : MaterialAnalysisResponseProjection.project(view);
                        json.writeValue(sink, projected);
                    } finally {
                        poll.cancel(false);
                        peak.accumulateAndGet(usedHeap(), Math::max);
                    }
                    double millis = (System.nanoTime() - started) / 1_000_000.0;
                    long allocatedAfter = allocatedBytes();
                    Map<String, Object> row = new LinkedHashMap<>();
                    row.put("event", "wire-serialization"); row.put("projection", version);
                    row.put("products", products); row.put("materials", view.flatMaterials().size()); row.put("sample", sample);
                    row.put("elapsedMillis", millis); row.put("responseBytes", sink.bytes);
                    row.put("heapBeforeBytes", heapBefore); row.put("heapPeakUsedBytes", peak.get());
                    row.put("heapPeakGrowthBytes", Math.max(0, peak.get() - heapBefore));
                    row.put("heapSamplingMillis", 5);
                    if (allocatedBefore >= 0 && allocatedAfter >= allocatedBefore) row.put("threadAllocatedBytes", allocatedAfter - allocatedBefore);
                    row.put("concurrentLoad", System.getProperty("uten.production.concurrentLoad", "unspecified"));
                    recorder.record(row);
                }
            }
        } finally { sampler.shutdownNow(); }
    }

    private static long usedHeap() { return Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory(); }

    private static long allocatedBytes() {
        var bean = ManagementFactory.getThreadMXBean();
        return bean instanceof com.sun.management.ThreadMXBean allocation && allocation.isThreadAllocatedMemoryEnabled()
                ? allocation.getThreadAllocatedBytes(Thread.currentThread().threadId()) : -1;
    }

    private static final class ByteCounter extends OutputStream {
        private long bytes;
        @Override public void write(int value) { bytes++; }
        @Override public void write(byte[] value, int offset, int length) { bytes += length; }
    }
}
