package com.uten.imp.common.export;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Isolation;
import org.springframework.transaction.annotation.Transactional;
import java.io.*;
import java.nio.file.*;

/** Compatibility bridge for small synchronous documents. Sources and formatters
 * are the same as durable jobs; only the final bounded HTTP byte[] is retained. */
@Service
@RequiredArgsConstructor
@Slf4j
public class BoundedDocumentExportService {
    private final XlsxExportService excel;
    private final TabularPdfExportService pdf;
    private final WorkbookDownloadService protection;
    private final ExportDocumentProjectionService projections;

    @Transactional(readOnly=true,isolation=Isolation.REPEATABLE_READ)
    public byte[] build(String format,String password,TableColumnProjection projection,
                        String section,String scope,Runnable readSource) {
        if(!"pdf".equals(format)&&!"xlsx".equals(format))throw new ApiException(ErrorCode.VALIDATION_FAILED,"导出格式无效");
        TabularPdfExportService.validatePassword(password);
        Path root=null,privateRoot=null;
        Throwable primary=null;
        try {
            // JDK temp-directory defaults are owner-only on POSIX; the nested
            // writer uses its existing whitelist and cleanup implementation.
            privateRoot=Files.createTempDirectory("uten-document-sync-");
            root=StreamingPdfDocumentWriter.privateDirectory(privateRoot,"report-document-");
            Path plain=root.resolve("document.bin");
            try(var writer="pdf".equals(format)?pdf.openDocumentStream(root,password):excel.openDocumentStream(root)) {
                writer.onCheckpoint(ExportOperationCheckpoint::check);
                try(var sink=DocumentPageSink.open(projections.stream(writer,projection,section,scope))) {readSource.run();}
                ExportOperationCheckpoint.check();
                try(var raw=Files.newOutputStream(plain,StandardOpenOption.CREATE_NEW);
                    var output=ExportTemporaryBudget.artifactOutput(raw,root,
                        ExportOperationCheckpoint::check,ExportResourceLimits.LEGACY_ARTIFACT_BYTES)) {writer.finish(output);}
            }
            Path ready=plain;
            if("xlsx".equals(format)&&password!=null&&!password.isEmpty()) {
                ready=root.resolve("protected.bin");ExportOperationCheckpoint.check();protection.protect(plain,ready,password);
            }
            ExportOperationCheckpoint.check();
            if(Files.size(ready)>ExportResourceLimits.LEGACY_ARTIFACT_BYTES)throw new IOException("Small export size limit exceeded");
            byte[] bytes=Files.readAllBytes(ready);ExportOperationCheckpoint.check();return bytes;
        } catch(IOException resource) {
            var rejected=new ApiException(ErrorCode.VALIDATION_FAILED,"同步导出超过文件或临时资源预算，请使用后台导出任务或收窄筛选；本次未生成文件");
            rejected.addSuppressed(resource);primary=rejected;throw rejected;
        } catch(RuntimeException|Error failure) {
            primary=failure;throw failure;
        } finally {
            IOException cleanup=null;
            if(root!=null)try{StreamingPdfDocumentWriter.removePrivateDirectory(root);}catch(IOException failure){cleanup=failure;}
            if(privateRoot!=null)try{Files.deleteIfExists(privateRoot);}catch(IOException failure){
                if(cleanup==null)cleanup=failure;else cleanup.addSuppressed(failure);
            }
            if(cleanup!=null) {
                log.warn("Synchronous export private temporary cleanup failed; privateRoot={}",privateRoot,cleanup);
                if(primary!=null)primary.addSuppressed(cleanup);
                else {
                    var rejected=new ApiException(ErrorCode.INTERNAL,"导出临时资源未能安全清理，本次未交付文件，请稍后重试或联系管理员");
                    rejected.addSuppressed(cleanup);throw rejected;
                }
            }
        }
    }
}
