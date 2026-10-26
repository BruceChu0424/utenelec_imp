package com.uten.imp.features.reporting.export;

import com.uten.imp.common.export.*;
import com.uten.imp.security.*;
import jakarta.annotation.PreDestroy;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.stereotype.Component;
import org.springframework.transaction.*;
import org.springframework.transaction.support.TransactionTemplate;
import java.io.*;
import java.nio.file.*;
import java.security.*;
import java.time.OffsetDateTime;
import java.util.HexFormat;
import java.util.Set;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** One database-fenced worker globally; no unbounded in-memory queue or full-row collection. */
@Component
@Profile("!cloud")
public class ReportExportWorker {
    private static final long MAX_BYTES=ExportResourceLimits.ARTIFACT_BYTES;
    private static final long MIN_FREE=ExportResourceLimits.FREE_RESERVE_BYTES;
    private final ReportExportRepository repository;
    private final ReportExportService service;
    private final ReportExportSource source;
    private final SubmitterPrincipalRestorer restorer;
    private final XlsxExportService xlsx;
    private final TabularPdfExportService pdf;
    private final JdbcTemplate jdbc;
    private final TransactionTemplate shortTx;
    private final TransactionTemplate readTx;
    private final AtomicBoolean busy=new AtomicBoolean();
    private final ExecutorService executor=Executors.newSingleThreadExecutor(r -> {
        var thread=new Thread(r,"report-export-worker");thread.setDaemon(true);return thread;
    });
    @org.springframework.beans.factory.annotation.Autowired
    public ReportExportWorker(ReportExportRepository repository,ReportExportService service,
            ReportExportSource source,SubmitterPrincipalRestorer restorer,XlsxExportService xlsx,
            TabularPdfExportService pdf,JdbcTemplate jdbc,PlatformTransactionManager transactions) {
        this.repository=repository;this.service=service;this.source=source;this.restorer=restorer;this.xlsx=xlsx;this.pdf=pdf;this.jdbc=jdbc;
        shortTx=new TransactionTemplate(transactions);
        shortTx.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        shortTx.setTimeout(15);
        readTx=new TransactionTemplate(transactions);
        readTx.setReadOnly(true);
        readTx.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRES_NEW);
        readTx.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
        readTx.setTimeout(600);
    }
    public ReportExportWorker(ReportExportRepository repository,ReportExportService service,
            ReportExportSource source,SubmitterPrincipalRestorer restorer,XlsxExportService xlsx,
            JdbcTemplate jdbc,PlatformTransactionManager transactions) {
        this(repository,service,source,restorer,xlsx,new TabularPdfExportService(),jdbc,transactions);
    }
    @Scheduled(fixedDelayString="${uten.report-export.poll-millis:2000}")
    public void poll() {
        try { service.requireStorage(); } catch(RuntimeException disabled) { return; }
        if(!busy.compareAndSet(false,true)) return;
        try {
            executor.execute(() -> {
                try {
                    cleanupExpired();
                    try {ExportDownloadFiles.reap(service.requireStorage(),java.time.Instant.now());}
                    catch(IOException cleanup) {org.slf4j.LoggerFactory.getLogger(getClass()).warn("Export download cache cleanup failed");}
                    var job=shortTx.execute(s -> repository.claim());
                    if(job!=null && job.isPresent()) runWithSlot(job.get());
                    else cleanupIdleFiles();
                } catch(RuntimeException unavailable) {
                    // The durable queue remains authoritative; retry discovery on the next poll.
                    org.slf4j.LoggerFactory.getLogger(getClass()).warn("Export queue poll failed: {}",unavailable.getClass().getSimpleName());
                } finally { busy.set(false); }
            });
        } catch(RejectedExecutionException closed) { busy.set(false); }
    }
    private void cleanupIdleFiles() {
        jdbc.execute((org.springframework.jdbc.core.ConnectionCallback<Void>) connection -> {
            boolean acquired;
            try(var statement=connection.createStatement();var rows=statement.executeQuery("SELECT pg_try_advisory_lock(935,2)")) {
                rows.next();acquired=rows.getBoolean(1);
            }
            if(!acquired)return null;
            try {
                if(Boolean.FALSE.equals(shortTx.execute(s -> repository.hasRunning())))cleanupInterruptedFiles(null);
            } finally {try(var statement=connection.createStatement()){statement.execute("SELECT pg_advisory_unlock(935,2)");}}
            return null;
        });
    }
    private void runWithSlot(ReportExportRepository.Job job) {
        // A session lock holds the physical worker slot even after cancellation or a stale lease.
        // Closing a crashed process' connection releases it; another instance cannot overlap its work.
        jdbc.execute((org.springframework.jdbc.core.ConnectionCallback<Void>) connection -> {
            boolean acquired;
            try(var statement=connection.createStatement();var rows=statement.executeQuery("SELECT pg_try_advisory_lock(935,2)")) {
                rows.next();acquired=rows.getBoolean(1);
            }
            if(!acquired) return null;
            try { cleanupInterruptedFiles(job);run(job); }
            finally {try(var statement=connection.createStatement()) {statement.execute("SELECT pg_advisory_unlock(935,2)");}}
            return null;
        });
    }
    private void cleanupInterruptedFiles(ReportExportRepository.Job current) {
        // This dedicated directory contains reproducible export copies only. The session slot
        // proves no other report worker can still be writing a sheet or a partial workbook.
        var names=java.util.regex.Pattern.compile("([0-9a-f-]{36})-([0-9]+)\\.(?:xlsx|pdf)(\\.part)?");
        int scanned=0;
        try(var files=Files.newDirectoryStream(service.requireStorage())) {
            for(Path file:files) {
                if(++scanned>1000)break;
                String name=file.getFileName().toString();
                if(name.matches("report-document-[0-9a-f-]{36}") && Files.isDirectory(file,LinkOption.NOFOLLOW_LINKS)
                        && !Files.isSymbolicLink(file)) {ExportDownloadFiles.removeDocumentScratch(file);continue;}
                if(!Files.isRegularFile(file,LinkOption.NOFOLLOW_LINKS))continue;
                if(name.matches("report-sheet-[0-9]+\\.xml\\.gz")) {Files.deleteIfExists(file);continue;}
                var match=names.matcher(name);
                if(!match.matches())continue;
                java.util.UUID id;int attempt;
                try {id=java.util.UUID.fromString(match.group(1));attempt=Integer.parseInt(match.group(2));}
                catch(IllegalArgumentException invalid) {continue;}
                var job=shortTx.execute(s -> repository.find(id));
                if(job==null || job.isEmpty())continue;
                var value=job.get();
                boolean rejected=Set.of("FAILED","CANCELLED","EXPIRED").contains(value.status())
                        && value.attempt()==attempt;
                if(match.group(3)!=null || rejected)Files.deleteIfExists(file);
            }
        } catch(IOException failure) {
            org.slf4j.LoggerFactory.getLogger(getClass()).warn("Interrupted export file cleanup failed: {}",failure.getClass().getSimpleName());
        }
    }
    private void run(ReportExportRepository.Job job) {
        Path destination=service.artifact(job);
        Path part=destination.resolveSibling(destination.getFileName()+".part");
        boolean published=false;
        try {
            service.requireCompatibleReader(job);
            AuthUser principal=shortTx.execute(s -> restorer.restore(job.owner(),job.authVersion(),job.authEpoch()));
            var request=service.decode(job.request());
            ReportExportService.authorizeRequest(principal,request);
            var context=SecurityContextHolder.createEmptyContext();
            context.setAuthentication(new UsernamePasswordAuthenticationToken(principal,null,principal.getAuthorities()));
            SecurityContextHolder.setContext(context);
            long deadline=System.nanoTime()+TimeUnit.MINUTES.toNanos(10);
            checkpoint(job,0,deadline);
            MessageDigest digest=MessageDigest.getInstance("SHA-256");
            try(var writer=openWriter(request,job,deadline)) {
                try(var operation=ExportOperationCheckpoint.open(()->checkpoint(job,writer.rowCount(),deadline))) {
                readTx.executeWithoutResult(tx -> {
                    jdbc.execute("SET LOCAL statement_timeout='60s'");
                    var snapshot=jdbc.queryForObject("SELECT transaction_timestamp() AS at,txid_current_snapshot()::text AS identity",
                            (r,n) -> new Snapshot(r.getObject("at",OffsetDateTime.class),r.getString("identity")));
                    shortTx.executeWithoutResult(s -> repository.snapshot(job,snapshot.at(),snapshot.identity()));
                    writer.readSource();
                });
                }
                checkpoint(job,writer.rowCount(),deadline);
                if(Files.getFileStore(service.requireStorage()).getUsableSpace()<MIN_FREE+MAX_BYTES)
                    throw new IOException("Export file reservation unavailable");
                try(var file=Files.newOutputStream(part,StandardOpenOption.CREATE_NEW);
                    var hashing=new DigestOutputStream(file,digest)) {
                    writer.finish(new FilterOutputStream(hashing) {
                        long bytes;
                        long checked=System.nanoTime();
                        private void before(int amount) throws IOException {
                            bytes+=amount;
                            if(bytes>MAX_BYTES) throw new IOException("Export file size limit exceeded");
                            if(System.nanoTime()-checked>TimeUnit.SECONDS.toNanos(2)) {
                                checkpoint(job,writer.rowCount(),deadline);checked=System.nanoTime();
                            }
                        }
                        @Override public void write(int b) throws IOException { before(1);out.write(b); }
                        @Override public void write(byte[] b,int off,int len) throws IOException { before(len);out.write(b,off,len); }
                    });
                }
                checkpoint(job,writer.rowCount(),deadline);
                Files.move(part,destination,StandardCopyOption.ATOMIC_MOVE);
                long bytes=Files.size(destination);
                String sha=HexFormat.of().formatHex(digest.digest());
                published=Boolean.TRUE.equals(shortTx.execute(s -> repository.succeed(job,writer.rowCount(),bytes,sha)));
            }
        } catch(Exception failure) {
            var confirmed=shortTx.execute(s -> repository.find(job.id()));
            if(confirmed!=null && confirmed.isPresent() && "SUCCEEDED".equals(confirmed.get().status())
                    && confirmed.get().attempt()==job.attempt()) {
                published=true;
                return;
            }
            String message=failure instanceof SubmitterPrincipalRestorer.PrincipalChangedException
                    ?"账号或权限已变化，请重新创建导出任务"
                    :failure instanceof com.uten.imp.common.web.ApiException api?api.getMessage()
                    :"导出未完成，请检查任务条件及可用空间后重新创建任务";
            shortTx.executeWithoutResult(s -> repository.fail(job,message));
            org.slf4j.LoggerFactory.getLogger(getClass()).warn("Export job {} failed: {}",job.id(),failure.getClass().getSimpleName());
        } finally {
            SecurityContextHolder.clearContext();
            try {
                Files.deleteIfExists(part);
                if(!published) {
                    // COMMIT may have succeeded even when its acknowledgement was lost.
                    // Keep an uncertain candidate until an authoritative task read resolves it.
                    var confirmed=shortTx.execute(s -> repository.find(job.id()));
                    if(confirmed!=null && confirmed.isPresent()
                            && Set.of("FAILED","CANCELLED","EXPIRED").contains(confirmed.get().status())
                            && confirmed.get().attempt()==job.attempt())
                        Files.deleteIfExists(destination);
                }
            }
            catch(IOException cleanup) { org.slf4j.LoggerFactory.getLogger(getClass()).warn("Export temporary file cleanup failed for {}",job.id()); }
            catch(RuntimeException uncertain) { org.slf4j.LoggerFactory.getLogger(getClass()).warn("Export publication remains uncertain for {}",job.id()); }
            shortTx.executeWithoutResult(s -> repository.acknowledgeCancellation(job));
        }
    }
    private interface TaskWriter extends AutoCloseable {
        int rowCount();void readSource();void finish(OutputStream output)throws IOException;
        @Override void close()throws IOException;
    }
    private TaskWriter openWriter(ReportExportRequest request,ReportExportRepository.Job job,long deadline) {
        if(source.document(request)) {
            var document="pdf".equals(request.format())?pdf.openDocumentStream(service.requireStorage())
                    :xlsx.openDocumentStream(service.requireStorage());
            document.onCheckpoint(()->checkpoint(job,Math.toIntExact(document.primaryRowCount()),deadline));
            return new TaskWriter() {
                public int rowCount(){return Math.toIntExact(document.primaryRowCount());}
                public void readSource(){
                    try(var sink=DocumentPageSink.open(new DocumentPageSink.Consumer(){
                        public void begin(DocumentPageSink.Header header){checkpoint(job,rowCount(),deadline);document.begin(header);}
                        public void accept(DocumentPageSink.Page page){checkpoint(job,rowCount(),deadline);document.accept(page);}
                    })) {source.readDocument(request);}
                }
                public void finish(OutputStream output)throws IOException{document.finish(output);}
                public void close()throws IOException{document.close();}
            };
        }
        var table=xlsx.openStream(ReportExportSource.projection(request),ReportExportSource.scope(request),service.requireStorage());
        return new TaskWriter() {
            public int rowCount(){return table.rowCount();}
            public void readSource(){
                try(var cursor=com.uten.imp.common.report.ReportExportCursor.open();
                    var sink=ExportPageSink.open(page->{checkpoint(job,rowCount(),deadline);table.accept(page);})) {
                    var remainder=source.read(request);
                    // Naturally bounded fixed layouts still use the original authoritative adapter.
                    if(!remainder.rows().isEmpty())table.accept(remainder);
                }
            }
            public void finish(OutputStream output)throws IOException{table.finish(output);}
            public void close()throws IOException{table.close();}
        };
    }
    private record Snapshot(OffsetDateTime at,String identity) { }
    private void checkpoint(ReportExportRepository.Job job,int rows,long deadline) {
        if(Thread.currentThread().isInterrupted() || System.nanoTime()>deadline) throw new CancellationException();
        service.requireCurrentAccess(job);
        shortTx.executeWithoutResult(s -> {
            if(!repository.heartbeat(job,rows)) throw new CancellationException();
        });
        try {
            if(Files.getFileStore(service.requireStorage()).getUsableSpace()<MIN_FREE)
                throw new IOException("Export free space reserve reached");
        } catch(IOException error) { throw new UncheckedIOException(error); }
    }
    private void cleanupExpired() {
        var expired=shortTx.execute(s -> repository.expired());
        if(expired==null)return;
        for(var job:expired) {
            try {
                Files.deleteIfExists(service.artifact(job));
                shortTx.executeWithoutResult(s -> repository.expire(job.id()));
            } catch(IOException failure) {
                org.slf4j.LoggerFactory.getLogger(getClass()).warn("Expired export file cleanup failed for {}",job.id());
            }
        }
    }
    @PreDestroy public void close() { executor.shutdownNow(); }
}
