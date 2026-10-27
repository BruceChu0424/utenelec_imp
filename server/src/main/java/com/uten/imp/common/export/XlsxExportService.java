package com.uten.imp.common.export;

import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.CellStyle;
import org.apache.poi.ss.usermodel.FillPatternType;
import org.apache.poi.ss.usermodel.Font;
import org.apache.poi.ss.usermodel.HorizontalAlignment;
import org.apache.poi.ss.usermodel.IndexedColors;
import org.apache.poi.ss.usermodel.Row;
import org.apache.poi.ss.usermodel.Sheet;
import org.apache.poi.xssf.streaming.SXSSFWorkbook;
import org.springframework.stereotype.Service;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;
import java.util.Objects;

/**
 * 把「列定义 + 行」导出为 .xlsx 字节（SXSSF 流式，防几万行 OOM）。
 *
 * <p>格式约定(对齐前端 formatReportCell)：金额/数量 = 2 位小数、用量 (qty) = 常规格式按存储值全精度、
 * 日期 = yyyy-MM-dd、布尔 = 是/否、其余文本。
 * 表头加粗灰底居中、冻结首行、列宽按表头长度估。数值右对齐 + 千分位。
 *
 * <p>输入约定：报表行由 {@code execute().norm()} 归一化——日期已转 yyyy-MM-dd 字符串、金额为 BigDecimal/Number。
 */
@Service
public class XlsxExportService {

    @org.springframework.beans.factory.annotation.Autowired
    private org.springframework.beans.factory.ObjectProvider<ExportTableProjectionService> projections;

    public byte[] build(List<ExportColumn> columns, List<Map<String,Object>> rows,
                        TableColumnProjection projection, String allowedScope) {
        if(projection==null)return build(columns,rows);
        ExportPayload projected=projections.getObject().project(columns,rows,projection,allowedScope);
        return build(projected.columns(),projected.rows());
    }

    /** SXSSF 滚动窗口（同时在内存的行数；超出写临时文件）。 */
    private static final int ROW_ACCESS_WINDOW = 200;

    /** Multi-sheet snapshot export; this never rereads mutable platform values. */
    public byte[] buildDocument(ExportDocument document) {
        LegacyExportBudget.requireRows(document.sections().getFirst().rows().size());
        try (var out=new ByteArrayOutputStream();var writer=openDocumentStream(null)) {
            DocumentPageSink.emitDocument(document,writer);
            writer.finish(out);
            return out.toByteArray();
        } catch(IOException failure) {
            throw new IllegalStateException("生成 Excel 失败",failure);
        }
    }
    public byte[] build(List<ExportColumn> columns, List<Map<String, Object>> rows) {
        LegacyExportBudget.requireRows(rows.size());
        try (var out = new ByteArrayOutputStream(); var writer = openStream(null, null)) {
            writer.accept(new ExportPayload(columns, rows, rows.size()));
            writer.finish(out);
            return out.toByteArray();
        } catch (IOException error) {
            throw new IllegalStateException("生成 Excel 失败", error);
        }
    }

    /** Bounded page writer; shares the same projection, precision, units and literal text rules. */
    public StreamingWorkbook openStream(TableColumnProjection projection, String allowedScope) {
        return new StreamingWorkbook(projection, allowedScope, null);
    }

    public StreamingWorkbook openStream(TableColumnProjection projection, String allowedScope, java.nio.file.Path temporaryDirectory) {
        return new StreamingWorkbook(projection, allowedScope, new ExportTemporaryBudget(temporaryDirectory));
    }

    public StreamingDocumentWriter openDocumentStream(java.nio.file.Path temporaryDirectory) {
        return new DocumentWorkbook(new StreamingWorkbook(null,null,
                temporaryDirectory==null?null:new ExportTemporaryBudget(temporaryDirectory)));
    }

    private static org.apache.poi.xssf.streaming.SheetDataWriter privateSheetWriter(ExportTemporaryBudget budget) throws IOException {
        var strategy = new org.apache.poi.util.DefaultTempFileCreationStrategy(budget.directory.toFile()) {
            @Override public java.io.File createTempFile(String prefix, String suffix) throws IOException {
                var path = java.nio.file.Files.createTempFile(budget.directory,"report-sheet-",suffix);
                budget.files.add(path);
                return path.toFile();
            }
        };
        try {
            // POI scopes this strategy to the current thread and restores any
            // previous strategy on both success and failure. Other exports keep
            // their own directory and budget; no process-wide setting changes.
            return org.apache.poi.util.TempFile.withStrategy(strategy, () -> {
                try {
                    return new org.apache.poi.xssf.streaming.GZIPSheetDataWriter() {
                        @Override protected java.io.OutputStream decorateOutputStream(java.io.FileOutputStream output) throws IOException {
                            return new java.util.zip.GZIPOutputStream(budget.guard(output));
                        }
                    };
                } catch (IOException failure) {
                    throw new java.io.UncheckedIOException(failure);
                }
            });
        } catch (java.io.UncheckedIOException failure) {
            throw failure.getCause();
        }
    }

