package com.uten.imp.features.admin.serverstatus;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.management.OperatingSystemMXBean;
import com.uten.imp.config.props.StorageProperties;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.io.InputStream;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static com.uten.imp.features.admin.serverstatus.ServerStatusView.*;

/** Small, read-only samples. No shell execution, filesystem scans, or privileged host commands. */
@Component
public class ServerStatusProbe {
    private final DataSource dataSource;
    private final StorageProperties storage;
    private final MeterRegistry meters;
    private final ObjectMapper mapper;
    private final String dataPath;
    private final String backupPath;
    private final String backupStatusFile;
    private final String applicationVersion;

    public ServerStatusProbe(DataSource dataSource, StorageProperties storage, MeterRegistry meters,
            ObjectMapper mapper, @Value("${uten.server-status.data-path:/data}") String dataPath,
            @Value("${uten.server-status.backup-path:}") String backupPath,
            @Value("${uten.server-status.backup-status-file:}") String backupStatusFile,
            @Value("${uten.server-status.application-version:未提供版本标识}") String applicationVersion) {
        this.dataSource=dataSource; this.storage=storage; this.meters=meters; this.mapper=mapper;
        this.dataPath=dataPath; this.backupPath=backupPath; this.backupStatusFile=backupStatusFile;
        this.applicationVersion=applicationVersion;
    }

    ServerStatusView sample(Instant now) {
        List<Metric> metrics=new ArrayList<>();
        var os=ManagementFactory.getOperatingSystemMXBean();
        Double cpu=null, memory=null;
        Long memoryTotal=null,memoryFree=null;
        String memoryDetail="系统内存占用；包含平台以外的进程。";
        if (os instanceof OperatingSystemMXBean extended) {
            double load=extended.getCpuLoad();
            if (Double.isFinite(load) && load>=0 && load<=1) cpu=load*100;
            memoryTotal=extended.getTotalMemorySize(); memoryFree=extended.getFreeMemorySize();
            memory=percent(memoryTotal-memoryFree,memoryTotal);
        }
        if (System.getProperty("os.name", "").toLowerCase().contains("linux")) {
            try {
                // MemAvailable includes reclaimable cache; counting all Linux cache as used
                // would incorrectly tell employees that a healthy server is out of memory.
                Long[] amounts=linuxMemory(Files.readString(Path.of("/proc/meminfo")));
                memoryTotal=amounts[0];memoryFree=amounts[1];
                memory=memoryTotal==null||memoryFree==null?null:percent(memoryTotal-memoryFree,memoryTotal);
                memoryDetail="按系统可用内存计算，可回收的文件缓存不算作内存不足。";
            } catch (Exception unavailable) {
                memory=null;memoryTotal=null;memoryFree=null;
                memoryDetail="暂时读不到系统可用内存，不能据此判断内存正常。";
            }
        }
        metrics.add(metric("cpu","处理器占用",cpu,80,95,
                "运行环境的处理器占用；短时升高可继续观察，持续偏高需要检查。"));
        metrics.add(new Metric("memory","系统内存占用",memory,"PERCENT",80d,90d,severity(memory,80,90),memoryDetail,
                memory==null?null:memoryTotal,memory==null?null:memoryTotal-memoryFree,memory==null?null:memoryFree));
        var heap=ManagementFactory.getMemoryMXBean().getHeapMemoryUsage();
        Double heapPercent=percent(heap.getUsed(),heap.getMax());
        metrics.add(new Metric("jvm_memory","平台应用内存",heapPercent,"PERCENT",80d,90d,severity(heapPercent,80,90),
                "平台 Java 堆内存占用，与整台服务器的系统内存分开统计。",heapPercent==null?null:heap.getMax(),
                heapPercent==null?null:heap.getUsed(),heapPercent==null?null:heap.getMax()-heap.getUsed()));
        double active=meters.find("hikaricp.connections.active").gauges().stream().mapToDouble(g->g.value()).sum();
        double maximum=meters.find("hikaricp.connections.max").gauges().stream().mapToDouble(g->g.value()).sum();
        metrics.add(metric("db_pool","平台数据库连接占用",percent(active,maximum),80,95,
                "正在处理业务的连接占连接池上限的比例；持续偏高可能使页面等待。"));
        List<Disk> disks=disks();
        Database database=database();
        Backup backup=backup(now);
        List<Alert> alerts=new ArrayList<>();
        for (Metric metric:metrics) if (!"NORMAL".equals(metric.status()))
            alerts.add(new Alert(metric.key(),metric.status(),metric.label()+statusText(metric.status()),metric.detail()));
        for (Disk disk:disks) if (!"NORMAL".equals(disk.status()))
            alerts.add(new Alert(disk.key(),disk.status(),disk.label()+statusText(disk.status()),
                    "查看文件和备份的保留情况；不要直接删除数据库目录。"));
        if (!"NORMAL".equals(database.status())) alerts.add(new Alert("database",database.status(),
                "数据库"+statusText(database.status()),database.detail()));
        if (!"NORMAL".equals(backup.status())) alerts.add(new Alert("backup",backup.status(),
                "备份"+statusText(backup.status()),backup.detail()));
        String overall=alerts.stream().map(Alert::status).reduce("NORMAL",ServerStatusProbe::moreSevere);
        return new ServerStatusView(now,15,overall,
                os.getName()+" · "+os.getAvailableProcessors()+" 个逻辑处理器",applicationVersion,
                ManagementFactory.getRuntimeMXBean().getUptime()/1000,List.copyOf(metrics),disks,
                database,backup,List.copyOf(alerts));
    }

