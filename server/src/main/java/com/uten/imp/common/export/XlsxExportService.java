package com.uten.imp.common.export;

import org.apache.poi.ss.usermodel.Cell;
import org.apache.poi.ss.usermodel.CellStyle;
import org.apache.poi.ss.usermodel.DataFormatter;
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
 * <p>格式约定(对齐前端 formatReportCell)：金额至少显示2位并完整保留原有小数，用量按存储值全精度；
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
        return build(new ExportPayload(columns,rows,rows.size()),projection,allowedScope);
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
        return build(new ExportPayload(columns,rows,rows.size()),null,null);
    }
    public byte[] build(ExportPayload payload,TableColumnProjection projection,String allowedScope) {
        List<Map<String,Object>> rows=payload.rows();
        LegacyExportBudget.requireRows(rows.size());
        try (var out = new ByteArrayOutputStream(); var writer = openStream(projection, allowedScope)) {
            writer.accept(payload);
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
                    return new RichTextSheetDataWriter() {
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

    /** Preserve inline rich runs without retaining every string in a shared
     * strings table. Ordinary cells still use POI's bounded streaming writer. */
    private static class RichTextSheetDataWriter extends org.apache.poi.xssf.streaming.GZIPSheetDataWriter {
        RichTextSheetDataWriter() throws IOException { super(); }

        @Override public void writeCell(int columnIndex, Cell cell) throws IOException {
            if(cell==null||cell.getCellType()!=org.apache.poi.ss.usermodel.CellType.STRING
                    ||!(cell.getRichStringCellValue() instanceof org.apache.poi.xssf.usermodel.XSSFRichTextString rich)
                    ||!rich.hasFormatting()) {
                super.writeCell(columnIndex,cell);
                return;
            }
            String address=org.apache.poi.ss.util.CellReference.convertNumToColString(columnIndex)+(cell.getRowIndex()+1);
            int style=Short.toUnsignedInt(cell.getCellStyle().getIndex());
            _out.write("<c r=\""+address+"\" s=\""+style+"\" t=\"inlineStr\">");
            rich.getCTRst().save(_out,new org.apache.xmlbeans.XmlOptions()
                    .setSaveSyntheticDocumentElement(new javax.xml.namespace.QName(
                            "http://schemas.openxmlformats.org/spreadsheetml/2006/main","is"))
                    .setSaveNoXmlDecl());
            _out.write("</c>");
        }
    }

    public final class StreamingWorkbook implements AutoCloseable {
        private final SXSSFWorkbook workbook;
        private final ExportTemporaryBudget tempBudget;
        private final TableColumnProjection projection;
        private final String allowedScope;
        private final ExportRowSelection rowSelection;
        private final CellStyle header;
        private final CellStyle number;
        private final CellStyle quantity;
        private final CellStyle text;
        private final Map<String, CellStyle> units = new java.util.HashMap<>();
        private final Map<String, CellStyle> layoutStyles = new java.util.HashMap<>();
        private final Map<String, Font> layoutFonts = new java.util.HashMap<>();
        private final DataFormatter sourceValueFormatter = new DataFormatter(java.util.Locale.ROOT);
        private final Map<String,SheetState> sheets=new java.util.LinkedHashMap<>();
        private boolean finished;
        private boolean written;
        private boolean closed;
        private final class SheetState {
            final Sheet sheet;final List<ExportColumn> columns;final ExportTableLayout layout;int rowIndex=1,dataCount;
            final Map<Integer,List<ExportTableLayout.Band>> bands=new java.util.HashMap<>();
            final Map<Integer,List<ExportTableLayout.TextSpan>> spans=new java.util.HashMap<>();
            final Map<Integer,List<ExportTableLayout.SupplementalCell>> supplemental=new java.util.TreeMap<>();
            Sheet notes;int notesRow=1;
            SheetState(Sheet sheet,List<ExportColumn> columns,ExportTableLayout layout){
                this.sheet=sheet;this.columns=List.copyOf(columns);this.layout=layout;this.rowIndex=layout==null?1:layout.headerRow()+1;
                if(layout!=null){layout.bands().forEach(band->bands.computeIfAbsent(band.row(),key->new java.util.ArrayList<>()).add(band));layout.spans().forEach(span->spans.computeIfAbsent(span.row(),key->new java.util.ArrayList<>()).add(span));
                    layout.supplementalCells().forEach(cell->{if(cell.column()<columns.size())throw new IllegalArgumentException("Supplemental cell overlaps main report");supplemental.computeIfAbsent(layout.headerRow()+cell.rowOffset(),key->new java.util.ArrayList<>()).add(cell);});}
            }
        }

        private StreamingWorkbook(TableColumnProjection projection, String allowedScope, ExportTemporaryBudget tempBudget) {
            this.rowSelection = new ExportRowSelection(projection);
            this.tempBudget = tempBudget;
            workbook = new SXSSFWorkbook(ROW_ACCESS_WINDOW) {
                @Override protected org.apache.poi.xssf.streaming.SheetDataWriter createSheetDataWriter() throws IOException {
                    return tempBudget==null?new RichTextSheetDataWriter():privateSheetWriter(tempBudget);
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
            if (rowSelection.active()) {
                if (page.layout()!=null) throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"原件请使用完整输出；选中明细请在明细报表中输出");
                var selectedRows=rowSelection.select(page.columns(),page.rows());
                page=new ExportPayload(page.columns(),selectedRows,selectedRows.size(),null,page.documentMetadata());
            }
            ExportPayload selected = projection == null || page.layout()!=null ? page
                    : projections.getObject().project(page.columns(), page.rows(), projection, allowedScope);
            LegacyExportBudget.requireRows((long)rowCount()+selected.rows().size());
            SheetState state=section("data",selected.layout()==null?"data":selected.layout().sheetName(),selected.columns(),false,selected.layout());
            if(!Objects.equals(state.layout,selected.layout()))throw new IllegalStateException("Export layout changed while writing");
            append(state,selected.columns(),selected.rows());
        }

        private SheetState section(String id,String name,List<ExportColumn> columns,boolean document) {
            return section(id,name,columns,document,null);
        }
        private SheetState section(String id,String name,List<ExportColumn> columns,boolean document,ExportTableLayout layout) {
            if(finished||closed)throw new IllegalStateException("Workbook is already finished or closed");
            SheetState state=sheets.get(id);
            if(state==null) {
                String safeName=org.apache.poi.ss.util.WorkbookUtil.createSafeSheetName(name);
                if(workbook.getSheet(safeName)!=null) {
                    int suffix=sheets.size()+1;
                    do{safeName="表"+suffix++;}while(workbook.getSheet(safeName)!=null);
                }
                Sheet sheet=workbook.createSheet(safeName);
                if(layout!=null&&layout.widths().size()<columns.size())throw new IllegalStateException("Template column count changed");
                state=new SheetState(sheet,columns,layout);sheets.put(id,state);
                Row labels = sheet.createRow(layout==null?0:layout.headerRow());
                for (int i = 0; i < columns.size(); i++) {
                    ExportColumn column = columns.get(i);
                    Cell label = labels.createCell(i);
                    label.setCellValue(column.label());
                    label.setCellStyle(layout==null?header:layoutStyle(header,layout,false,null,HorizontalAlignment.CENTER,true));
                    int width = column.width() == null
                            ? document?Math.max(12,Math.min(42,column.label().length()*2+4)):Math.min(50, Math.max(10, column.label().length() + 4))
                            : Math.min(100, Math.max(document?8:6, (int) Math.round(column.width() / 7)));
                    sheet.setColumnWidth(i, layout==null?width*256:(int)Math.round(layout.widths().get(i)*256));
                }
                if(layout!=null)for(int col=columns.size();col<layout.widths().size();col++)sheet.setColumnWidth(col,(int)Math.round(layout.widths().get(col)*256));
                if(layout!=null)for(int col:layout.hiddenColumns())sheet.setColumnHidden(col,true);
                if(layout!=null)initializeLayout(state);
                sheet.createFreezePane(0, layout==null?1:layout.headerRow()+1);
                if(document) {
                    sheet.setRepeatingRows(new org.apache.poi.ss.util.CellRangeAddress(0,0,-1,-1));
                    sheet.getPrintSetup().setLandscape(true);sheet.setFitToPage(true);
                    sheet.getPrintSetup().setFitWidth((short)1);sheet.getPrintSetup().setFitHeight((short)0);
                }
            }
            return state;
        }

        private CellStyle layoutStyle(CellStyle original,ExportTableLayout layout,boolean bold,String fill,HorizontalAlignment alignment,boolean border) {
            String key=original.getDataFormatString()+"|"+layout.fontName()+"|"+layout.fontSize()+"|"+bold+"|"+fill+"|"+alignment+"|"+border;
            return layoutStyles.computeIfAbsent(key,ignored->{
                var style=workbook.createCellStyle();style.cloneStyleFrom(original);style.setAlignment(alignment);
                style.setVerticalAlignment(org.apache.poi.ss.usermodel.VerticalAlignment.CENTER);style.setWrapText(true);
                String fontKey=layout.fontName()+"|"+layout.fontSize()+"|"+bold;
                var font=layoutFonts.computeIfAbsent(fontKey,k->{var value=workbook.createFont();value.setFontName(layout.fontName());value.setFontHeightInPoints(layout.fontSize());value.setBold(bold);return value;});
                style.setFont(font);style.setFillPattern(FillPatternType.NO_FILL);
                if(fill!=null&&fill.matches("[0-9A-Fa-f]{6}")) {
                    ((org.apache.poi.xssf.usermodel.XSSFCellStyle)style).setFillForegroundColor(new org.apache.poi.xssf.usermodel.XSSFColor(java.util.HexFormat.of().parseHex(fill),new org.apache.poi.xssf.usermodel.DefaultIndexedColorMap()));
                    style.setFillPattern(FillPatternType.SOLID_FOREGROUND);
                }
                if(border){style.setBorderTop(org.apache.poi.ss.usermodel.BorderStyle.THIN);style.setBorderBottom(org.apache.poi.ss.usermodel.BorderStyle.THIN);style.setBorderLeft(org.apache.poi.ss.usermodel.BorderStyle.THIN);style.setBorderRight(org.apache.poi.ss.usermodel.BorderStyle.THIN);}
                return style;
            });
        }
        private void initializeLayout(SheetState state) {
            var layout=state.layout;var sheet=state.sheet;
            for(int rowNo=layout.headerStartRow();rowNo<=layout.headerRow();rowNo++) {
                Row row=sheet.getRow(rowNo);if(row==null){row=sheet.createRow(rowNo);}row.setHeightInPoints(layout.rowHeight());
                for(int col=0;col<state.columns.size();col++){Cell cell=row.getCell(col);if(cell==null){cell=row.createCell(col);}cell.setCellStyle(layoutStyle(header,layout,false,null,HorizontalAlignment.CENTER,true));}
            }
            for(var heading:layout.headings()) {
                Row row=sheet.getRow(heading.row());if(row==null)row=sheet.createRow(heading.row());
                row.setHeightInPoints(Math.max(layout.rowHeight(),heading.fontSize()+8));
                Cell cell=row.getCell(heading.column());if(cell==null){cell=row.createCell(heading.column());}cell.setCellValue(heading.text());
                var style=workbook.createCellStyle();style.cloneStyleFrom(heading.row()>=layout.headerStartRow()?layoutStyle(header,layout,heading.bold(),null,HorizontalAlignment.CENTER,true):text);
                var font=workbook.createFont();font.setFontName(layout.fontName());font.setFontHeightInPoints((short)heading.fontSize());font.setBold(heading.bold());style.setFont(font);
                style.setAlignment(switch(heading.alignment()){case "CENTER"->HorizontalAlignment.CENTER;case "RIGHT"->HorizontalAlignment.RIGHT;default->HorizontalAlignment.LEFT;});
                style.setVerticalAlignment(org.apache.poi.ss.usermodel.VerticalAlignment.CENTER);style.setWrapText(true);cell.setCellStyle(style);
            }
            for(var merge:layout.merges()) {
                var range=new org.apache.poi.ss.util.CellRangeAddress(merge.firstRow(),merge.lastRow(),merge.firstColumn(),merge.lastColumn());sheet.addMergedRegion(range);
                if(merge.firstRow()>=layout.headerStartRow()){
                    org.apache.poi.ss.util.RegionUtil.setBorderTop(org.apache.poi.ss.usermodel.BorderStyle.THIN,range,sheet);
                    org.apache.poi.ss.util.RegionUtil.setBorderBottom(org.apache.poi.ss.usermodel.BorderStyle.THIN,range,sheet);
                    org.apache.poi.ss.util.RegionUtil.setBorderLeft(org.apache.poi.ss.usermodel.BorderStyle.THIN,range,sheet);
                    org.apache.poi.ss.util.RegionUtil.setBorderRight(org.apache.poi.ss.usermodel.BorderStyle.THIN,range,sheet);
                }
                if(merge.lastRow()<=layout.headerRow())for(int rowNo=merge.firstRow();rowNo<=merge.lastRow();rowNo++)for(int column=merge.firstColumn();column<=merge.lastColumn();column++) {
                    if(rowNo==merge.firstRow()&&column==merge.firstColumn())continue;
                    Row row=sheet.getRow(rowNo);if(row!=null&&row.getCell(column)!=null)row.getCell(column).setBlank();
                }
            }
            layout.headingRowHeights().forEach((rowNo,height)->{Row row=sheet.getRow(rowNo);if(row==null){row=sheet.createRow(rowNo);}row.setHeightInPoints(height);});
            for(int rowNo=0;rowNo<=layout.headerRow();rowNo++)if(state.supplemental.containsKey(rowNo)){
                Row row=sheet.getRow(rowNo);if(row==null){row=sheet.createRow(rowNo);}appendSupplemental(state,row);
            }
            sheet.setRepeatingRows(new org.apache.poi.ss.util.CellRangeAddress(0,layout.headerRow(),-1,-1));
            sheet.getPrintSetup().setPaperSize(org.apache.poi.ss.usermodel.PrintSetup.A4_PAPERSIZE);
            sheet.getPrintSetup().setLandscape(layout.landscape());sheet.setFitToPage(true);
            sheet.getPrintSetup().setFitWidth((short)1);sheet.getPrintSetup().setFitHeight((short)0);
            sheet.setHorizontallyCenter(true);
            if(!layout.sourcePrint().isEmpty())applySourcePageSetup(state);
            else for(int rowNo=0;rowNo<=layout.headerRow();rowNo++){
                Row row=sheet.getRow(rowNo);if(row==null)continue;
                for(Cell cell:row){
                    int lastColumn=cell.getColumnIndex(),rowSpan=1;boolean anchor=true;
                    for(var merge:layout.merges())if(rowNo>=merge.firstRow()&&rowNo<=merge.lastRow()
                        &&cell.getColumnIndex()>=merge.firstColumn()&&cell.getColumnIndex()<=merge.lastColumn()){
                        anchor=rowNo==merge.firstRow()&&cell.getColumnIndex()==merge.firstColumn();
                        lastColumn=merge.lastColumn();rowSpan=merge.lastRow()-merge.firstRow()+1;break;
                    }
                    if(anchor)protectLayoutValue(state,cell,cell.getColumnIndex(),lastColumn,rowSpan);
                }
            }
        }

        private void applySourcePageSetup(SheetState state){
            var source=state.layout.sourcePrint();var sheet=state.sheet;
            if(!"2".equals(Objects.toString(source.get("version")))||!Boolean.FALSE.equals(source.get("fitToPage"))||sourceNumber(source.get("scalePercent"))!=100d||!"portrait".equals(source.get("orientation"))||!"A4".equals(source.get("effectivePaperSize")))throw new IllegalArgumentException("Unsupported source print setup");
            sheet.setFitToPage(false);sheet.getPrintSetup().setScale((short)100);sheet.getPrintSetup().setPaperSize(org.apache.poi.ss.usermodel.PrintSetup.A4_PAPERSIZE);sheet.getPrintSetup().setLandscape(false);sheet.getPrintSetup().setLeftToRight(false);
            sheet.setRepeatingRows(null);sheet.setRepeatingColumns(null);sheet.setHorizontallyCenter(false);sheet.setVerticallyCenter(false);
            var margins=sourceMap(source.get("marginsPoints"));sheet.setMargin(org.apache.poi.ss.usermodel.PageMargin.LEFT,sourceNumber(margins.get("left"))/72d);sheet.setMargin(org.apache.poi.ss.usermodel.PageMargin.RIGHT,sourceNumber(margins.get("right"))/72d);sheet.setMargin(org.apache.poi.ss.usermodel.PageMargin.TOP,sourceNumber(margins.get("top"))/72d);sheet.setMargin(org.apache.poi.ss.usermodel.PageMargin.BOTTOM,sourceNumber(margins.get("bottom"))/72d);sheet.getPrintSetup().setHeaderMargin(sourceNumber(margins.get("header"))/72d);sheet.getPrintSetup().setFooterMargin(sourceNumber(margins.get("footer"))/72d);
            var basis=sourceMap(source.get("widthBasis"));var normal=workbook.getFontAt(0);normal.setFontName(Objects.toString(basis.get("fontName")));normal.setFontHeightInPoints((short)sourceNumber(basis.get("fontSize")));if(normal instanceof org.apache.poi.xssf.usermodel.XSSFFont resolved)resolved.setScheme(org.apache.poi.ss.usermodel.FontScheme.NONE);
            // Without the built-in Normal named style Excel synthesises its
            // own theme font and reinterprets column units despite font0.
            var styleSheet=workbook.getXSSFWorkbook().getStylesSource().getCTStylesheet();
            if(!styleSheet.isSetCellStyles())try(var cursor=styleSheet.newCursor()){cursor.toEndToken();cursor.beginElement(new javax.xml.namespace.QName("http://schemas.openxmlformats.org/spreadsheetml/2006/main","cellStyles"));cursor.insertAttributeWithValue("count","1");cursor.beginElement(new javax.xml.namespace.QName("http://schemas.openxmlformats.org/spreadsheetml/2006/main","cellStyle"));cursor.insertAttributeWithValue("name","Normal");cursor.insertAttributeWithValue("builtinId","0");cursor.insertAttributeWithValue("xfId","0");}
            for(int row=0;row<=state.layout.headerRow();row++){Row record=sheet.getRow(row);if(record!=null)for(Cell cell:record)applySourceCellStyle(state,cell,row,cell.getColumnIndex(),false);}
        }
        @SuppressWarnings("unchecked")private static java.util.Map<String,Object> sourceMap(Object value){return value instanceof java.util.Map<?,?> map?(java.util.Map<String,Object>)map:java.util.Map.of();}
        private static double sourceNumber(Object value){try{double number=Double.parseDouble(Objects.toString(value));if(!Double.isFinite(number)||number<0||number>1200)throw new NumberFormatException();return number;}catch(NumberFormatException failure){throw new IllegalArgumentException("Invalid source print geometry",failure);}}
        private void applySourceCellStyle(SheetState state,Cell cell,int sourceRow,int column,boolean body){
            var source=state.layout.sourcePrint();if(source.isEmpty())return;java.util.Map<String,Object> details;
            if(body){Object styles=source.get("bodyStyles");details=styles instanceof java.util.List<?> list&&column<list.size()?sourceMap(list.get(column)):java.util.Map.of();}
            else{String address=new org.apache.poi.ss.util.CellReference(sourceRow,column).formatAsString();details=sourceMap(sourceMap(source.get("sourceStyles")).get(address));}
            if(details.isEmpty())return;var original=cell.getCellStyle();String key="source-text|"+original.getIndex()+"|"+details;
            cell.setCellStyle(layoutStyles.computeIfAbsent(key,ignored->{var style=workbook.createCellStyle();style.cloneStyleFrom(original);style.setWrapText(Boolean.TRUE.equals(details.get("wrapText")));style.setShrinkToFit(Boolean.TRUE.equals(details.get("shrinkToFit")));Object alignment=details.get("alignment");if(alignment instanceof String text&&java.util.Set.of("LEFT","CENTER","RIGHT").contains(text)){style.setAlignment(HorizontalAlignment.valueOf(text));}String fontKey="source|"+state.layout.fontName()+"|"+details.get("fontSize")+"|"+details.get("bold");var font=layoutFonts.computeIfAbsent(fontKey,unused->{var created=workbook.createFont();created.setFontName(state.layout.fontName());created.setFontHeightInPoints((short)sourceNumber(details.get("fontSize")));created.setBold(Boolean.TRUE.equals(details.get("bold")));return created;});style.setFont(font);return style;}));
        }
        /** Complete values may expand vertically without changing source widths,
         * fonts, input or precision. Frozen source paper uses its physical width
         * proof; generated layouts use the widths actually assigned to the sheet. */
        private void protectLayoutValue(SheetState state,Cell cell,int firstColumn,int lastColumn,int rowSpan){
            var source=state.layout.sourcePrint();if(cell.getCellStyle().getShrinkToFit())return;
            String value=sourceValueFormatter.formatCellValue(cell);if(value.isEmpty())return;
            double width=-4;
            if(source.isEmpty()){
                for(int column=firstColumn;column<=lastColumn;column++)if(!state.sheet.isColumnHidden(column))width+=state.sheet.getColumnWidthInPixels(column)*.75d;
            }else{
                Object raw=source.get("columnWidthsPoints");if(!(raw instanceof java.util.List<?> widths)||lastColumn>=widths.size())throw new IllegalArgumentException("Source column width proof unavailable");
                for(int column=firstColumn;column<=lastColumn;column++)if(!state.layout.hiddenColumns().contains(column))width+=sourceNumber(widths.get(column));
            }
            if(width<=0)return;
            double fontSize=workbook.getFontAt(cell.getCellStyle().getFontIndex()).getFontHeightInPoints();
            // Excel cannot wrap a numeric display token; a taller row still
            // shows ###. Generated layouts retain the original minimum width
            // and grow only the affected column, using the formatted value
            // (including %, sign, units and precision), never a changed value
            // or smaller font. Frozen physical source canvases stay unchanged.
            if(source.isEmpty()&&firstColumn==lastColumn&&cell.getCellType()==org.apache.poi.ss.usermodel.CellType.NUMERIC) {
                double longest=0,line=0;
                for(int offset=0;offset<value.length();){int cp=value.codePointAt(offset);offset+=Character.charCount(cp);if(cp=='\n'){longest=Math.max(longest,line);line=0;}else line+=layoutGlyphAdvance(cp,fontSize);}
                double requiredWidth=Math.max(longest,line)+4;
                if(requiredWidth>width+4) {
                    int requested=(int)Math.ceil(state.sheet.getColumnWidth(firstColumn)*requiredWidth/(width+4));
                    if(requested>255*256)throw new IllegalArgumentException("完整数字超过Excel最大列宽，不能截断或缩字");
                    state.sheet.setColumnWidth(firstColumn,requested);
                    width=state.sheet.getColumnWidthInPixels(firstColumn)*.75d-4;
                }
            }
            var original=cell.getCellStyle();String key="source-complete|"+original.getIndex();cell.setCellStyle(layoutStyles.computeIfAbsent(key,ignored->{var style=workbook.createCellStyle();style.cloneStyleFrom(original);style.setWrapText(true);return style;}));
            double used=0;int lines=1;
            for(int offset=0;offset<value.length();){int cp=value.codePointAt(offset);offset+=Character.charCount(cp);if(cp=='\n'){lines++;used=0;continue;}double advance=layoutGlyphAdvance(cp,fontSize);if(used>0&&used+advance>width){lines++;used=0;}used+=advance;}
            double required=lines==1?fontSize+2:lines*fontSize*1.35+4,existing=0;int anchor=cell.getRowIndex();for(int row=anchor;row<anchor+rowSpan;row++){Row record=state.sheet.getRow(row);existing+=record==null?state.layout.rowHeight():record.getHeightInPoints();}
            if(required>existing){Row last=state.sheet.getRow(anchor+rowSpan-1);double height=last.getHeightInPoints()+required-existing;if(height>409.5)throw new IllegalArgumentException("原表完整单格超过Excel行高，不能截断或缩字");last.setHeightInPoints((float)height);}
        }

        private double layoutGlyphAdvance(int codePoint,double fontSize){return fontSize*(codePoint<128?.65:1.0);}

        private void appendSupplemental(SheetState state,Row row){
            for(var item:state.supplemental.getOrDefault(row.getRowNum(),List.of())){
                Cell cell=row.createCell(item.column());
                writeCell(cell,item.type(),item.value(),number,quantity,text,units);
                var alignment=item.header()?HorizontalAlignment.CENTER:HorizontalAlignment.valueOf(ExportTableLayout.columnAlignment(item.type()));
                cell.setCellStyle(layoutStyle(cell.getCellStyle(),state.layout,item.header(),null,alignment,true));
            }
        }

        private void append(SheetState state,List<ExportColumn> columns,List<Map<String,Object>> rows) {
            if (!state.columns.equals(columns)) {
                throw new IllegalStateException("Export columns changed while writing");
            }
            for (Map<String, Object> values : rows) {
                if (Thread.currentThread().isInterrupted()) throw new java.util.concurrent.CancellationException();
                if (state.rowIndex >= 1_048_576) throw new IllegalStateException("Excel row limit exceeded");
                Row row = state.sheet.createRow(state.rowIndex++);
                if(state.layout!=null)row.setHeightInPoints(state.layout.rowHeight());
                for (int i = 0; i < columns.size(); i++) {
                    ExportColumn column = columns.get(i);
                    Cell cell = row.createCell(i);
                    writeCell(cell, column.type(), values == null ? null : values.get(column.key()), number, quantity, text,units);
                    if(state.layout==null)applyUnit(cell, column, values, workbook, units);
                    else {
                        var layout=state.layout;var alignment=HorizontalAlignment.valueOf(ExportTableLayout.columnAlignment(column.type()));
                        boolean bold=false;String fill=null;
                        for(var band:state.bands.getOrDefault(state.dataCount,List.of()))if(i>=band.firstColumn()&&i<=band.lastColumn()){bold=band.bold();fill=band.fill();}
                        CellStyle base=cell.getCellStyle();
                        if("%".equals(ExportCellValues.unit(column,values))||values!=null&&values.get("__percentageKeys") instanceof java.util.Collection<?> percentage&&percentage.contains(column.key())) {
                            var points=ExportCellValues.decimal(values==null?null:values.get(column.key()));
                            boolean exactText=points!=null&&points.stripTrailingZeros().precision()>15;
                            if(points!=null) {
                                if(exactText)cell.setCellValue(ExportCellValues.exactText(points)+"%");
                                else cell.setCellValue(points.movePointLeft(2).doubleValue());
                            }
                            int fraction=points==null?2:Math.max(2,Math.max(0,points.stripTrailingZeros().scale()));
                            String percentageKey="financial-percentage-points-"+exactText+":"+fraction;
                            base=units.computeIfAbsent(percentageKey,k->{var style=workbook.createCellStyle();style.cloneStyleFrom(number);style.setDataFormat(workbook.createDataFormat().getFormat(exactText?"@":"0."+"0".repeat(fraction)+"%"));return style;});
                        }
                        cell.setCellStyle(layoutStyle(base,layout,bold,fill,alignment,true));
                        if(values!=null&&Boolean.TRUE.equals(values.get("__showCurrencyInOriginal"))&&ExportColumn.MONEY.equals(column.type())&&"currencyCode".equals(column.unitKey()))applyUnit(cell,column,values,workbook,units);
                        applySourceCellStyle(state,cell,row.getRowNum(),i,true);
                        protectLayoutValue(state,cell,i,i,1);
                        if(cell.getCellType()==org.apache.poi.ss.usermodel.CellType.STRING) {
                            String value=cell.getStringCellValue();
                            org.apache.poi.xssf.usermodel.XSSFRichTextString rich=null;
                            for(var span:state.spans.getOrDefault(state.dataCount,List.of()))if(span.column()==i) {
                                if(span.end()>value.length())continue;
                                if(rich==null)rich=new org.apache.poi.xssf.usermodel.XSSFRichTextString(value);
                                int baseIndex=cell.getCellStyle().getFontIndex();
                                String key="span:"+baseIndex+":"+span.color().toUpperCase(java.util.Locale.ROOT);
                                Font font=layoutFonts.computeIfAbsent(key,ignored->{
                                    var colored=(org.apache.poi.xssf.usermodel.XSSFFont)workbook.createFont();
                                    colored.getCTFont().set(((org.apache.poi.xssf.usermodel.XSSFFont)workbook.getFontAt(baseIndex)).getCTFont());
                                    colored.setColor(new org.apache.poi.xssf.usermodel.XSSFColor(java.util.HexFormat.of().parseHex(span.color()),new org.apache.poi.xssf.usermodel.DefaultIndexedColorMap()));
                                    return colored;
                                });
                                rich.applyFont(span.start(),span.end(),font);
                            }
                            if(rich!=null)cell.setCellValue(rich);
                        }
                    }
                }
                if(state.layout!=null){appendSupplemental(state,row);appendSourceNote(state,values);}
                state.dataCount++;
            }
        }

        private void appendSourceNote(SheetState state,Map<String,Object> values) {
            if(values==null)return;
            String basis=Objects.toString(values.get("__basis"),Objects.toString(values.get("basis"),"")).strip();
            if(basis.isEmpty())return;
            if(state.notes==null) {
                String name="取数与核对";int suffix=2;while(workbook.getSheet(name)!=null)name="取数与核对"+suffix++;
                state.notes=workbook.createSheet(name);var row=state.notes.createRow(0);
                var labels=List.of("原表行序","项目/往来","取数与核对说明");
                for(int i=0;i<labels.size();i++){var cell=row.createCell(i);cell.setCellValue(labels.get(i));cell.setCellStyle(header);}
                state.notes.setColumnWidth(0,12*256);state.notes.setColumnWidth(1,36*256);state.notes.setColumnWidth(2,120*256);
                state.notes.createFreezePane(0,1);state.notes.setRepeatingRows(new org.apache.poi.ss.util.CellRangeAddress(0,0,-1,-1));
                state.notes.getPrintSetup().setLandscape(true);state.notes.setFitToPage(true);state.notes.getPrintSetup().setFitWidth((short)1);state.notes.getPrintSetup().setFitHeight((short)0);
            }
            if(state.notesRow>=1048576)throw new IllegalStateException("Excel notes row limit exceeded");
            var row=state.notes.createRow(state.notesRow++);row.setHeightInPoints(Math.min(240,Math.max(30,(float)Math.ceil(basis.length()/70.0)*15)));
            var ordinal=row.createCell(0);ordinal.setCellValue(state.dataCount+1);ordinal.setCellStyle(quantity);
            var item=row.createCell(1);item.setCellValue(Objects.toString(values.get(state.columns.getFirst().key()),""));item.setCellStyle(layoutStyle(text,state.layout,false,null,HorizontalAlignment.LEFT,false));
            var note=row.createCell(2);note.setCellValue(basis);note.setCellStyle(layoutStyle(text,state.layout,false,null,HorizontalAlignment.LEFT,false));
        }

        private void appendSourceFooter(SheetState state,Runnable checkpoint){
            var layout=state.layout;var footer=layout.footer();int start=layout.headerRow()+1+Math.max(state.dataCount,footer.minimumDataRows());
            int end=start+footer.cells().stream().mapToInt(cell->cell.rowOffset()+cell.rowSpan()).max().orElse(0)-1;
            if(end>=1048576)throw new IllegalStateException("Source footer exceeds Excel row limit");
            while(state.rowIndex<start){checkpoint.run();Row row=state.sheet.createRow(state.rowIndex++);row.setHeightInPoints(layout.rowHeight());for(int col=0;col<state.columns.size();col++){row.createCell(col).setCellStyle(layoutStyle(text,layout,false,null,HorizontalAlignment.LEFT,true));}appendSupplemental(state,row);}
            while(state.rowIndex<=end){Row row=state.sheet.createRow(state.rowIndex++);row.setHeightInPoints(layout.rowHeight());appendSupplemental(state,row);}
            for(var source:footer.cells()){
                checkpoint.run();int rowNo=start+source.rowOffset();Row row=state.sheet.getRow(rowNo);Cell cell=row.getCell(source.column());if(cell==null)cell=row.createCell(source.column());
                writeCell(cell,source.type(),source.value(),number,quantity,text,units);
                var original=cell.getCellStyle();String styleKey="source-footer|"+original.getDataFormatString()+"|"+layout.fontName()+"|"+source.fontSize()+"|"+source.bold()+"|"+source.alignment();
                cell.setCellStyle(layoutStyles.computeIfAbsent(styleKey,key->{var style=workbook.createCellStyle();style.cloneStyleFrom(original);style.setAlignment(HorizontalAlignment.valueOf(source.alignment()));style.setVerticalAlignment(org.apache.poi.ss.usermodel.VerticalAlignment.CENTER);style.setWrapText(true);var font=layoutFonts.computeIfAbsent(layout.fontName()+"|"+source.fontSize()+"|"+source.bold(),ignored->{var value=workbook.createFont();value.setFontName(layout.fontName());value.setFontHeightInPoints((short)source.fontSize());value.setBold(source.bold());return value;});style.setFont(font);return style;}));
                applySourceCellStyle(state,cell,layout.headerRow()+1+footer.minimumDataRows()+source.rowOffset(),source.column(),false);
                protectLayoutValue(state,cell,source.column(),source.lastColumn(),source.rowSpan());
                if(source.rowSpan()>1||source.lastColumn()>source.column())state.sheet.addMergedRegion(new org.apache.poi.ss.util.CellRangeAddress(rowNo,rowNo+source.rowSpan()-1,source.column(),source.lastColumn()));
            }
        }

        public int rowCount() { return Math.toIntExact(sheets.values().stream().mapToLong(state->state.dataCount).sum()); }

        public void finish(java.io.OutputStream output) throws IOException {
            finish(output,LegacyExportBudget::checkpoint);
        }
        private void finish(java.io.OutputStream output,Runnable checkpoint)throws IOException {
            rowSelection.verifyComplete();
            if (finished || closed || sheets.isEmpty()) throw new IllegalStateException("Workbook is not writable");
            for(var state:sheets.values())if(state.layout!=null) {
                if(state.layout.footer()!=null)appendSourceFooter(state,checkpoint);
                for(String note:state.layout.footnotes()) {
                    Row row=state.sheet.createRow(state.rowIndex++);row.setHeightInPoints(state.layout.rowHeight()*2);
                    Cell cell=row.createCell(0);cell.setCellValue(note);cell.setCellStyle(layoutStyle(text,state.layout,false,null,HorizontalAlignment.LEFT,false));
                    if(state.columns.size()>1)state.sheet.addMergedRegion(new org.apache.poi.ss.util.CellRangeAddress(row.getRowNum(),row.getRowNum(),0,state.columns.size()-1));
                    protectLayoutValue(state,cell,0,state.columns.size()-1,1);
                    appendSupplemental(state,row);
                }
                int lastSupplemental=state.supplemental.keySet().stream().mapToInt(Integer::intValue).max().orElse(-1);
                while(state.rowIndex<=lastSupplemental){Row row=state.sheet.createRow(state.rowIndex++);row.setHeightInPoints(state.layout.rowHeight());appendSupplemental(state,row);}
                workbook.setPrintArea(workbook.getSheetIndex(state.sheet),0,state.layout.widths().size()-1,0,state.rowIndex-1);
            }
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
            return writer.sheets.get(id).dataCount;
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
                if(section.omitIfEmpty()&&state.dataCount==0) {
                    ((org.apache.poi.xssf.streaming.SXSSFSheet)state.sheet).flushRows();
                    writer.workbook.removeSheetAt(writer.workbook.getSheetIndex(state.sheet));
                }
            }
            writer.finish(output,checkpoint);
        }
        @Override public void close()throws IOException{closed=true;writer.close();}
    }

    private static void writeCell(Cell cell, String type, Object v, CellStyle numStyle, CellStyle qtyStyle,
                                  CellStyle textStyle,Map<String,CellStyle> cache) {
        if (v == null) return;
        switch (type == null ? ExportColumn.TEXT : type) {
            case ExportColumn.EXACT_NUMBER -> {
                BigDecimal d = ExportCellValues.decimal(v);
                cell.setCellValue(d == null ? Objects.toString(v) : ExportCellValues.exactText(d));
                // String cells keep every digit; reuse numeric alignment without Excel General rounding.
                cell.setCellStyle(qtyStyle);
            }
            case ExportColumn.MONEY, ExportColumn.NUMBER, ExportColumn.QTY -> {
                BigDecimal d = ExportCellValues.decimal(v);
                if (d != null) {
                    double value=d.doubleValue();
                    if(d.stripTrailingZeros().precision()>15 || Math.abs(d.stripTrailingZeros().scale())>64 || !Double.isFinite(value)
                            || d.signum()!=0&&Math.abs(value)<Double.MIN_NORMAL) {
                        cell.setCellValue(ExportCellValues.exactText(d)); cell.setCellStyle(textStyle);
                    } else {
                        cell.setCellValue(value);
                        int scale=Math.max(ExportColumn.MONEY.equals(type)?2:0,Math.max(0,d.stripTrailingZeros().scale()));
                        String pattern=(ExportColumn.MONEY.equals(type)?"#,##0":"0")+(scale==0?"":"."+"0".repeat(scale));
                        String key="exact-number:"+pattern;
                        cell.setCellStyle(cache.computeIfAbsent(key,ignored->{var style=cell.getSheet().getWorkbook().createCellStyle();style.cloneStyleFrom(ExportColumn.MONEY.equals(type)?numStyle:qtyStyle);style.setDataFormat(cell.getSheet().getWorkbook().createDataFormat().getFormat(pattern));return style;}));
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
        String base = cell.getCellType() == org.apache.poi.ss.usermodel.CellType.STRING ? "@" : cell.getCellStyle().getDataFormatString();
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
