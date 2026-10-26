package com.uten.imp.common.export;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.apache.pdfbox.io.MemoryUsageSetting;
import org.apache.pdfbox.io.ScratchFile;
import org.apache.pdfbox.pdmodel.PDDocument;
import org.apache.pdfbox.pdmodel.font.PDType0Font;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

/** Bounded JSONL spool permits exact full-section width calculation without retaining result rows. */
final class StreamingPdfDocumentWriter implements StreamingDocumentWriter {
    private static final long MAX_CELLS=60_000;
    private final Path directory;
    private final ExportTemporaryBudget budget;
    private final String password;
    private final ObjectMapper json=new ObjectMapper().enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS)
            .enable(DeserializationFeature.USE_BIG_INTEGER_FOR_INTS);
    private final Map<String,DiskSection> sections=new LinkedHashMap<>();
    private final DocumentPageSink.RowBudget rowBudget=new DocumentPageSink.RowBudget();
    private DocumentPageSink.Header document;
    private Runnable taskCheckpoint=LegacyExportBudget::checkpoint;
    private long cells,rows,primaryRows,nextCheckpoint;
    private boolean failed,finished,closed;

    StreamingPdfDocumentWriter(Path parent,String password)throws IOException {
        TabularPdfExportService.validatePassword(password);
        this.password=password;
        directory=privateDirectory(parent,"report-document-");budget=new ExportTemporaryBudget(directory);
        try{budget.requireFreeReserve();}catch(IOException failure){removePrivateDirectory(directory);throw failure;}
    }
    static Path privateDirectory(Path parent,String prefix)throws IOException {
        Path root=Objects.requireNonNull(parent).toAbsolutePath().normalize();
        if(!Files.isDirectory(root,LinkOption.NOFOLLOW_LINKS)||Files.isSymbolicLink(root))throw new IOException("Invalid private export directory");
        if(!Set.of("report-document-","report-download-pdf-").contains(prefix))throw new IllegalArgumentException("Unknown private export directory prefix");
        Path child=root.resolve(prefix+UUID.randomUUID());
        if(!child.normalize().getParent().equals(root))throw new IOException("Invalid private export directory");
        return Files.createDirectory(child);
    }
    static void removePrivateDirectory(Path directory)throws IOException {
        Path root=directory.toAbsolutePath().normalize();
        if(!root.getFileName().toString().matches("(?:report-document-|report-download-pdf-)[0-9a-f-]{36}"))
            throw new IOException("Refusing an unknown export temporary directory");
        IOException failure=null;
        // Never follow links. Only this exact generated directory is eligible for cleanup.
        if(Files.exists(root,LinkOption.NOFOLLOW_LINKS))try(var paths=Files.walk(root)) {
            var owned=paths.limit(1001).sorted(Comparator.reverseOrder()).toList();
            if(owned.size()>1000)throw new IOException("Unexpected export temporary file count");
            for(Path path:owned)try{Files.deleteIfExists(path);}catch(IOException error){
                if(failure==null)failure=error;else failure.addSuppressed(error);
            }
        }
        if(failure!=null)throw failure;
    }
    @Override public void onCheckpoint(Runnable checkpoint){taskCheckpoint=Objects.requireNonNull(checkpoint);nextCheckpoint=0;}
    private void writable(){if(failed||finished||closed)throw new IllegalStateException("PDF document writer is not writable");}
    private void checkpoint() {
        if(Thread.currentThread().isInterrupted())throw new java.util.concurrent.CancellationException();
        long now=System.nanoTime();
        if(now>=nextCheckpoint) {
            taskCheckpoint.run();
            try{budget.requireFreeReserve();}catch(IOException failure){throw new UncheckedIOException(failure);}
            nextCheckpoint=now+TimeUnit.SECONDS.toNanos(1);
        }
    }
    private static ApiException tooManyCells(){return new ApiException(ErrorCode.VALIDATION_FAILED,"PDF 明细较多，请缩小范围或下载 Excel");}

    @Override public void begin(DocumentPageSink.Header header) {
        writable();
        try {
            if(document!=null)throw new IllegalStateException("Document header already supplied");
            checkpoint();
            rowBudget.begin(header);
            int primaryColumns=header.sections().stream().filter(DocumentPageSink.Section::primary).findFirst().orElseThrow().columns().size();
            if(header.expectedPrimaryRows()>=0)LegacyExportBudget.requireRows(header.expectedPrimaryRows());
            if(header.expectedPrimaryRows()>MAX_CELLS/primaryColumns)throw tooManyCells();
            document=header;
            for(var section:header.sections())sections.put(section.id(),new DiskSection(section));
        }catch(IOException error){failed=true;throw new UncheckedIOException(error);}
        catch(RuntimeException error){failed=true;throw error;}
    }
    @Override public void accept(DocumentPageSink.Page page) {
        writable();
        try {
            if(document==null)throw new IllegalStateException("Document header is required");
            checkpoint();
            DiskSection section=sections.get(page.sectionId());
            if(section==null)throw new IllegalArgumentException("Undeclared document section");
            rowBudget.accept(page);
            if(section.definition.primary())LegacyExportBudget.requireRows(primaryRows+page.rows().size());
            long nextCells=cells+(long)section.columns().size()*page.rows().size();
            if(nextCells>MAX_CELLS)throw tooManyCells();
            for(var values:page.rows()) {
                checkpoint();Map<String,Object> projected=new LinkedHashMap<>();
                for(var column:section.columns()) {
                    projected.put(column.key(),scalar(values.get(column.key())));
                    if(column.unitKey()!=null)projected.put(column.unitKey(),scalar(values.get(column.unitKey())));
                }
                section.output.write(json.writeValueAsString(projected));section.output.newLine();
                section.count++;rows++;if(section.definition.primary())primaryRows++;
            }
            cells=nextCells;
        }catch(IOException error){failed=true;throw new UncheckedIOException(error);}
        catch(RuntimeException error){failed=true;throw error;}
    }
    private static Object scalar(Object value) {
        if(value==null||value instanceof Number||value instanceof Boolean||value instanceof String)return value;
        if(value instanceof java.util.Date||value instanceof java.time.temporal.TemporalAccessor)return ExportCellValues.date(value);
        return Objects.toString(value);
    }
    @Override public long primaryRowCount(){return primaryRows;}
    @Override public long rowCount(){return rows;}

    @Override public void finish(OutputStream output)throws IOException {
        writable();
        if(document==null){failed=true;throw new IllegalStateException("Document header is required");}
        if(document.expectedPrimaryRows()>=0&&document.expectedPrimaryRows()!=primaryRows){failed=true;throw new IllegalStateException("Document primary rows are incomplete");}
        finished=true;
        try {
            closeSpools();checkpoint();
            long remaining=budget.remaining();
            if(remaining<=0)throw new IOException("Export temporary space limit exceeded");
            try(PDDocument pdf=new PDDocument(()->new ScratchFile(MemoryUsageSetting.setupTempFileOnly(remaining).setTempDir(directory.toFile())));
                var fontFile=TabularPdfExportService.class.getResourceAsStream("/fonts/NotoSansSCFullPdf.ttf")) {
                if(fontFile==null)throw new IOException("导出中文字体资源缺失");
                PDType0Font font=PDType0Font.load(pdf,fontFile,true);
                pdf.getDocumentInformation().setTitle(document.title());pdf.getDocumentInformation().setProducer("Uten IMP");
                var metadata=document.metadata().stream().map(value->Map.<String,Object>of("value",value)).toList();
                TabularPdfExportService.renderSection(pdf,font,document.title(),TabularPdfExportService.memorySection(
                        new ExportDocument.Section("版本与口径",List.of(new ExportColumn("value","来源说明",ExportColumn.TEXT)),metadata)),this::checkpoint);
                for(var section:sections.values())if(!section.definition.omitIfEmpty()||section.count>0)
                    TabularPdfExportService.renderSection(pdf,font,document.title(),section,this::checkpoint);
                checkpoint();TabularPdfExportService.protectDocument(pdf,password);
                pdf.save(ExportTemporaryBudget.artifactOutput(output,directory,this::checkpoint));
                checkpoint();
            }
        }catch(IOException|RuntimeException error){failed=true;throw error;}
    }

    private final class DiskSection implements TabularPdfExportService.RowSource {
        final DocumentPageSink.Section definition;
        final Path path;
        BufferedWriter output;
        long count;
        DiskSection(DocumentPageSink.Section definition)throws IOException {
            this.definition=definition;path=Files.createTempFile(directory,"section-",".jsonl");budget.files.add(path);
            output=new BufferedWriter(new OutputStreamWriter(budget.guard(Files.newOutputStream(path,StandardOpenOption.WRITE)),StandardCharsets.UTF_8));
        }
        @Override public String name(){return definition.name();}
        @Override public List<ExportColumn> columns(){return definition.columns();}
        @Override public TabularPdfExportService.RowCursor open()throws IOException {
            if(output!=null)throw new IllegalStateException("PDF spool must be closed before rendering");
            BufferedReader input=Files.newBufferedReader(path,StandardCharsets.UTF_8);
            return new TabularPdfExportService.RowCursor() {
                @Override public Map<String,Object> next()throws IOException {
                    String line=input.readLine();
                    return line==null?null:json.readValue(line,new com.fasterxml.jackson.core.type.TypeReference<Map<String,Object>>(){});
                }
                @Override public void close()throws IOException{input.close();}
            };
        }
    }
    private void closeSpools()throws IOException {
        IOException failure=null;
        for(var section:sections.values())if(section.output!=null) {
            try{section.output.close();}catch(IOException error){if(failure==null)failure=error;else failure.addSuppressed(error);}
            finally{section.output=null;}
        }
        if(failure!=null)throw failure;
    }
    @Override public void close()throws IOException {
        if(closed)return;closed=true;IOException failure=null;
        try{closeSpools();}catch(IOException error){failure=error;}
        try{removePrivateDirectory(directory);}catch(IOException error){if(failure==null)failure=error;else failure.addSuppressed(error);}
        if(failure!=null)throw failure;
    }
}
