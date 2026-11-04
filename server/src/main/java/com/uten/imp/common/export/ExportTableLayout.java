package com.uten.imp.common.export;

import java.util.List;
import java.util.Objects;

/** Bounded presentation facts only. Values and calculations still belong to the report source. */
public record ExportTableLayout(String sheetName,int headerRow,int headerStartRow,List<Heading> headings,List<Merge> merges,
                                List<Double> widths,String fontName,short fontSize,float rowHeight,
                                List<Band> bands,List<TextSpan> spans,List<String> footnotes,boolean landscape,
                                List<SupplementalCell> supplementalCells,List<Integer> hiddenColumns,FooterBlock footer,java.util.Map<Integer,Float> headingRowHeights,
                                java.util.Map<String,Object> sourcePrint) {
    public ExportTableLayout(String sheetName,int headerRow,int headerStartRow,List<Heading> headings,List<Merge> merges,List<Double> widths,String fontName,short fontSize,float rowHeight,List<Band> bands,List<TextSpan> spans,List<String> footnotes,boolean landscape,List<SupplementalCell> supplementalCells,List<Integer> hiddenColumns,FooterBlock footer,java.util.Map<Integer,Float> headingRowHeights){
        this(sheetName,headerRow,headerStartRow,headings,merges,widths,fontName,fontSize,rowHeight,bands,spans,footnotes,landscape,supplementalCells,hiddenColumns,footer,headingRowHeights,java.util.Map.of());
    }
    public ExportTableLayout(String sheetName,int headerRow,int headerStartRow,List<Heading> headings,List<Merge> merges,List<Double> widths,String fontName,short fontSize,float rowHeight,List<Band> bands,List<TextSpan> spans,List<String> footnotes,boolean landscape,List<SupplementalCell> supplementalCells,List<Integer> hiddenColumns){
        this(sheetName,headerRow,headerStartRow,headings,merges,widths,fontName,fontSize,rowHeight,bands,spans,footnotes,landscape,supplementalCells,hiddenColumns,null,java.util.Map.of());
    }
    public ExportTableLayout(String sheetName,int headerRow,int headerStartRow,List<Heading> headings,List<Merge> merges,
            List<Double> widths,String fontName,short fontSize,float rowHeight,List<Band> bands,List<TextSpan> spans,
            List<String> footnotes,boolean landscape){
        this(sheetName,headerRow,headerStartRow,headings,merges,widths,fontName,fontSize,rowHeight,bands,spans,footnotes,landscape,List.of(),List.of());
    }
    public ExportTableLayout(String sheetName,int headerRow,int headerStartRow,List<Heading> headings,List<Merge> merges,
            List<Double> widths,String fontName,short fontSize,float rowHeight,List<Band> bands,List<TextSpan> spans,
            List<String> footnotes,boolean landscape,List<SupplementalCell> supplementalCells){
        this(sheetName,headerRow,headerStartRow,headings,merges,widths,fontName,fontSize,rowHeight,bands,spans,footnotes,landscape,supplementalCells,List.of());
    }
    public ExportTableLayout {
        Objects.requireNonNull(sheetName);Objects.requireNonNull(fontName);
        headings=List.copyOf(headings);merges=List.copyOf(merges);widths=List.copyOf(widths);
        bands=List.copyOf(bands);spans=List.copyOf(spans);footnotes=List.copyOf(footnotes);
        supplementalCells=supplementalCells==null?List.of():List.copyOf(supplementalCells);
        hiddenColumns=hiddenColumns==null?List.of():List.copyOf(hiddenColumns);
        headingRowHeights=headingRowHeights==null?java.util.Map.of():java.util.Map.copyOf(headingRowHeights);
        sourcePrint=sourcePrint==null?java.util.Map.of():java.util.Map.copyOf(sourcePrint);
        for(var entry:headingRowHeights.entrySet())if(entry.getKey()<0||entry.getKey()>headerRow||entry.getValue()==null||!Float.isFinite(entry.getValue())||entry.getValue()<10||entry.getValue()>160)throw new IllegalArgumentException("Invalid source heading row height");
        if(footer!=null)for(var cell:footer.cells())if(cell.lastColumn()>=widths.size())throw new IllegalArgumentException("Footer outside source canvas");
        if(headerRow<0||headerRow>12||headerStartRow<0||headerStartRow>headerRow||widths.isEmpty()||widths.size()>160||fontSize<8||fontSize>24||rowHeight<10||rowHeight>80
                ||headings.size()>100||merges.size()>160||bands.size()>10000||spans.size()>10000||footnotes.size()>100||supplementalCells.size()>1000)
            throw new IllegalArgumentException("Invalid bounded report layout");
        for(double width:widths)if(!Double.isFinite(width)||width<1||width>120)throw new IllegalArgumentException("Invalid report width");
        for(var heading:headings)if(heading.column()>=widths.size())throw new IllegalArgumentException("Heading outside template");
        for(var merge:merges)if(merge.lastColumn()>=widths.size())throw new IllegalArgumentException("Merge outside template");
        for(var band:bands)if(band.lastColumn()>=widths.size())throw new IllegalArgumentException("Band outside template");
        for(var span:spans)if(span.column()>=widths.size())throw new IllegalArgumentException("Text span outside template");
        var cellAddresses=new java.util.HashSet<String>();
        for(var cell:supplementalCells){
            if(cell.column()>=widths.size()||headerRow+cell.rowOffset()<0||!cellAddresses.add(cell.rowOffset()+":"+cell.column()))
                throw new IllegalArgumentException("Supplemental cell outside template or repeated");
        }
        for(String note:footnotes)if(note==null||note.length()>4096)throw new IllegalArgumentException("Footnote too long");
        if(hiddenColumns.size()>widths.size()||new java.util.HashSet<>(hiddenColumns).size()!=hiddenColumns.size())throw new IllegalArgumentException("Invalid source hidden columns");
        for(int column:hiddenColumns)if(column<0||column>=widths.size())throw new IllegalArgumentException("Invalid source hidden column");
    }
    /** Relative to the first row after max(real data rows, minimum template rows).
     * These are presentation values from the report, never another calculation. */
    public record FooterBlock(int minimumDataRows,List<FooterCell> cells){
        public FooterBlock{cells=List.copyOf(cells);if(minimumDataRows<0||minimumDataRows>20000||cells.size()>120)throw new IllegalArgumentException("Invalid source footer block");
            var occupied=new java.util.HashSet<String>();for(var cell:cells)for(int row=cell.rowOffset();row<cell.rowOffset()+cell.rowSpan();row++)for(int col=cell.column();col<=cell.lastColumn();col++)if(!occupied.add(row+":"+col))throw new IllegalArgumentException("Overlapping source footer cells");}
    }
    public record FooterCell(int rowOffset,int column,int lastColumn,int rowSpan,String type,Object value,float fontSize,boolean bold,String alignment,boolean pending,String basis){
        public FooterCell{Objects.requireNonNull(type);Objects.requireNonNull(alignment);if(rowOffset<0||rowOffset>64||rowSpan<1||rowSpan>8||column<0||lastColumn<column||lastColumn>=160||fontSize<8||fontSize>32||!java.util.Set.of("text","money","qty","number","date").contains(type)||!java.util.Set.of("LEFT","CENTER","RIGHT").contains(alignment)||value!=null&&!(value instanceof String)&&!(value instanceof Number)||value instanceof String text&&text.length()>32767||basis!=null&&basis.length()>4096)throw new IllegalArgumentException("Invalid source footer cell");}
    }
    /** Row offset is relative to the original main table header, not an export page. */
    public record SupplementalCell(int rowOffset,int column,String type,Object value,boolean header) {
        public SupplementalCell {
            if(rowOffset< -12||rowOffset>1024||column<0||column>=160||type==null||!java.util.Set.of("text","money","qty","number","date").contains(type)
                ||value!=null&&!(value instanceof String)&&!(value instanceof Number)||value instanceof String text&&text.length()>32767)
                throw new IllegalArgumentException("Invalid supplemental source cell");
        }
    }
    public record Heading(int row,int column,String text,float fontSize,boolean bold,String alignment) {
        public Heading {Objects.requireNonNull(text);Objects.requireNonNull(alignment);if(row<0||row>12||column<0||column>159||fontSize<8||fontSize>32||text.length()>1000)throw new IllegalArgumentException("Invalid heading");}
    }
    public record Merge(int firstRow,int lastRow,int firstColumn,int lastColumn) {
        public Merge {if(firstRow<0||lastRow<firstRow||lastRow>=1048576||firstColumn<0||lastColumn<firstColumn||lastColumn>=160||firstRow==lastRow&&firstColumn==lastColumn)throw new IllegalArgumentException("Invalid merge");}
    }
    /** Row is relative to the first data row, so pagination cannot change the template bands. */
    public record Band(int row,int firstColumn,int lastColumn,String fill,boolean bold) {
        public Band {if(row<0||row>=1048576||firstColumn<0||lastColumn<firstColumn||lastColumn>=160||fill!=null&&!fill.matches("[0-9A-Fa-f]{6}"))throw new IllegalArgumentException("Invalid band");}
    }
    public record TextSpan(int row,int column,int start,int end,String color) {
        public TextSpan {if(row<0||row>=1048576||column<0||column>=160||start<0||end<=start||color==null||!color.matches("[0-9A-Fa-f]{6}"))throw new IllegalArgumentException("Invalid text span");}
    }
}
