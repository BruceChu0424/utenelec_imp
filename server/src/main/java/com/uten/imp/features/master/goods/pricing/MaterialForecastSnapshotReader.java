package com.uten.imp.features.master.goods.pricing;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.time.BusinessTime;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.stereotype.Component;
import java.io.IOException;
import java.math.BigDecimal;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.channels.SeekableByteChannel;
import java.nio.file.*;
import java.time.*;
import java.util.*;
import static com.uten.imp.features.master.goods.pricing.MaterialForecastContracts.*;

/** Only bounded local files from the operator directory are read. No URL is ever fetched. */
@Component
public class MaterialForecastSnapshotReader {
    static final int MAX_BYTES=131072,MAX_CATALOG=100;
    private static final Set<String> FIELDS=Set.of("schemaVersion","seriesId","name","commodity","market","grade","region","currency","unit","priceBasis","sourceName","sourceUrl","authorized","rollPolicy","dataAsOf","generatedAt","latestPrice","status","reasonCodes","modelVersion","libraryVersion","datasetDigest","validation","forecasts","procurementSignal");
    private static final Set<String> VALIDATION_FIELDS=Set.of("passed","baselineMAE","modelMAE","folds","coverage80","backtestStart","backtestEnd");
    private static final Set<String> FORECAST_FIELDS=Set.of("horizon","price","lower80","upper80","direction");
    private static final Set<String> V2_FIELDS=Set.of("validationBasis","modelPriceBasis","quoteContract","sourceFetchedAt","historyRecordCount");
    private final MaterialForecastProperties properties;
    private final ObjectMapper json;
    private final Clock clock;
    private final MaterialBenchmarkCatalog benchmarks;

    public record Read(String status,Snapshot snapshot,List<String> reasons) {}

    @Autowired
    public MaterialForecastSnapshotReader(MaterialForecastProperties properties,ObjectMapper json,MaterialBenchmarkCatalog benchmarks) {
        this(properties,json,Clock.systemUTC(),benchmarks);
    }
    MaterialForecastSnapshotReader(MaterialForecastProperties properties,ObjectMapper json,Clock clock) {
        this(properties,json,clock,new MaterialBenchmarkCatalog(json));
    }
    MaterialForecastSnapshotReader(MaterialForecastProperties properties,ObjectMapper json,Clock clock,MaterialBenchmarkCatalog benchmarks) {
        this.properties=properties;this.json=json;this.clock=clock;this.benchmarks=benchmarks;
    }
    public boolean enabled(){return properties.getSnapshotDirectory()!=null&&!properties.getSnapshotDirectory().isBlank();}
    static boolean validSeries(String id){return id!=null&&id.matches("[a-z0-9][a-z0-9_-]{0,63}");}

    public Read read(String seriesId) {
        if(!enabled())return new Read("DISABLED",null,List.of("MARKET_FORECAST_DISABLED"));
        if(!validSeries(seriesId))return unavailable();
        try {
            Benchmark benchmark=benchmarks.find(seriesId);
            Path configured=Path.of(properties.getSnapshotDirectory());
            if(benchmark!=null&&configured.isAbsolute()&&Files.notExists(configured,LinkOption.NOFOLLOW_LINKS))return pending();
            Path root=root();
            if(benchmark!=null&&Files.notExists(root.resolve(seriesId+".json"),LinkOption.NOFOLLOW_LINKS))return pending();
            Snapshot snapshot=load(root,seriesId);
            if(benchmark!=null&&(snapshot.schemaVersion()!=2||!benchmarks.matches(benchmark,snapshot)))
                return new Read("UNAVAILABLE",null,List.of("MARKET_REFERENCE_IDENTITY_CHANGED"));
            if(stale(snapshot))return new Read("STALE",withoutSignal(snapshot,"STALE_MARKET_DATA"),List.of("STALE_MARKET_DATA"));
            return new Read(snapshot.status(),snapshot,snapshot.reasonCodes());
        }catch(IOException|RuntimeException invalid){return unavailable();}
    }

