package com.uten.imp.support;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;

/** Isolated-fixture measurements, deliberately separate from production latency/SLA evidence. */
public final class LoadingGrowthEvidence {
    private LoadingGrowthEvidence() { }
    public static Map<String,Object> samples(Runnable read) {
        List<Double> millis=new ArrayList<>();
        for(int i=0;i<3;i++){long start=System.nanoTime();read.run();millis.add((System.nanoTime()-start)/1_000_000.0);}
        List<Double> sorted=millis.stream().sorted().toList();
        return Map.of("samples",3,"millis",millis,"p50Millis",sorted.get(1),"p95Millis",sorted.get(2),
                "quantileMethod","nearest rank; only 3 isolated warm observations, no production SLA claim");
    }
    public static void write(String scenario,int history,Map<String,Object> values,String plan) {
        try {
            var directory=Path.of(System.getProperty("uten.loading.measurement.directory","build/loading-validation/backend/growth"));
            Files.createDirectories(directory);
            Map<String,Object> evidence=new LinkedHashMap<>(values);
            evidence.put("scenario",scenario);evidence.put("historicalRows",history);evidence.put("fixedActiveRows",50);
            evidence.put("scope","Disposable PostgreSQL structural fixture, production SQL builder, no shared database or company-network SLA");
            evidence.put("explainAnalyzeBuffersJson",new com.fasterxml.jackson.databind.ObjectMapper().readTree(plan));
            new com.fasterxml.jackson.databind.ObjectMapper().writerWithDefaultPrettyPrinter()
                    .writeValue(directory.resolve(scenario+"-history-"+history+".json").toFile(),evidence);
            System.out.println("LOADING-GROWTH scenario="+scenario+" history="+history+" active=50 "+
                    new com.fasterxml.jackson.databind.ObjectMapper().writeValueAsString(values));
        }catch(java.io.IOException failure){throw new IllegalStateException("Cannot persist isolated growth evidence",failure);}
    }
}