    public final class StreamingWorkbook implements AutoCloseable {
        private final SXSSFWorkbook workbook;
        private final ExportTemporaryBudget tempBudget;
        private final TableColumnProjection projection;
        private final String allowedScope;
        private final CellStyle header;
        private final CellStyle number;
        private final CellStyle quantity;
        private final CellStyle text;
        private final Map<String, CellStyle> units = new java.util.HashMap<>();
        private final Map<String,SheetState> sheets=new java.util.LinkedHashMap<>();
        private boolean finished;
        private boolean written;
        private boolean closed;
        private final class SheetState {
            final Sheet sheet;final List<ExportColumn> columns;int rowIndex=1;
            SheetState(Sheet sheet,List<ExportColumn> columns){this.sheet=sheet;this.columns=List.copyOf(columns);}
        }

        private StreamingWorkbook(TableColumnProjection projection, String allowedScope, ExportTemporaryBudget tempBudget) {
            this.tempBudget = tempBudget;
            workbook = tempBudget == null ? new SXSSFWorkbook(ROW_ACCESS_WINDOW) : new SXSSFWorkbook(ROW_ACCESS_WINDOW) {
                @Override protected org.apache.poi.xssf.streaming.SheetDataWriter createSheetDataWriter() throws IOException {
                    return privateSheetWriter(tempBudget);
                }
            };
            this.projection = projection;
            this.allowedScope = allowedScope;
            workbook.setCompressTempFiles(true);
            header = workbook.createCellStyle();
            Font font = workbook.createFont();
            font.setBold(true);
            header.setFont(font);
            header.setFillForegroundColor(IndexedColors.GREY_25_PERCENT.getIndex());
            header.setFillPattern(FillPatternType.SOLID_FOREGROUND);
            header.setAlignment(HorizontalAlignment.CENTER);
            header.setDataFormat(workbook.createDataFormat().getFormat("@"));
            number = workbook.createCellStyle();
            number.setDataFormat(workbook.createDataFormat().getFormat("#,##0.00"));
            number.setAlignment(HorizontalAlignment.RIGHT);
            quantity = workbook.createCellStyle();
            quantity.setDataFormat(workbook.createDataFormat().getFormat("General"));
            quantity.setAlignment(HorizontalAlignment.RIGHT);
            text = workbook.createCellStyle();
            text.setDataFormat(workbook.createDataFormat().getFormat("@"));
        }

        public void accept(ExportPayload page) {
            if (finished||closed) throw new IllegalStateException("Workbook is already finished or closed");
            ExportPayload selected = projection == null ? page
                    : projections.getObject().project(page.columns(), page.rows(), projection, allowedScope);
            LegacyExportBudget.requireRows((long)rowCount()+selected.rows().size());
            append(section("data","data",selected.columns(),false),selected.columns(),selected.rows());
        }

        private SheetState section(String id,String name,List<ExportColumn> columns,boolean document) {
            if(finished||closed)throw new IllegalStateException("Workbook is already finished or closed");
            SheetState state=sheets.get(id);
            if(state==null) {
                String safeName=org.apache.poi.ss.util.WorkbookUtil.createSafeSheetName(name);
                if(workbook.getSheet(safeName)!=null) {
                    int suffix=sheets.size()+1;
                    do{safeName="表"+suffix++;}while(workbook.getSheet(safeName)!=null);
                }
                Sheet sheet=workbook.createSheet(safeName);
                state=new SheetState(sheet,columns);sheets.put(id,state);
                Row labels = sheet.createRow(0);
                for (int i = 0; i < columns.size(); i++) {
                    ExportColumn column = columns.get(i);
                    Cell label = labels.createCell(i);
                    label.setCellValue(column.label());
                    label.setCellStyle(header);
                    int width = column.width() == null
                            ? document?Math.max(12,Math.min(42,column.label().length()*2+4)):Math.min(50, Math.max(10, column.label().length() + 4))
                            : Math.min(100, Math.max(document?8:6, (int) Math.round(column.width() / 7)));
                    sheet.setColumnWidth(i, width * 256);
                }
                sheet.createFreezePane(0, 1);
                if(document) {
                    sheet.setRepeatingRows(new org.apache.poi.ss.util.CellRangeAddress(0,0,-1,-1));
                    sheet.getPrintSetup().setLandscape(true);sheet.setFitToPage(true);
                    sheet.getPrintSetup().setFitWidth((short)1);sheet.getPrintSetup().setFitHeight((short)0);
                }
            }
            return state;
        }