    /** Invalid files are excluded; an overlarge/unreadable directory is unavailable, never unbounded. */
    public List<Snapshot> catalog() {
        if(!enabled())return List.of();
        try {
            Path root=root();List<Path> files;
            try(var entries=Files.list(root)) {
                files=entries.filter(p->p.getFileName().toString().endsWith(".json")).limit(MAX_CATALOG+1L).toList();
            }
            if(files.size()>MAX_CATALOG)throw new IOException("Catalog limit");
            List<Snapshot> result=new ArrayList<>();
            for(Path file:files) {
                String name=file.getFileName().toString(),id=name.substring(0,name.length()-5);
                if(!validSeries(id))continue;
                try {
                    Snapshot snapshot=load(root,id);
                    Benchmark benchmark = benchmarks.find(id);
                    if (benchmark != null
                            && (snapshot.schemaVersion() != 2 || !benchmarks.matches(benchmark, snapshot))) {
                        continue;
                    }
                    result.add(stale(snapshot)?withoutSignal(snapshot,"STALE_MARKET_DATA"):snapshot);
                }catch(IOException|RuntimeException invalid){/* Never expose a malformed file or its parse details. */}
            }
            return result.stream().sorted(Comparator.comparing(Snapshot::seriesId)).toList();
        }catch(IOException|RuntimeException unavailable){
            throw GoodsPriceAnalysisService.invalid("市场参考目录暂不可用，请核对离线快照配置");
        }
    }