    static Double percent(double used,double total) {
        if (!Double.isFinite(used)||!Double.isFinite(total)||total<=0||used<0||used>total) return null;
        return used/total*100;
    }
    static String severity(Double value,double warning,double critical) {
        if (value==null||!Double.isFinite(value)||value<0) return "UNKNOWN";
        return value>=critical?"CRITICAL":value>=warning?"WARNING":"NORMAL";
    }
    static String moreSevere(String left,String right) {
        List<String> order=List.of("NORMAL","UNKNOWN","WARNING","CRITICAL");
        return order.indexOf(left)>=order.indexOf(right)?left:right;
    }
    private static String statusText(String status) {
        return switch(status) { case "CRITICAL" -> "需要尽快处理"; case "WARNING" -> "接近预警值"; default -> "暂时无法确认"; };
    }
    private static Metric metric(String key,String label,Double value,double warning,double critical,String detail) {
        return new Metric(key,label,value,"PERCENT",warning,critical,severity(value,warning,critical),detail,null,null,null);
    }
    static Double linuxMemoryPercent(String meminfo) {
        Long[] amounts=linuxMemory(meminfo);
        return amounts[0]==null||amounts[1]==null?null:percent(amounts[0]-amounts[1],amounts[0]);
    }
    private static Long[] linuxMemory(String meminfo) {
        Long total=null,available=null;
        for (String line:meminfo.lines().toList()) {
            if (line.startsWith("MemTotal:")||line.startsWith("MemAvailable:")) {
                String[] values=line.trim().split("\\s+");
                if(values.length!=3||!"kB".equals(values[2])) return new Long[]{null,null};
                long number=Math.multiplyExact(Long.parseLong(values[1]),1024);
                if(line.startsWith("MemTotal:"))total=number;else available=number;
            }
        }
        return new Long[]{total,available};
    }

    private List<Disk> disks() {
        Map<String,String> paths=new LinkedHashMap<>();
        paths.put(Path.of("").toAbsolutePath().getRoot().toString(),"系统盘");
        String attachment=storage.getInternal().getRoot();
        if(attachment!=null&&!attachment.isBlank())paths.merge(attachment,"附件存储",(a,b)->a+" / "+b);
        if(dataPath!=null&&!dataPath.isBlank())paths.merge(dataPath,"数据库与业务数据",(a,b)->a+" / "+b);
        if(backupPath!=null&&!backupPath.isBlank())paths.merge(backupPath,"本地备份",(a,b)->a+" / "+b);
        Map<String,Disk> byStore=new LinkedHashMap<>();
        int index=0;
        for(var path:paths.entrySet()) {
            String key="disk-"+(index++);
            try {
                var directory=Path.of(path.getKey());
                if(!directory.isAbsolute()||!Files.isDirectory(directory))throw new IllegalStateException();
                var store=Files.getFileStore(directory);
                long total=store.getTotalSpace(),free=store.getUsableSpace(),used=total-free;
                Double value=percent(used,total);
                String identity=store.name()+"|"+store.type()+"|"+total;
                Disk previous=byStore.get(identity);
                String label=previous==null?path.getValue():previous.label()+" / "+path.getValue();
                byStore.put(identity,new Disk(previous==null?key:previous.key(),label,total,used,free,value,80,90,
                        severity(value,80,90),"按当前服务可用空间统计，同一文件系统合并显示；磁盘空间不等于内存。"));
            }catch(Exception unavailable) {
                byStore.put(key,new Disk(key,path.getValue(),null,null,null,null,80,90,"UNKNOWN",
                        "目录尚未配置、未挂载或当前服务无法读取，不能按零占用处理。"));
            }
        }
        return List.copyOf(byStore.values());
    }