        private void append(SheetState state,List<ExportColumn> columns,List<Map<String,Object>> rows) {
            if (!state.columns.equals(columns)) {
                throw new IllegalStateException("Export columns changed while writing");
            }
            for (Map<String, Object> values : rows) {
                if (Thread.currentThread().isInterrupted()) throw new java.util.concurrent.CancellationException();
                if (state.rowIndex >= 1_048_576) throw new IllegalStateException("Excel row limit exceeded");
                Row row = state.sheet.createRow(state.rowIndex++);
                for (int i = 0; i < columns.size(); i++) {
                    ExportColumn column = columns.get(i);
                    Cell cell = row.createCell(i);
                    writeCell(cell, column.type(), values == null ? null : values.get(column.key()), number, quantity, text);
                    applyUnit(cell, column, values, workbook, units);
                }
            }
        }

        public int rowCount() { return Math.toIntExact(sheets.values().stream().mapToLong(state->state.rowIndex-1).sum()); }

        public void finish(java.io.OutputStream output) throws IOException {
            finish(output,LegacyExportBudget::checkpoint);
        }
        private void finish(java.io.OutputStream output,Runnable checkpoint)throws IOException {
            if (finished || closed || sheets.isEmpty()) throw new IllegalStateException("Workbook is not writable");
            finished = true;
            var bounded=ExportTemporaryBudget.artifactOutput(output,tempBudget==null?null:tempBudget.directory,checkpoint);
            if (tempBudget == null) workbook.write(bounded);
            else workbook.writeAvoidingTempFiles(bounded);
            written=true;
        }

        @Override public void close() throws IOException {
            if(closed)return;closed=true;
            IOException failure=null;
            // POI close also disposes sheet files after closing their writers.
            // An unpublished window can be discarded; a successful write is already flushed.
            for(Sheet raw:workbook)if(raw instanceof org.apache.poi.xssf.streaming.SXSSFSheet sheet) {
                if(!written) {
                    var pending=new java.util.ArrayList<Row>();sheet.forEach(pending::add);
                    pending.forEach(sheet::removeRow);
                }
                try{sheet.flushRows();}catch(IOException error){if(failure==null)failure=error;else failure.addSuppressed(error);}
            }
            try { workbook.close(); }catch(Exception error){
                IOException closing=error instanceof IOException io?io:new IOException("Closing workbook failed",error);
                if(failure==null)failure=closing;else failure.addSuppressed(closing);
            }
            if(tempBudget!=null)try{tempBudget.cleanupFiles();}catch(IOException error){
                if(failure==null)failure=error;else failure.addSuppressed(error);
            }
            if(failure!=null)throw failure;
        }
    }

