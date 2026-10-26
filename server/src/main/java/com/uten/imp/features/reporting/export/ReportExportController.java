package com.uten.imp.features.reporting.export;

import com.uten.imp.common.export.*;
import com.uten.imp.common.web.*;
import com.uten.imp.audit.AuditService;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.*;
import java.io.*;
import java.nio.file.*;
import java.security.*;
import java.time.OffsetDateTime;
import java.util.UUID;
import java.util.concurrent.Semaphore;

@RestController
@RequestMapping("/api/report-export-jobs")
public class ReportExportController {
    private final ReportExportService service;
    private final WorkbookDownloadService workbooks;
    private final TabularPdfExportService pdf;
    private final AuditService audit;
    private final SecurityContextCurrentUser users;
    private final Semaphore downloads=new Semaphore(1,true);
    @org.springframework.beans.factory.annotation.Autowired
    public ReportExportController(ReportExportService service,WorkbookDownloadService workbooks,TabularPdfExportService pdf,
            AuditService audit,SecurityContextCurrentUser users) {
        this.service=service;this.workbooks=workbooks;this.pdf=pdf;this.audit=audit;this.users=users;
    }
    public ReportExportController(ReportExportService service,WorkbookDownloadService workbooks,AuditService audit,SecurityContextCurrentUser users) {
        this(service,workbooks,new TabularPdfExportService(),audit,users);
    }
    @PostMapping public ReportExportService.View submit(@Valid @RequestBody ReportExportRequest request) { return service.submit(request); }
    @GetMapping public java.util.List<ReportExportService.View> recent() { return service.recent(); }
    @GetMapping("/capabilities") public java.util.Map<String,Boolean> capabilities() { return java.util.Map.of("available",service.available()); }
    @GetMapping("/{id}") public ReportExportService.View get(@PathVariable UUID id) { return service.get(id); }
    @GetMapping("/{id}/download-authorization")
    public java.util.Map<String,Boolean> downloadAuthorization(@PathVariable UUID id) {
        service.authorizedArtifact(id);
        return java.util.Map.of("authorized",true);
    }
    @PostMapping("/{id}/cancel") public ReportExportService.View cancel(@PathVariable UUID id) { return service.cancel(id); }
    @PostMapping("/{id}/download")
    public void download(@PathVariable UUID id,@Valid @RequestBody ExportPasswordRequest request,HttpServletResponse response) throws IOException {
        var job=service.authorizedArtifact(id);
        if(!"SUCCEEDED".equals(job.status()) || job.expiresAt().isBefore(OffsetDateTime.now()))
            throw new ApiException(ErrorCode.CONFLICT,"导出尚未完成或下载已到期，请核对任务状态");
        if(!downloads.tryAcquire()) throw new ApiException(ErrorCode.RATE_LIMITED,"另一个导出正在下载，请稍后重试");
        ExportDownloadFiles temporary=null;
        try {
            Path original=service.artifact(job);
            if(!Files.isRegularFile(original,LinkOption.NOFOLLOW_LINKS) || Files.size(original)!=job.bytes())
                throw new ApiException(ErrorCode.CONFLICT,"导出文件不可用，请重新创建任务");
            MessageDigest sha;
            try { sha=MessageDigest.getInstance("SHA-256"); } catch(NoSuchAlgorithmException impossible) { throw new IllegalStateException(impossible); }
            try(var input=new DigestInputStream(Files.newInputStream(original),sha)) { input.transferTo(OutputStream.nullOutputStream()); }
            if(!java.util.HexFormat.of().formatHex(sha.digest()).equals(job.sha256()))
                throw new ApiException(ErrorCode.CONFLICT,"导出文件校验失败，请重新创建任务");
            Path output=original;
            boolean pdfFormat="pdf".equals(service.decode(job.request()).format());
            if(request.password()!=null && !request.password().isEmpty()) {
                temporary=ExportDownloadFiles.open(service.requireStorage(),id);
                if(pdfFormat)pdf.protect(original,temporary.file(),request.password());
                else workbooks.protect(original,temporary.file(),request.password());
                output=temporary.file();
            }
            service.authorizedArtifact(id);
            response.setContentType(pdfFormat?"application/pdf":"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet");
            response.setHeader("Content-Disposition",DownloadContentDisposition.attachment("report_"+id+(pdfFormat?".pdf":".xlsx")));
            response.setHeader("Cache-Control","no-store");
            response.setContentLengthLong(Files.size(output));
            try(var input=Files.newInputStream(output)) {
                byte[] buffer=new byte[65536];int count;long checked=System.nanoTime();
                while((count=input.read(buffer))!=-1) {
                    if(System.nanoTime()-checked>2_000_000_000L) {service.authorizedArtifact(id);checked=System.nanoTime();}
                    response.getOutputStream().write(buffer,0,count);
                }
            }
            var user=users.get().orElseThrow();
            audit.logExplicit(user.getId(),user.getLoginAccount(),"export_report_download","report_export_jobs",id+"/"+job.rows()+"rows","success");
        } finally {
            try {
                if(temporary!=null)temporary.close();
            } catch(IOException cleanup) {
                org.slf4j.LoggerFactory.getLogger(getClass()).warn("Export download copy cleanup failed for {}",id);
            } finally {downloads.release();}
        }
    }
}