    private Database database() {
        long start=System.nanoTime();
        try(var connection=dataSource.getConnection();var statement=connection.createStatement()) {
            statement.setQueryTimeout(2);
            try(var result=statement.executeQuery("SELECT (SELECT count(*) FROM pg_stat_activity WHERE datname=current_database()),current_setting('max_connections')::int")) {
                if(!result.next())throw new IllegalStateException();
                double milliseconds=(System.nanoTime()-start)/1_000_000.0;
                int connections=result.getInt(1),maximum=result.getInt(2);
                String status=moreSevere(severity(milliseconds,200,1000),severity(percent(connections,maximum),80,95));
                return new Database(status,milliseconds,connections,maximum,
                        "后台只读探测；连接数为本数据库连接，上限为 PostgreSQL 全实例配置。不会读取业务明细或查询文本。");
            }
        }catch(Exception unavailable) {
            return new Database("CRITICAL",null,null,null,"数据库探测失败；请检查数据库服务、连接额度与网络。");
        }
    }

    private Backup backup(Instant now) {
        if(backupStatusFile==null||backupStatusFile.isBlank())
            return new Backup("UNKNOWN",null,null,30,48,"尚未接入备份状态；有备份目录不代表最近备份已成功。");
        try {
            Path file=Path.of(backupStatusFile);
            if(!file.isAbsolute())throw new IllegalStateException();
            try(InputStream input=Files.newInputStream(file,LinkOption.NOFOLLOW_LINKS)) {
                byte[] bytes=input.readNBytes(65537);
                if(bytes.length>65536)throw new IllegalStateException();
                return backup(mapper.readTree(bytes),now);
            }
        }catch(Exception unavailable) {
            return new Backup("UNKNOWN",null,null,30,48,"备份状态文件无法核验，请检查采集服务；不能据此认定备份正常。");
        }
    }
    static Backup backup(JsonNode node,Instant now) {
        if(node==null||!"uten-server-backup-status-v1".equals(node.path("format").asText()))throw new IllegalArgumentException();
        Instant sampled=Instant.parse(node.path("sampledAt").asText());
        long elapsed=Duration.between(sampled,now).getSeconds();
        if(elapsed< -120||elapsed>900)return new Backup("UNKNOWN",null,null,30,48,"备份检查超过 15 分钟未更新，请检查采集服务。");
        Instant success=node.path("lastSuccessAt").isTextual()?Instant.parse(node.path("lastSuccessAt").asText()):null;
        if(success!=null&&success.isAfter(sampled.plusSeconds(120)))throw new IllegalArgumentException();
        Double hours=success==null?null:Math.max(0,Duration.between(success,now).toMillis()/3_600_000.0);
        String attempt=node.path("lastAttemptStatus").asText();
        if("CHECK_FAILED".equals(attempt))return new Backup("CRITICAL",success,hours,30,48,"最近一次备份检查未通过，请检查备份任务、存储和恢复所需文件。");
        if("FAILED".equals(attempt))return new Backup("CRITICAL",success,hours,30,48,"最近一次备份失败，请尽快检查备份任务和剩余空间。");
        if(!"SUCCESS".equals(attempt)||success==null)return new Backup("UNKNOWN",success,hours,30,48,"尚未取得可核验的成功备份记录。");
        return new Backup(severity(hours,30,48),success,hours,30,48,
                "最近成功备份超过 30 小时报黄、48 小时报红；备份成功不等同于已经通过恢复演练。");
    }
}
