package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.stereotype.Component;
import org.springframework.beans.factory.annotation.Autowired;
import lombok.extern.slf4j.Slf4j;
import java.io.IOException;
import java.io.InputStream;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.MaterialForecastContracts.*;

/** Packaged definitions are selectable before the independent collector has produced any data. */
@Component
@Slf4j
public class MaterialBenchmarkCatalog {
    private final List<Benchmark> definitions;
    private final Map<String,Benchmark> byId;
    @Autowired public MaterialBenchmarkCatalog(ObjectMapper json) {
        this(json,MaterialBenchmarkCatalog.class.getResourceAsStream("/pricing/material-benchmarks.json"));
    }
    MaterialBenchmarkCatalog(ObjectMapper json,InputStream source) {
        Map<String,Benchmark> loaded=new LinkedHashMap<>();
        try(var input=source) {
            if(input==null)throw new IOException("Missing packaged benchmarks");
            byte[] bytes=input.readNBytes(16385);if(bytes.length>16384)throw new IOException("Invalid benchmark catalog");
            JsonNode root=json.reader().with(DeserializationFeature.FAIL_ON_READING_DUP_TREE_KEY,DeserializationFeature.FAIL_ON_TRAILING_TOKENS).readTree(bytes);
            if(!root.isArray()||root.size()!=3)throw new IOException("Invalid benchmark catalog");
            for(JsonNode row:root) {
                MaterialForecastSnapshotReader.fields(row,Set.of("seriesId","name","commodity","market","grade","region","currency","unit","priceBasis","sourceName","sourceUrl","rollPolicy","provider","symbol","autoUpdate","selectable"),Set.of());
                for(String key:List.of("seriesId","name","commodity","market","grade","region","currency","unit","priceBasis","sourceName","provider","symbol"))MaterialForecastSnapshotReader.text(row,key,256,false);
                MaterialForecastSnapshotReader.text(row,"rollPolicy",512,false);
                var sourceUri=java.net.URI.create(MaterialForecastSnapshotReader.text(row,"sourceUrl",2048,false));
                if(!"https".equals(sourceUri.getScheme())||!"www.shfe.com.cn".equals(sourceUri.getHost())||sourceUri.getUserInfo()!=null
                        ||sourceUri.getPort()!=-1&&sourceUri.getPort()!=443||!row.path("autoUpdate").isBoolean()||!row.path("selectable").isBoolean())throw new IOException("Invalid benchmark source");
                Benchmark b=json.treeToValue(row,Benchmark.class);
                String expected=switch(b.symbol()){case "cu"->"COPPER";case "al"->"ALUMINIUM";case "ag"->"SILVER";default->throw new IOException("Invalid benchmark symbol");};
                if(!b.seriesId().equals("shfe_"+b.symbol()+"_main_daily")||!b.provider().equals("SHFE_PUBLIC_DAILY")||!b.market().equals("FUTURES")
                        ||!b.commodity().equals(expected)||!b.currency().equals("CNY")||!b.unit().equals(b.symbol().equals("ag")?"千克":"吨")
                        ||!b.autoUpdate()||!b.selectable()||b.rollPolicy()==null||b.rollPolicy().isBlank()||loaded.putIfAbsent(b.seriesId(),b)!=null)
                    throw new IOException("Invalid benchmark identity");
            }
        }catch(IOException|RuntimeException invalid){
            loaded.clear();log.warn("内置市场参考目录暂不可用，原有价格分析继续可用");
        }
        definitions=List.copyOf(loaded.values());byId=Map.copyOf(loaded);
    }
    public List<Benchmark> all(){return definitions;}
    public Benchmark find(String id){return id==null?null:byId.get(id);}
    String identityDigest(Benchmark b) {
        var values=new ArrayList<>(identity(b));values.add(b.provider());values.add(b.symbol());
        return GoodsPriceSourceReader.hash(values.stream().map(v->v.length()+":"+v).collect(java.util.stream.Collectors.joining()));
    }
    boolean matches(Benchmark b,Snapshot s){return identity(b).equals(List.of(s.seriesId(),s.name(),s.commodity(),s.market(),s.grade(),s.region(),s.currency(),s.unit(),s.priceBasis(),s.sourceName(),s.sourceUrl(),Objects.toString(s.rollPolicy(),"")));}
    private List<String> identity(Benchmark b){return List.of(b.seriesId(),b.name(),b.commodity(),b.market(),b.grade(),b.region(),b.currency(),b.unit(),b.priceBasis(),b.sourceName(),b.sourceUrl(),b.rollPolicy());}
    static boolean validContract(Benchmark b,String value) {
        if(value==null||!value.matches(b.symbol()+"[0-9]{4}"))return false;
        // The matched suffix has exactly four ASCII digits. Decode its two
        // month digits directly; malformed contract text never reaches a
        // throwing numeric parser or receives a default delivery month.
        int end=value.length();
        int month=(value.charAt(end-2)-'0')*10+(value.charAt(end-1)-'0');
        return month>=1&&month<=12;
    }
}
