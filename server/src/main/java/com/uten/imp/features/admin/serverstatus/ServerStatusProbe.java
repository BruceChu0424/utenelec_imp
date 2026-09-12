package com.uten.imp.features.admin.serverstatus;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.sun.management.OperatingSystemMXBean;
import com.uten.imp.config.props.StorageProperties;
import io.micrometer.core.instrument.MeterRegistry;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.io.InputStream;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.sql.ResultSet;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.function.DoubleSupplier;
import java.util.function.IntSupplier;

import static com.uten.imp.features.admin.serverstatus.ServerStatusView.*;

/**
 * Small, read-only samples. No shell execution, filesystem scans, or privileged host commands.
 *
 * <p>Fast lane (every 15-second sample): CPU, memory, heap, pool, disks, database ping,
 * backup file, thread count, recent error-log count, scheduled-task registry. Slow lane
 * (every {@value #SLOW_LANE_EVERY}th sample = 60 s): online sessions and outbox backlog;
 * attachment volume additionally keeps a {@value #ATTACHMENTS_CACHE_MINUTES}-minute cache.
 * Slow-lane results are reused between refreshes; a failed or timed-out probe is reported
 * as UNKNOWN, never as zero.</p>
 */
@Component
public class ServerStatusProbe {
    static final int SLOW_LANE_EVERY = 4;
    static final int ATTACHMENTS_CACHE_MINUTES = 5;
    static final int ERROR_WINDOW_SAMPLES = 60;
    static final double ERRORS_WARNING = 10, ERRORS_CRITICAL = 100;
    static final int OUTBOX_WARNING_COUNT = 50, OUTBOX_CRITICAL_COUNT = 500;
    static final int OUTBOX_WARNING_MINUTES = 5, OUTBOX_CRITICAL_MINUTES = 30;

    private final DataSource dataSource;
    private final StorageProperties storage;
    private final MeterRegistry meters;
    private final ObjectMapper mapper;
    private final ScheduledTaskRunRegistry taskRuns;
    private final DoubleSupplier errorEvents;
    private final IntSupplier liveThreads;
    private final String dataPath;
    private final String backupPath;
    private final String backupStatusFile;
    private final String applicationVersion;
    private final int threadsWarning;
    private final int threadsCritical;
    private final RecentCounterWindow errorWindow = new RecentCounterWindow(ERROR_WINDOW_SAMPLES);
    private long sampleCount;
    private Metric cachedSessions;
    private Metric cachedOutbox;
    private Metric cachedAttachments;
    private Instant attachmentsSampledAt;

    @Autowired
    public ServerStatusProbe(DataSource dataSource, StorageProperties storage, MeterRegistry meters,
            ObjectMapper mapper, ScheduledTaskRunRegistry taskRuns,
            @Value("${uten.server-status.data-path:/data}") String dataPath,
            @Value("${uten.server-status.backup-path:}") String backupPath,
            @Value("${uten.server-status.backup-status-file:}") String backupStatusFile,
            @Value("${uten.server-status.application-version:未提供版本标识}") String applicationVersion,
            @Value("${uten.server-status.threads-warning:400}") int threadsWarning,
            @Value("${uten.server-status.threads-critical:800}") int threadsCritical) {
        this(dataSource, storage, meters, mapper, taskRuns, new ErrorLogEventCounter(meters),
                () -> ManagementFactory.getThreadMXBean().getThreadCount(),
                dataPath, backupPath, backupStatusFile, applicationVersion, threadsWarning, threadsCritical);
    }