    String identityDigest(Snapshot s) {
        var fields=List.of(s.seriesId(),s.name(),s.commodity(),s.market(),s.grade(),s.region(),s.currency(),s.unit(),s.priceBasis(),s.sourceName(),s.sourceUrl(),Objects.toString(s.rollPolicy(),""));
        return GoodsPriceSourceReader.hash(fields.stream().map(value->value.length()+":"+value).collect(java.util.stream.Collectors.joining()));
    }
    private Read unavailable(){return new Read("UNAVAILABLE",null,List.of("MARKET_SNAPSHOT_UNAVAILABLE"));}
    private Read pending(){return new Read("SYNC_PENDING",null,List.of("MARKET_DATA_PENDING"));}
    private Path root() throws IOException {
        Path configured=Path.of(properties.getSnapshotDirectory());
        if(!configured.isAbsolute())throw new IOException("Absolute directory required");
        Path normalized=configured.normalize();
        if(!Files.isDirectory(normalized,LinkOption.NOFOLLOW_LINKS)||Files.isSymbolicLink(normalized))throw new IOException("Directory unavailable");
        Path real=normalized.toRealPath();
        if(!real.equals(normalized))throw new IOException("Directory links forbidden");
        return real;
    }
    private Snapshot load(Path root,String id) throws IOException {
        JsonNode node=localJson(root,id+".json");
        validate(node,id);
        ((com.fasterxml.jackson.databind.node.ObjectNode)node).remove("synthetic");
        return json.treeToValue(node,Snapshot.class);
    }
    JsonNode localJson(String filename)throws IOException {
        if(!filename.matches("(?:auto-feed-health|[a-z0-9][a-z0-9_-]{0,63}(?:\\.quote)?)\\.json"))throw new IOException("Invalid local filename");
        return localJson(root(),filename);
    }
    private JsonNode localJson(Path root,String filename)throws IOException {
        Path file=root.resolve(filename).normalize();
        if(!file.getParent().equals(root)||!Files.isRegularFile(file,LinkOption.NOFOLLOW_LINKS)||Files.isSymbolicLink(file)||Files.size(file)>MAX_BYTES)throw new IOException("Invalid snapshot");
        ByteBuffer bytes=ByteBuffer.allocate(MAX_BYTES+1);
        try(SeekableByteChannel channel=Files.newByteChannel(file,Set.of(StandardOpenOption.READ,LinkOption.NOFOLLOW_LINKS))) {
            while(bytes.hasRemaining()&&channel.read(bytes)!=-1) { }
        }
        if(bytes.position()>MAX_BYTES)throw new IOException("Snapshot limit");
        return json.reader().with(DeserializationFeature.FAIL_ON_READING_DUP_TREE_KEY,DeserializationFeature.FAIL_ON_TRAILING_TOKENS).readTree(Arrays.copyOf(bytes.array(),bytes.position()));
    }
    private void validate(JsonNode n,String id) {
        if (n == null || !n.isObject()) {
            bad();
        }
        int schema=n.path("schemaVersion").intValue();
        var required=new HashSet<>(FIELDS);if(schema==2)required.addAll(V2_FIELDS);
        fields(n,required,Set.of("synthetic"));
        if(n.has("synthetic")&&(!n.get("synthetic").isBoolean()||n.get("synthetic").booleanValue()))bad();
        if(!n.path("schemaVersion").isIntegralNumber()||!n.path("schemaVersion").canConvertToInt()||!Set.of(1,2).contains(schema)||!id.equals(text(n,"seriesId",64,false)))bad();
        for(String key:List.of("name","currency","unit","priceBasis","sourceName","modelVersion","libraryVersion"))text(n,key,256,false);
        String commodity=text(n,"commodity",32,false),market=text(n,"market",16,false);
        if(!Set.of("COPPER","ALUMINIUM","SILVER","POLYCARBONATE").contains(commodity)||!Set.of("SPOT","FUTURES").contains(market))bad();
        String grade=text(n,"grade",256,true),region=text(n,"region",256,true);
        if("POLYCARBONATE".equals(commodity)&&(!"SPOT".equals(market)||grade.isBlank()||region.isBlank()))bad();
        if(!n.path("authorized").isBoolean()||!n.path("authorized").booleanValue())bad();
        if("FUTURES".equals(market))text(n,"rollPolicy",512,false);
        else if(!n.get("rollPolicy").isNull())text(n,"rollPolicy",512,true);
        String source=text(n,"sourceUrl",2048,true);
        if(!source.isEmpty()) {
            URI uri=URI.create(source);
            if(!Set.of("https","http").contains(Objects.toString(uri.getScheme(),"").toLowerCase(Locale.ROOT))||uri.getHost()==null||uri.getUserInfo()!=null)bad();
        }
        if(!text(n,"datasetDigest",64,false).matches("[0-9a-f]{64}"))bad();
        String generatedText=text(n,"generatedAt",40,false);if(!generatedText.endsWith("Z"))bad();
        Instant generated=Instant.parse(generatedText);
        LocalDate asOf=LocalDate.parse(text(n,"dataAsOf",10,false));
        if(generated.isAfter(clock.instant())||asOf.isAfter(today())||asOf.isAfter(generated.atZone(BusinessTime.ZONE).toLocalDate()))bad();
        BigDecimal latest=decimal(n,"latestPrice",true,false);
        String status=text(n,"status",32,false),signal=text(n,"procurementSignal",32,false);
        if(!Set.of("READY","RESEARCH_ONLY","BASELINE_ONLY","INSUFFICIENT").contains(status)||!Set.of("RISING","WATCH","INSUFFICIENT").contains(signal))bad();
        if(schema==2) {
            Benchmark b=benchmarks.find(id);
            if(b==null||"READY".equals(status)||!"INSUFFICIENT".equals(signal)||!"LATEST_HISTORY_REPLAY".equals(text(n,"validationBasis",64,false))
                    ||!"CHAIN_LINKED_CURRENT_ANCHOR".equals(text(n,"modelPriceBasis",64,false))||!MaterialBenchmarkCatalog.validContract(b,text(n,"quoteContract",16,false)))bad();
            Instant fetched=utcInstant(n,"sourceFetchedAt",false);
            if(fetched.isAfter(generated)||asOf.isAfter(fetched.atZone(BusinessTime.ZONE).toLocalDate()))bad();
            JsonNode records=n.path("historyRecordCount");if(!records.isIntegralNumber()||!records.canConvertToInt()||records.intValue()<1||records.intValue()>1000000)bad();
        }else if("RESEARCH_ONLY".equals(status))bad();
        JsonNode reasons=n.get("reasonCodes");
        if(!reasons.isArray()||reasons.size()>30)bad();
        for(JsonNode reason:reasons)if(!reason.isTextual()||!reason.asText().matches("[A-Z][A-Z0-9_]{0,79}"))bad();
        JsonNode v=n.get("validation");fields(v,VALIDATION_FIELDS,Set.of());
        if(!v.path("passed").isBoolean()||!v.path("folds").isIntegralNumber()||!v.path("folds").canConvertToInt())bad();
        int folds=v.path("folds").intValue();if(folds<0||folds>10000)bad();
        BigDecimal baseline=decimal(v,"baselineMAE",false,true),model=decimal(v,"modelMAE",false,true),coverage=decimal(v,"coverage80",false,true);
        if(coverage!=null&&coverage.compareTo(BigDecimal.ONE)>0)bad();
        LocalDate start=optionalDate(v,"backtestStart"),end=optionalDate(v,"backtestEnd");
        if ((start == null) != (end == null)) {
            bad();
        }
        if (start != null && end != null && (start.isAfter(end) || end.isAfter(asOf))) {
            bad();
        }
        boolean ready="READY".equals(status),research="RESEARCH_ONLY".equals(status),validated=ready||research;
        if(validated&&(!v.path("passed").booleanValue()||folds<20||baseline==null||model==null||coverage==null||baseline.signum()<=0||model.compareTo(baseline)>=0||coverage.compareTo(new BigDecimal("0.70"))<0||start==null))bad();
        if(!validated&&(!"INSUFFICIENT".equals(signal)||v.path("passed").booleanValue()))bad();
        JsonNode forecasts=n.get("forecasts");if(!forecasts.isArray()||forecasts.size()>3||!"INSUFFICIENT".equals(status)&&forecasts.size()!=3)bad();
        Set<Integer> horizons=new HashSet<>();boolean mediumRising=false,falling=false;
        for(JsonNode f:forecasts) {
            fields(f,FORECAST_FIELDS,Set.of());
            if(!f.path("horizon").isIntegralNumber()||!f.path("horizon").canConvertToInt())bad();
            int horizon=f.path("horizon").intValue();if(!Set.of(1,5,20).contains(horizon)||!horizons.add(horizon))bad();
            BigDecimal price=decimal(f,"price",true,false),lower=decimal(f,"lower80",false,false),upper=decimal(f,"upper80",true,false);
            if(lower.compareTo(price)>0||price.compareTo(upper)>0)bad();
            String direction=text(f,"direction",16,false);
            String expected=!validated?"UNCERTAIN":lower.compareTo(latest)>0?"UP":upper.compareTo(latest)<0?"DOWN":"UNCERTAIN";
            if(!expected.equals(direction))bad();
            mediumRising|=horizon>=5&&"UP".equals(direction);falling|="DOWN".equals(direction);
        }
        if(ready&&forecasts.size()!=3||ready&&!signal.equals(mediumRising&&!falling?"RISING":"WATCH"))bad();
    }
    private boolean stale(Snapshot s) {
        return !clock.instant().isBefore(expiry(s));
    }
    public String expiresAt(Snapshot snapshot){return expiry(snapshot).toString();}
    private Instant expiry(Snapshot s) {
        int days=properties.getMaxDataAgeDays();if(days<1||days>7)return Instant.EPOCH;
        Instant generatedDeadline=Instant.parse(s.generatedAt()).plus(Duration.ofHours(36));
        Instant dataDeadline=LocalDate.parse(s.dataAsOf()).plusDays(days+1L).atStartOfDay(BusinessTime.ZONE).toInstant();
        return generatedDeadline.isBefore(dataDeadline)?generatedDeadline:dataDeadline;
    }
    private LocalDate today(){return LocalDate.now(clock.withZone(BusinessTime.ZONE));}
    private Snapshot withoutSignal(Snapshot s,String reason) {
        var reasons=new ArrayList<>(s.reasonCodes());if(!reasons.contains(reason))reasons.add(reason);
        return new Snapshot(s.schemaVersion(),s.seriesId(),s.name(),s.commodity(),s.market(),s.grade(),s.region(),s.currency(),s.unit(),s.priceBasis(),s.sourceName(),s.sourceUrl(),s.authorized(),s.rollPolicy(),s.dataAsOf(),s.generatedAt(),s.latestPrice(),"INSUFFICIENT",List.copyOf(reasons),s.modelVersion(),s.libraryVersion(),s.datasetDigest(),s.validation(),s.forecasts().stream().map(f->new Forecast(f.horizon(),f.price(),f.lower80(),f.upper80(),"UNCERTAIN")).toList(),"INSUFFICIENT",s.validationBasis(),s.modelPriceBasis(),s.quoteContract(),s.sourceFetchedAt(),s.historyRecordCount());
    }
    static void fields(JsonNode n,Set<String> required,Set<String> optional) {
        if (n == null || !n.isObject()) {
            bad();
        }
        Set<String> actual = new HashSet<>();
        n.fieldNames().forEachRemaining(actual::add);
        if (!actual.containsAll(required)
                || actual.stream().anyMatch(f -> !required.contains(f) && !optional.contains(f))) {
            bad();
        }
    }
    static String text(JsonNode n,String key,int max,boolean blank) {
        JsonNode value = n.get(key);
        if (value == null || !value.isTextual()) {
            bad();
        }
        String text = value.asText();
        if (text.length() > max || !blank && text.isBlank()
                || text.codePoints().anyMatch(Character::isISOControl)) {
            bad();
        }
        return text;
    }
    static BigDecimal decimal(JsonNode n,String key,boolean positive,boolean nullable) {
        JsonNode value = n.get(key);
        if (nullable && value != null && value.isNull()) {
            return null;
        }
        String text = text(n, key, 80, false);
        if (!text.matches("(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?")) {
            bad();
        }
        BigDecimal amount = new BigDecimal(text);
        if (amount.precision() > 36 || amount.scale() > 18 || positive && amount.signum() <= 0
                || amount.compareTo(new BigDecimal("1000000000000000")) > 0) {
            bad();
        }
        return amount;
    }
    private static LocalDate optionalDate(JsonNode n, String key) {
        return n.get(key).isNull() ? null : LocalDate.parse(text(n, key, 10, false));
    }
    static Instant utcInstant(JsonNode n,String key,boolean nullable) {
        JsonNode node = n.get(key);
        if (nullable && node != null && node.isNull()) {
            return null;
        }
        String value = text(n, key, 40, false);
        if (!value.endsWith("Z")) {
            bad();
        }
        return Instant.parse(value);
    }
    static void bad(){throw new IllegalArgumentException("Invalid market snapshot");}
}
