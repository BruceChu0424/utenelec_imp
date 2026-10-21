package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import java.nio.file.*;
import java.time.*;
import java.util.List;
import static org.assertj.core.api.Assertions.*;

class MaterialForecastSnapshotReaderTest {
    @TempDir Path directory;
    final ObjectMapper json=new ObjectMapper();
    final Clock clock=Clock.fixed(Instant.parse("2026-10-20T16:30:00Z"),ZoneOffset.UTC);
    MaterialForecastSnapshotReader reader(){var p=new MaterialForecastProperties();p.setSnapshotDirectory(directory.toString());return new MaterialForecastSnapshotReader(p,json,clock);}
    ObjectNode fixture(){
        return (ObjectNode)json.valueToTree(java.util.Map.ofEntries(
            java.util.Map.entry("schemaVersion",1),java.util.Map.entry("seriesId","copper-test"),java.util.Map.entry("name","铜参考"),
            java.util.Map.entry("commodity","COPPER"),java.util.Map.entry("market","SPOT"),java.util.Map.entry("grade","T1"),java.util.Map.entry("region","华东"),
            java.util.Map.entry("currency","CNY"),java.util.Map.entry("unit","吨"),java.util.Map.entry("priceBasis","含税现货"),java.util.Map.entry("sourceName","授权CSV"),
            java.util.Map.entry("sourceUrl","https://example.org/prices"),java.util.Map.entry("authorized",true),java.util.Map.entry("rollPolicy",""),
            java.util.Map.entry("dataAsOf","2026-10-21"),java.util.Map.entry("generatedAt","2026-10-20T16:29:00Z"),java.util.Map.entry("latestPrice","100"),
            java.util.Map.entry("status","READY"),java.util.Map.entry("reasonCodes",List.of()),java.util.Map.entry("modelVersion","SF_V1"),java.util.Map.entry("libraryVersion","2.0.3"),
            java.util.Map.entry("datasetDigest","a".repeat(64)),java.util.Map.entry("validation",java.util.Map.of("passed",true,"baselineMAE","4","modelMAE","2","folds",20,"coverage80","0.8","backtestStart","2024-01-01","backtestEnd","2026-10-20")),
            java.util.Map.entry("forecasts",List.of(java.util.Map.of("horizon",1,"price","105","lower80","101","upper80","110","direction","UP"),java.util.Map.of("horizon",5,"price","105","lower80","101","upper80","110","direction","UP"),java.util.Map.of("horizon",20,"price","105","lower80","101","upper80","110","direction","UP"))),java.util.Map.entry("procurementSignal","RISING")));
    }
    void write(ObjectNode n)throws Exception{Files.writeString(directory.resolve("copper-test.json"),json.writeValueAsString(n));}
    @Test void validatesTheRealContractAndChineseBusinessDateAcrossUtcMidnight()throws Exception{
        write(fixture());var result=reader().read("copper-test");assertThat(result.status()).isEqualTo("READY");assertThat(result.snapshot().latestPrice()).isEqualTo("100");assertThat(reader().catalog()).hasSize(1);
    }
    @Test void disabledDirectoryDoesNotReadAnything(){var r=new MaterialForecastSnapshotReader(new MaterialForecastProperties(),json,clock);assertThat(r.read("copper-test").status()).isEqualTo("DISABLED");assertThat(r.catalog()).isEmpty();}
    @Test void rejectsTraversalAndMetadataSwap()throws Exception{write(fixture());assertThat(reader().read("../copper-test").snapshot()).isNull();var n=fixture();n.put("seriesId","silver-test");write(n);assertThat(reader().read("copper-test").status()).isEqualTo("UNAVAILABLE");}
    @Test void expiredQuotesRemainVisibleWithoutAnActiveSignal()throws Exception{
        var n=fixture();n.put("dataAsOf","2026-10-15");((ObjectNode)n.get("validation")).put("backtestEnd","2026-10-14");write(n);
        var result=reader().read("copper-test");assertThat(result.status()).isEqualTo("STALE");assertThat(result.snapshot().latestPrice()).isEqualTo("100");assertThat(result.snapshot().status()).isEqualTo("INSUFFICIENT");assertThat(result.snapshot().procurementSignal()).isEqualTo("INSUFFICIENT");assertThat(result.snapshot().forecasts()).allMatch(f->f.direction().equals("UNCERTAIN"));
    }
    @Test void oldGenerationIsStaleEvenWhenTheDataDateLooksRecent()throws Exception{var n=fixture();n.put("dataAsOf","2026-10-19");n.put("generatedAt","2026-10-18T16:00:00Z");((ObjectNode)n.get("validation")).put("backtestEnd","2026-10-18");write(n);assertThat(reader().read("copper-test").status()).isEqualTo("STALE");}
    @Test void rejectsFutureGenerationAndFutureData()throws Exception{for(var key:List.of("generatedAt","dataAsOf")){var n=fixture();n.put(key,key.equals("generatedAt")?"2026-10-20T16:31:00Z":"2026-10-22");write(n);assertThat(reader().read("copper-test").snapshot()).as(key).isNull();}}
    @Test void readyNeedsRealHeldoutValidationAndImprovement()throws Exception{
        for(String key:List.of("passed","folds","modelMAE","coverage80")){var n=fixture();var v=(ObjectNode)n.get("validation");switch(key){case "passed"->v.put(key,false);case "folds"->v.put(key,19);case "modelMAE"->v.put(key,"4");default->v.put(key,"0.69");}write(n);assertThat(reader().read("copper-test").snapshot()).as(key).isNull();}
        var n=fixture();((ObjectNode)n.get("validation")).put("coverage80","1");write(n);assertThat(reader().read("copper-test").status()).isEqualTo("READY");
    }
    @Test void pcRequiresExplicitGradeRegionAndSpotMarket()throws Exception{for(String key:List.of("grade","region","market")){var n=fixture();n.put("commodity","POLYCARBONATE");n.put(key,key.equals("market")?"FUTURES":"");write(n);assertThat(reader().read("copper-test").snapshot()).as(key).isNull();}}
    @Test void rejectsSyntheticDataUntrustedSourceAndNumbersMasqueradingAsDecimals()throws Exception{
        for(String key:List.of("synthetic","authorized","sourceUrl","latestPrice")){var n=fixture();switch(key){case "synthetic"->n.put(key,true);case "authorized"->n.put(key,false);case "latestPrice"->n.put(key,100);default->n.put(key,"javascript:alert(1)");}write(n);assertThat(reader().read("copper-test").snapshot()).as(key).isNull();}
    }
    @Test void rejectsDirectionAndSignalThatContradictIntervals()throws Exception{
        var n=fixture();((ObjectNode)n.withArray("forecasts").get(0)).put("direction","DOWN");write(n);assertThat(reader().read("copper-test").snapshot()).isNull();
        n=fixture();var f=(ObjectNode)n.withArray("forecasts").get(2);f.put("price","90");f.put("lower80","80");f.put("upper80","99");f.put("direction","DOWN");n.put("procurementSignal","WATCH");write(n);assertThat(reader().read("copper-test").status()).isEqualTo("READY");
        n.put("procurementSignal","RISING");write(n);assertThat(reader().read("copper-test").snapshot()).isNull();
    }
    @Test void malformedAndOversizedFilesStayOutOfTheCatalog()throws Exception{
        write(fixture());Files.writeString(directory.resolve("bad.json"),"{");assertThat(reader().catalog()).hasSize(1);
        Files.writeString(directory.resolve("copper-test.json"),"x".repeat(MaterialForecastSnapshotReader.MAX_BYTES+1));assertThat(reader().read("copper-test").snapshot()).isNull();
    }
    @Test void rejectsTrailingJsonAndDuplicateFields()throws Exception{String valid=json.writeValueAsString(fixture());for(String text:List.of(valid+" {}",valid.substring(0,valid.length()-1)+",\"schemaVersion\":1}")){Files.writeString(directory.resolve("copper-test.json"),text);assertThat(reader().read("copper-test").snapshot()).isNull();}}
    @Test void identityDigestChangesWithGradeButNotWithDailyPrices()throws Exception{write(fixture());var r=reader();var before=r.identityDigest(r.read("copper-test").snapshot());var n=fixture();n.put("latestPrice","99");write(n);assertThat(r.identityDigest(r.read("copper-test").snapshot())).isEqualTo(before);n.put("grade","T2");write(n);assertThat(r.identityDigest(r.read("copper-test").snapshot())).isNotEqualTo(before);}
    @Test void ownCsvSourcesNeedNoPublicUrlAndZeroLowerBoundIsConservative()throws Exception{
        var n=fixture();n.put("sourceUrl","");n.put("procurementSignal","WATCH");for(var f:n.withArray("forecasts")){((ObjectNode)f).put("lower80","0");((ObjectNode)f).put("direction","UNCERTAIN");}write(n);assertThat(reader().read("copper-test").status()).isEqualTo("READY");
    }
    @Test void bindingVersionCannotBeCoercedFromFloatingPointOrText()throws Exception{
        for(String value:List.of("1.2","\"1\"","9223372036854775808"))assertThatThrownBy(()->json.readValue("{\"seriesId\":null,\"expectedVersion\":"+value+"}",MaterialForecastContracts.BindingRequest.class)).isInstanceOf(java.io.IOException.class);
        assertThat(json.readValue("{\"seriesId\":null,\"expectedVersion\":1}",MaterialForecastContracts.BindingRequest.class).expectedVersion()).isEqualTo(1);
    }
    @Test void actualStatsForecastCliFixtureIsRejectedAsSyntheticButItsSchemaInteroperates()throws Exception{
        ObjectNode actual;
        try(var source=getClass().getResourceAsStream("/pricing/material-forecast-worker-v1.synthetic.json")){actual=(ObjectNode)json.readTree(source);}
        var p=new MaterialForecastProperties();p.setSnapshotDirectory(directory.toString());
        var r=new MaterialForecastSnapshotReader(p,json,Clock.fixed(Instant.parse(actual.path("generatedAt").asText()).plusSeconds(60),ZoneOffset.UTC));
        Files.writeString(directory.resolve("synthetic_demo.json"),json.writeValueAsString(actual));
        assertThat(r.read("synthetic_demo").snapshot()).as("Synthetic data must never enter the production catalog").isNull();assertThat(r.catalog()).isEmpty();
        actual.remove("synthetic"); // Temporary directory only: verifies the real Python output against the Java wire contract.
        Files.writeString(directory.resolve("synthetic_demo.json"),json.writeValueAsString(actual));
        var result=r.read("synthetic_demo");assertThat(result.status()).isEqualTo("READY");assertThat(result.snapshot().libraryVersion()).isEqualTo("2.1.1");assertThat(result.snapshot().validation().folds()).isGreaterThanOrEqualTo(20);
    }
    @Test void expiryUsesTheEarlierOfGenerationAndChineseBusinessDataDeadlines()throws Exception{
        write(fixture());var r=reader();assertThat(r.expiresAt(r.read("copper-test").snapshot())).isEqualTo("2026-10-22T04:29:00Z");
        var n=fixture();n.put("dataAsOf","2026-10-18");((ObjectNode)n.get("validation")).put("backtestEnd","2026-10-17");write(n);
        var snapshot=r.read("copper-test").snapshot();assertThat(r.expiresAt(snapshot)).isEqualTo("2026-10-21T16:00:00Z");
        var p=new MaterialForecastProperties();p.setSnapshotDirectory(directory.toString());var atExpiry=new MaterialForecastSnapshotReader(p,json,Clock.fixed(Instant.parse("2026-10-21T16:00:00Z"),ZoneOffset.UTC));assertThat(atExpiry.read("copper-test").status()).isEqualTo("STALE");
    }
}