    private static final class DocumentWorkbook implements StreamingDocumentWriter {
        final StreamingWorkbook writer;
        final DocumentPageSink.RowBudget rowBudget=new DocumentPageSink.RowBudget();
        DocumentPageSink.Header document;
        boolean failed,finished,closed;
        Runnable checkpoint=LegacyExportBudget::checkpoint;
        DocumentWorkbook(StreamingWorkbook writer){this.writer=writer;}
        @Override public void onCheckpoint(Runnable value){checkpoint=Objects.requireNonNull(value);}
        private void writable(){if(failed||finished||closed)throw new IllegalStateException("Document writer is not writable");}
        @Override public void begin(DocumentPageSink.Header header) {
            writable();if(document!=null){failed=true;throw new IllegalStateException("Document header already supplied");}
            try {
                if(writer.tempBudget!=null)writer.tempBudget.requireFreeReserve();
                rowBudget.begin(header);
                if(header.expectedPrimaryRows()>=0)LegacyExportBudget.requireRows(header.expectedPrimaryRows());
                document=Objects.requireNonNull(header);
                Sheet info=writer.workbook.createSheet("说明");int row=0;
                for(String value:java.util.stream.Stream.concat(java.util.stream.Stream.of(header.title()),header.metadata().stream()).toList()) {
                    Cell cell=info.createRow(row++).createCell(0);cell.setCellValue(value);cell.setCellStyle(writer.text);
                }
                info.setColumnWidth(0,100*256);
                for(var section:header.sections())writer.section(section.id(),section.name(),section.columns(),true);
            }catch(IOException failure){failed=true;throw new java.io.UncheckedIOException(failure);}
            catch(RuntimeException failure){failed=true;throw failure;}
        }
        @Override public void accept(DocumentPageSink.Page page) {
            writable();if(document==null){failed=true;throw new IllegalStateException("Document header is required");}
            try {
                var section=document.sections().stream().filter(candidate->candidate.id().equals(page.sectionId())).findFirst()
                        .orElseThrow(()->new IllegalArgumentException("Undeclared document section"));
                rowBudget.accept(page);
                if(section.primary())LegacyExportBudget.requireRows(primaryRowCount()+page.rows().size());
                writer.append(writer.sheets.get(section.id()),section.columns(),page.rows());
            }catch(RuntimeException failure){failed=true;throw failure;}
        }
        @Override public long primaryRowCount(){
            if(document==null)return 0;
            String id=document.sections().stream().filter(DocumentPageSink.Section::primary).findFirst().orElseThrow().id();
            return writer.sheets.get(id).rowIndex-1;
        }
        @Override public long rowCount(){return writer.rowCount();}
        @Override public void finish(java.io.OutputStream output)throws IOException {
            writable();if(document==null)throw new IllegalStateException("Document header is required");
            if(document.expectedPrimaryRows()>=0&&primaryRowCount()!=document.expectedPrimaryRows()) {
                failed=true;throw new IllegalStateException("Document primary rows are incomplete");
            }
            finished=true;
            for(var section:document.sections()) {
                var state=writer.sheets.get(section.id());
                if(section.omitIfEmpty()&&state.rowIndex==1) {
                    ((org.apache.poi.xssf.streaming.SXSSFSheet)state.sheet).flushRows();
                    writer.workbook.removeSheetAt(writer.workbook.getSheetIndex(state.sheet));
                }
            }
            writer.finish(output,checkpoint);
        }
        @Override public void close()throws IOException{closed=true;writer.close();}
    }

    private static void writeCell(Cell cell, String type, Object v, CellStyle numStyle, CellStyle qtyStyle,
                                  CellStyle textStyle) {
        if (v == null) return;
        switch (type == null ? ExportColumn.TEXT : type) {
            case ExportColumn.MONEY, ExportColumn.NUMBER, ExportColumn.QTY -> {
                BigDecimal d = ExportCellValues.decimal(v);
                if (d != null) {
                    double value=d.doubleValue();
                    if(d.stripTrailingZeros().precision()>15 || !Double.isFinite(value)
                            || d.signum()!=0&&Math.abs(value)<Double.MIN_NORMAL) {
                        cell.setCellValue(ExportCellValues.exactText(d)); cell.setCellStyle(textStyle);
                    } else {
                        cell.setCellValue(value);
                        cell.setCellStyle(ExportColumn.MONEY.equals(type) ? numStyle : qtyStyle);
                    }
                } else {
                    // 非数值回退：按文本写，防公式注入
                    cell.setCellValue(Objects.toString(v));
                    cell.setCellStyle(textStyle);
                }
            }
            case ExportColumn.BOOL -> { cell.setCellValue(ExportCellValues.bool(v) ? "是" : "否"); cell.setCellStyle(textStyle); }
            case ExportColumn.DATE -> { cell.setCellValue(ExportCellValues.date(v)); cell.setCellStyle(textStyle); }
            default -> { cell.setCellValue(Objects.toString(v)); cell.setCellStyle(textStyle); }
        }
    }

    /** Excel literal number formats show units while retaining numeric and exact-text cell values. */
    private static void applyUnit(Cell cell, ExportColumn column, Map<String, Object> row,
                                  SXSSFWorkbook workbook, Map<String, CellStyle> cache) {
        Object raw = row == null ? null : row.get(column.key());
        if (raw == null || ExportCellValues.decimal(raw) == null) return;
        String unit=ExportCellValues.unit(column,row);
        if(unit.isEmpty())return;
        String base = cell.getCellType() == org.apache.poi.ss.usermodel.CellType.STRING ? "@"
                : ExportColumn.MONEY.equals(column.type()) ? "#,##0.00############" : "0.################";
        String literal = unit.replace("\\", "\\\\").replace("\"", "\\\"");
        String format = base + "\" " + literal + "\"";
        CellStyle style = cache.get(format);
        if (style == null) {
            style = workbook.createCellStyle();
            style.cloneStyleFrom(cell.getCellStyle());
            style.setDataFormat(workbook.createDataFormat().getFormat(format));
            cache.put(format, style);
        }
        cell.setCellStyle(style);
    }

}