    ServerStatusProbe(DataSource dataSource, StorageProperties storage, MeterRegistry meters,
            ObjectMapper mapper, ScheduledTaskRunRegistry taskRuns, DoubleSupplier errorEvents,
            IntSupplier liveThreads, String dataPath, String backupPath, String backupStatusFile,
            String applicationVersion, int threadsWarning, int threadsCritical) {
        this.dataSource=dataSource; this.storage=storage; this.meters=meters; this.mapper=mapper;
        this.taskRuns=taskRuns; this.errorEvents=errorEvents; this.liveThreads=liveThreads;
        this.dataPath=dataPath; this.backupPath=backupPath; this.backupStatusFile=backupStatusFile;
        this.applicationVersion=applicationVersion;
        this.threadsWarning=threadsWarning; this.threadsCritical=threadsCritical;
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
        List<Metric> extras=extras(now);
        List<Job> jobs=jobs(now);
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
        for (Metric metric:extras) if (!"NORMAL".equals(metric.status()))
            alerts.add(new Alert(metric.key(),metric.status(),metric.label()+statusText(metric.status()),metric.detail()));
        // A task that has simply not run yet (daily cron after a restart) is grey, not an alert.
        for (Job job:jobs) if ("WARNING".equals(job.status())||"CRITICAL".equals(job.status()))
            alerts.add(new Alert("job:"+job.key(),job.status(),"定时任务 "+job.label()+statusText(job.status()),job.detail()));
        String overall=alerts.stream().map(Alert::status).reduce("NORMAL",ServerStatusProbe::moreSevere);
        return new ServerStatusView(now,15,overall,
                os.getName()+" · "+os.getAvailableProcessors()+" 个逻辑处理器",applicationVersion,
                ManagementFactory.getRuntimeMXBean().getUptime()/1000,List.copyOf(metrics),disks,
                database,backup,List.copyOf(alerts),extras,jobs);
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
    private static Metric count(String key,String label,Double value,Double warning,Double critical,String status,String detail) {
        return new Metric(key,label,value,"COUNT",warning,critical,status,detail,null,null,null);
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
        // 2026-09-11 用户要求「把盘分别展示」：此前同一文件系统的多个用途会被合并成
        // 一行（/data 既放数据库又放备份，只显示一条「数据库与业务数据 / 本地备份」），
        // 看不出各自是什么。现在**一个用途一行**；两行落在同一个文件系统时，在说明里
        // 互相点名并标出挂载设备，免得有人把同一份剩余空间当成两份来花。
        Map<String,List<String>> storeUsage=new LinkedHashMap<>();
        Map<String,String> storeIdentity=new LinkedHashMap<>();
        for(var path:paths.entrySet()) {
            try {
                var directory=Path.of(path.getKey());
                if(!directory.isAbsolute()||!Files.isDirectory(directory))continue;
                var store=Files.getFileStore(directory);
                String identity=store.name()+"|"+store.type()+"|"+store.getTotalSpace();
                storeIdentity.put(path.getKey(),identity);
                storeUsage.computeIfAbsent(identity,ignored->new ArrayList<>()).add(path.getValue());
            }catch(Exception ignored) {
                // 读不到的目录下面会走 UNKNOWN 分支，这里不预登记。
            }
        }
        List<Disk> result=new ArrayList<>();
        int index=0;
        for(var path:paths.entrySet()) {
            String key="disk-"+(index++);
            try {
                var directory=Path.of(path.getKey());
                if(!directory.isAbsolute()||!Files.isDirectory(directory))throw new IllegalStateException();
                var store=Files.getFileStore(directory);
                long total=store.getTotalSpace(),free=store.getUsableSpace(),used=total-free;
                Double value=percent(used,total);
                List<String> shared=storeUsage.getOrDefault(storeIdentity.get(path.getKey()),List.of());
                StringBuilder detail=new StringBuilder("路径 ").append(path.getKey())
                        .append("，设备 ").append(store.name())
                        .append("。按当前服务可用空间统计；磁盘空间不等于内存。");
                if(shared.size()>1) {
                    detail.append("注意：与「")
                            .append(String.join("、",shared.stream()
                                    .filter(other->!other.equals(path.getValue())).toList()))
                            .append("」同在这一个文件系统上，剩余空间是共用的，不能重复计算。");
                }
                result.add(new Disk(key,path.getValue(),total,used,free,value,80,90,
                        severity(value,80,90),detail.toString()));
            }catch(Exception unavailable) {
                result.add(new Disk(key,path.getValue(),null,null,null,null,80,90,"UNKNOWN",
                        "目录（"+path.getKey()+"）尚未配置、未挂载或当前服务无法读取，不能按零占用处理。"));
            }
        }
        return List.copyOf(result);
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

    /** Fast-lane counters plus the cached slow-lane ones; order is the display order. */
    List<Metric> extras(Instant now) {
        boolean slowLane=sampleCount++%SLOW_LANE_EVERY==0;
        if(slowLane) {
            cachedSessions=sessions();
            cachedOutbox=outbox(now);
            if(attachmentsSampledAt==null||Duration.between(attachmentsSampledAt,now).toMinutes()>=ATTACHMENTS_CACHE_MINUTES) {
                cachedAttachments=attachments();
                attachmentsSampledAt=now;
            }
        }
        List<Metric> extras=new ArrayList<>();
        extras.add(threads());
        extras.add(recentErrors());
        extras.add(cachedSessions==null?pending("sessions","在线会话"):cachedSessions);
        extras.add(cachedOutbox==null?pending("outbox","待处理事件积压"):cachedOutbox);
        extras.add(cachedAttachments==null?pending("attachments","附件占用"):cachedAttachments);
        return List.copyOf(extras);
    }

    private static Metric pending(String key,String label) {
        return count(key,label,null,null,null,"UNKNOWN","尚未完成首次统计。");
    }

    Metric threads() {
        Double live;
        try { int value=liveThreads.getAsInt(); live=value<0?null:(double)value; }
        catch(RuntimeException unavailable) { live=null; }
        return count("threads","平台线程数",live,(double)threadsWarning,(double)threadsCritical,
                severity(live,threadsWarning,threadsCritical),
                "平台 Java 进程当前线程数；持续增长通常意味着连接或后台任务没有释放。");
    }

    Metric recentErrors() {
        double total;
        try { total=errorEvents.getAsDouble(); } catch(RuntimeException unavailable) { total=Double.NaN; }
        Double recent=errorWindow.record(total);
        if(recent==null) return count("errors","最近错误日志",null,ERRORS_WARNING,ERRORS_CRITICAL,"UNKNOWN",
                "暂时读不到错误日志计数，不能据此判断应用无错误。");
        String detail="最近 15 分钟（按 60 次采样滚动）新增的错误日志条数；自本次启动以来累计 "
                +(long)total+" 条，重启后重新计数。";
        return count("errors","最近错误日志",recent,ERRORS_WARNING,ERRORS_CRITICAL,
                severity(recent,ERRORS_WARNING,ERRORS_CRITICAL),detail);
    }

    Metric sessions() {
        try(var connection=dataSource.getConnection();
            var statement=connection.prepareStatement(
                "SELECT (SELECT count(DISTINCT session_id) FROM refresh_tokens WHERE revoked_at IS NULL AND expires_at>now()),"
                +"(SELECT count(DISTINCT session_id) FROM visitor_refresh_tokens WHERE revoked_at IS NULL AND expires_at>now())")) {
            statement.setQueryTimeout(2);
            try(ResultSet result=statement.executeQuery()) {
                if(!result.next())throw new IllegalStateException();
                long employees=result.getLong(1),visitors=result.getLong(2);
                return count("sessions","在线会话",(double)(employees+visitors),null,null,"NORMAL",
                        "员工 "+employees+" · 访客 "+visitors+"；按未撤销且未过期的登录会话统计，每 60 秒更新。");
            }
        }catch(Exception unavailable) {
            return count("sessions","在线会话",null,null,null,"UNKNOWN","会话统计暂时不可用，不能按无人在线处理。");
        }
    }

    Metric outbox(Instant now) {
        try(var connection=dataSource.getConnection();
            var statement=connection.prepareStatement(
                "SELECT (SELECT count(*) FROM business_outbox WHERE status=0),"
                +"(SELECT min(available_at) FROM business_outbox WHERE status=0),"
                +"(SELECT count(*) FROM attachment_object_outbox WHERE status IN ('PENDING','FAILED')),"
                +"(SELECT min(available_at) FROM attachment_object_outbox WHERE status IN ('PENDING','FAILED'))")) {
            statement.setQueryTimeout(2);
            try(ResultSet result=statement.executeQuery()) {
                if(!result.next())throw new IllegalStateException();
                long business=result.getLong(1),attachments=result.getLong(3);
                Instant oldest=earliest(result.getObject(2,OffsetDateTime.class),result.getObject(4,OffsetDateTime.class));
                long backlog=business+attachments;
                long oldestMinutes=oldest==null?0:Math.max(0,Duration.between(oldest,now).toMinutes());
                return outboxMetric(backlog,business,attachments,oldestMinutes);
            }
        }catch(Exception unavailable) {
            return count("outbox","待处理事件积压",null,(double)OUTBOX_WARNING_COUNT,(double)OUTBOX_CRITICAL_COUNT,"UNKNOWN",
                    "积压统计暂时不可用，不能按无积压处理。");
        }
    }

    static Metric outboxMetric(long backlog,long business,long attachments,long oldestMinutes) {
        String status=backlog>OUTBOX_CRITICAL_COUNT||oldestMinutes>OUTBOX_CRITICAL_MINUTES?"CRITICAL"
                :backlog>OUTBOX_WARNING_COUNT||oldestMinutes>OUTBOX_WARNING_MINUTES?"WARNING":"NORMAL";
        String detail="业务通知 "+business+" · 附件清理 "+attachments+"；最早一条已等待 "+oldestMinutes
                +" 分钟。超过 50 条或等待超过 5 分钟提醒，超过 500 条或 30 分钟告警；每 60 秒更新。";
        return count("outbox","待处理事件积压",(double)backlog,(double)OUTBOX_WARNING_COUNT,(double)OUTBOX_CRITICAL_COUNT,status,detail);
    }

    private static Instant earliest(OffsetDateTime left,OffsetDateTime right) {
        Instant a=left==null?null:left.toInstant(),b=right==null?null:right.toInstant();
        if(a==null)return b; if(b==null)return a; return a.isBefore(b)?a:b;
    }

    Metric attachments() {
        try(var connection=dataSource.getConnection();
            var statement=connection.prepareStatement(
                "SELECT count(*), COALESCE(SUM(COALESCE(stored_size_bytes,size_bytes)),0) FROM attachments")) {
            statement.setQueryTimeout(2);
            try(ResultSet result=statement.executeQuery()) {
                if(!result.next())throw new IllegalStateException();
                long files=result.getLong(1),bytes=result.getLong(2);
                return new Metric("attachments","附件占用",(double)bytes,"BYTES",null,null,"NORMAL",
                        "共 "+files+" 个附件，按实际存储大小汇总；每 5 分钟统计一次。",null,bytes,null);
            }
        }catch(Exception unavailable) {
            return new Metric("attachments","附件占用",null,"BYTES",null,null,"UNKNOWN",
                    "附件统计超时或不可用，不能按零占用处理。",null,null,null);
        }
    }

    List<Job> jobs(Instant now) {
        List<Job> result=new ArrayList<>();
        for (var run:taskRuns.snapshot()) result.add(job(run,now));
        return List.copyOf(result);
    }

    static Job job(ScheduledTaskRunRegistry.Run run,Instant now) {
        Long period=run.period()==null?null:run.period().getSeconds();
        String cadence=period==null?"按日程触发":"每 "+humanDuration(run.period());
        if(run.lastStart()==null) return new Job(run.name(),run.name(),null,null,null,period,null,"UNKNOWN",
                "启动后尚未执行；"+cadence+"。");
        if(run.running()) {
            long runningSeconds=Math.max(0,Duration.between(run.lastStart(),now).getSeconds());
            long limit=Math.max(600,period==null?600:period*2);
            String status=runningSeconds>limit?"WARNING":"NORMAL";
            return new Job(run.name(),run.name(),run.lastStart(),run.lastEnd(),null,period,null,status,
                    (status.equals("WARNING")?"本次执行已超过 ":"正在执行，已用 ")+humanDuration(Duration.ofSeconds(runningSeconds))+"；"+cadence+"。");
        }
        String took=run.lastDurationMs()==null?"":"，耗时 "+humanDuration(Duration.ofMillis(run.lastDurationMs()));
        if(run.lastErrorType()!=null) {
            String status=run.consecutiveFailures()>=3?"CRITICAL":"WARNING";
            return new Job(run.name(),run.name(),run.lastStart(),run.lastEnd(),run.lastDurationMs(),period,run.lastErrorType(),status,
                    "最近连续 "+run.consecutiveFailures()+" 次执行失败（"+run.lastErrorType()+"）"+took+"；"+cadence+"。");
        }
        if(period!=null&&Duration.between(run.lastEnd(),now).getSeconds()>period*2) {
            return new Job(run.name(),run.name(),run.lastStart(),run.lastEnd(),run.lastDurationMs(),period,null,"WARNING",
                    "已超过 2 个周期未执行，上次结束于 "+humanDuration(Duration.between(run.lastEnd(),now))+" 前；"+cadence+"。");
        }
        return new Job(run.name(),run.name(),run.lastStart(),run.lastEnd(),run.lastDurationMs(),period,null,"NORMAL",
                "上次执行正常"+took+"；"+cadence+"。");
    }

    static String humanDuration(Duration duration) {
        long seconds=Math.max(0,duration.getSeconds());
        if(seconds<1) return Math.max(0,duration.toMillis())+" 毫秒";
        if(seconds<60) return seconds+" 秒";
        if(seconds<3600) return (seconds/60)+" 分钟";
        if(seconds<86400) return (seconds/3600)+" 小时";
        return (seconds/86400)+" 天";
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
