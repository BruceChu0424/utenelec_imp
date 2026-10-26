package com.uten.imp.common.export;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.apache.pdfbox.Loader;
import org.apache.pdfbox.pdmodel.encryption.InvalidPasswordException;
import org.apache.pdfbox.text.PDFTextStripper;
import org.apache.poi.poifs.crypt.*;
import org.apache.poi.poifs.filesystem.POIFSFileSystem;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.transaction.annotation.*;
import java.io.*;
import java.math.BigDecimal;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class BoundedDocumentExportServiceTest {
    @TempDir Path temporary;
    private final List<Path> owned=new ArrayList<>();
    private BoundedDocumentExportService service() {
        var excel=spy(new XlsxExportService());
        doAnswer(call->{owned.add(call.getArgument(0));return call.callRealMethod();}).when(excel).openDocumentStream(any(Path.class));
        return new BoundedDocumentExportService(excel,new TabularPdfExportService(),new WorkbookDownloadService(),new ExportDocumentProjectionService(null));
    }
    private void facts() {
        var sink=Objects.requireNonNull(DocumentPageSink.current());
        sink.begin(new DocumentPageSink.Header("受控原件",List.of("原始精度与来源"),List.of(new DocumentPageSink.Section("facts","原件",List.of(
                new ExportColumn("name","名称",ExportColumn.TEXT),new ExportColumn("amount","金额",ExportColumn.QTY)),true,false)),1));
        sink.accept(new DocumentPageSink.Page("facts",List.of(Map.of("name","原始龘","amount",new BigDecimal("1234567890123456.000000000000000001")))));
    }
    @Test void smallXlsxUsesTheStreamingSourceAndPreservesExactCellsThenCleansItsPrivateFiles() throws Exception {
        byte[] bytes=service().build("xlsx",null,null,"原件","view_goods_cost",this::facts);
        try(var workbook=new XSSFWorkbook(new ByteArrayInputStream(bytes))) {
            var row=workbook.getSheet("原件").getRow(1);
            assertThat(row.getCell(0).getStringCellValue()).isEqualTo("原始龘");
            assertThat(row.getCell(1).getStringCellValue()).isEqualTo("1234567890123456.000000000000000001");
        }
        assertThat(owned).hasSize(1).allSatisfy(path->{assertThat(Files.exists(path)).isFalse();assertThat(Files.exists(path.getParent())).isFalse();});
        assertThat(DocumentPageSink.current()).isNull();
    }
    @Test void bothOriginalPasswordFormatsStayProtected() throws Exception {
        var bridge=service();byte[] xlsx=bridge.build("xlsx","test-only",null,"原件","view_goods_cost",this::facts);
        try(var file=new POIFSFileSystem(new ByteArrayInputStream(xlsx))) {
            var decryptor=Decryptor.getInstance(new EncryptionInfo(file));assertThat(decryptor.verifyPassword("test-only")).isTrue();
            try(var workbook=new XSSFWorkbook(decryptor.getDataStream(file))){assertThat(workbook.getSheet("原件").getRow(1).getCell(0).getStringCellValue()).isEqualTo("原始龘");}
        }
        byte[] pdf=bridge.build("pdf","test-only",null,"原件","view_goods_cost",this::facts);
        assertThatThrownBy(()->Loader.loadPDF(pdf)).isInstanceOf(InvalidPasswordException.class);
        try(var document=Loader.loadPDF(pdf,"test-only")){assertThat(new PDFTextStripper().getText(document)).contains("原始龘","1234567890123456.000000000000000001");}
    }
    @Test void failedSourceNeverReturnsHalfAFileAndStillClosesItsOwnedDirectory() {
        var denied=new ApiException(ErrorCode.READ_SCOPE_CHANGED);var bridge=service();
        assertThatThrownBy(()->bridge.build("xlsx",null,null,"原件","view_goods_cost",()->{facts();throw denied;})).isSameAs(denied);
        assertThat(owned).hasSize(1).allSatisfy(path->{assertThat(Files.exists(path)).isFalse();assertThat(Files.exists(path.getParent())).isFalse();});
        assertThat(DocumentPageSink.current()).isNull();
    }
    @Test void oneByteOverCustomOutputBudgetFailsBeforeWritingAndKeepsTheCommonCheckpoints() throws Exception {
        var bytes=new ByteArrayOutputStream();var checks=new AtomicInteger();
        var output=ExportTemporaryBudget.artifactOutput(bytes,temporary,checks::incrementAndGet,8);
        output.write(new byte[8]);assertThatThrownBy(()->output.write(9)).isInstanceOf(IOException.class);
        assertThat(bytes.size()).isEqualTo(8);assertThat(checks.get()).isGreaterThan(0);
        assertThatThrownBy(()->ExportTemporaryBudget.artifactOutput(bytes,temporary,()->{},ExportResourceLimits.ARTIFACT_BYTES+1)).isInstanceOf(IllegalArgumentException.class);
    }
    @Test void theBridgeDeclaresOneReadOnlyRepeatableReadTransaction() throws Exception {
        var method=BoundedDocumentExportService.class.getMethod("build",String.class,String.class,TableColumnProjection.class,String.class,String.class,Runnable.class);
        var transaction=method.getAnnotation(Transactional.class);assertThat(transaction.readOnly()).isTrue();assertThat(transaction.isolation()).isEqualTo(Isolation.REPEATABLE_READ);
    }
    @Test void failedOutputGuardFactoryStillClosesTheAlreadyOpenedRawFile() throws Exception {
        var raw=new AtomicReference<OutputStream>();var bridge=service();
        try(var factory=mockStatic(ExportTemporaryBudget.class,CALLS_REAL_METHODS)) {
            factory.when(()->ExportTemporaryBudget.artifactOutput(any(OutputStream.class),any(Path.class),any(Runnable.class),anyLong()))
                    .thenAnswer(call->{raw.set(call.getArgument(0));throw new IOException("synthetic reserve failure");});
            assertThatThrownBy(()->bridge.build("xlsx",null,null,"原件","view_goods_cost",this::facts)).isInstanceOf(ApiException.class);
        }
        assertThat(raw.get()).isNotNull();assertThatThrownBy(()->raw.get().write(1)).isInstanceOf(IOException.class);
        assertThat(owned).allSatisfy(path->assertThat(Files.exists(path)).isFalse());
    }
    @Test void cleanupFailureIsObservableAndNeverReplacesTheOriginalBusinessDenial() throws Exception {
        var denied=new ApiException(ErrorCode.READ_SCOPE_CHANGED);var bridge=service();
        try(var cleanup=mockStatic(StreamingPdfDocumentWriter.class,CALLS_REAL_METHODS)) {
            cleanup.when(()->StreamingPdfDocumentWriter.removePrivateDirectory(any(Path.class))).thenThrow(new IOException("synthetic cleanup failure"));
            assertThatThrownBy(()->bridge.build("xlsx",null,null,"原件","view_goods_cost",()->{facts();throw denied;})).isSameAs(denied);
            assertThat(denied.getSuppressed()).anySatisfy(error->assertThat(error).isInstanceOf(IOException.class).hasMessage("synthetic cleanup failure"));
        } finally {for(Path path:owned){StreamingPdfDocumentWriter.removePrivateDirectory(path);Files.deleteIfExists(path.getParent());}}
    }
    @Test void otherwiseSuccessfulOutputIsNotPublishedWhenItsPrivateCleanupFails() throws Exception {
        var bridge=service();
        try(var cleanup=mockStatic(StreamingPdfDocumentWriter.class,CALLS_REAL_METHODS)) {
            cleanup.when(()->StreamingPdfDocumentWriter.removePrivateDirectory(any(Path.class))).thenThrow(new IOException("synthetic cleanup failure"));
            assertThatThrownBy(()->bridge.build("xlsx",null,null,"原件","view_goods_cost",this::facts))
                    .isInstanceOf(ApiException.class).hasMessageContaining("未交付文件");
        } finally {for(Path path:owned){StreamingPdfDocumentWriter.removePrivateDirectory(path);Files.deleteIfExists(path.getParent());}}
    }
}
