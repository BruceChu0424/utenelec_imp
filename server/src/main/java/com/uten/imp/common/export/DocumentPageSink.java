package com.uten.imp.common.export;

import java.util.*;

/** Synchronous, scoped multi-section export. Source quantities stay in their own section. */
public final class DocumentPageSink implements AutoCloseable {
    public record Section(String id, String name, List<ExportColumn> columns,
                          boolean primary, boolean omitIfEmpty) {
        public Section {
            Objects.requireNonNull(id);Objects.requireNonNull(name);
            if (id.isBlank() || name.isBlank()) throw new IllegalArgumentException("Document section identity is required");
            columns=List.copyOf(columns);
            if(columns.isEmpty()||columns.size()>160) throw new IllegalArgumentException("Document columns must be bounded");
        }
    }
    public record Header(String title, List<String> metadata, List<Section> sections,long expectedPrimaryRows) {
        public Header(String title,List<String> metadata,List<Section> sections){this(title,metadata,sections,-1);}
        public Header {
            Objects.requireNonNull(title);metadata=List.copyOf(metadata);sections=List.copyOf(sections);
            if(sections.isEmpty()||sections.size()>16) throw new IllegalArgumentException("Document sections must be bounded");
            if(sections.stream().filter(Section::primary).count()!=1) throw new IllegalArgumentException("One primary document section is required");
            if(sections.stream().map(Section::id).distinct().count()!=sections.size()) throw new IllegalArgumentException("Duplicate document section identity");
            if(expectedPrimaryRows < -1)throw new IllegalArgumentException("Invalid primary row count");
        }
    }
    public record Page(String sectionId,List<Map<String,Object>> rows) {
        public Page {
            Objects.requireNonNull(sectionId);
            if(rows.size()>200) throw new IllegalArgumentException("Document pages cannot exceed 200 rows");
            rows=rows.stream().map(row->Collections.unmodifiableMap(new LinkedHashMap<>(row))).toList();
        }
    }
    public interface Consumer {
        void begin(Header header);
        void accept(Page page);
    }
    /** One file contract for immutable documents and both streaming writers. */
    public static final class RowBudget {
        private final Map<String,Long> counts=new HashMap<>();
        private boolean begun;
        public void begin(Header header) {
            if(begun)throw new IllegalStateException("Document row budget already started");
            if(header.expectedPrimaryRows()>ExportDocument.MAX_SECTION_ROWS)throw tooMany();
            header.sections().forEach(section->counts.put(section.id(),0L));begun=true;
        }
        public void accept(Page page) {
            Long previous=counts.get(page.sectionId());
            if(!begun||previous==null)throw new IllegalStateException("Document section is unknown");
            long next=previous+page.rows().size();
            if(next>ExportDocument.MAX_SECTION_ROWS)throw tooMany();
            counts.put(page.sectionId(),next);
        }
        private static com.uten.imp.common.web.ApiException tooMany() {
            return new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"单次导出每个分表最多 50000 行，请缩小范围");
        }
    }

    private static final ThreadLocal<Consumer> CURRENT=new ThreadLocal<>();
    private final Consumer previous;
    private final Thread owner=Thread.currentThread();
    private boolean closed;
    private DocumentPageSink(Consumer sink) {previous=CURRENT.get();CURRENT.set(Objects.requireNonNull(sink));}
    public static DocumentPageSink open(Consumer sink) {return new DocumentPageSink(sink);}
    public static Consumer current() {return CURRENT.get();}
    /** Bounded compatibility adapter: both document formats use this same section order. */
    public static void emitDocument(ExportDocument document,Consumer sink) {
        List<Section> sections=new ArrayList<>();
        for(int index=0;index<document.sections().size();index++) {
            var section=document.sections().get(index);
            sections.add(new Section("section-"+index,section.name(),section.columns(),index==0,false));
        }
        sink.begin(new Header(document.title(),document.metadata(),sections,document.sections().getFirst().rows().size()));
        for(int index=0;index<document.sections().size();index++) {
            var rows=document.sections().get(index).rows();
            for(int start=0;start<rows.size();start+=200)
                sink.accept(new Page("section-"+index,rows.subList(start,Math.min(rows.size(),start+200))));
        }
    }
    @Override public void close() {
        if(Thread.currentThread()!=owner) throw new IllegalStateException("Document sink belongs to another thread");
        if(closed)return;closed=true;
        if(previous==null)CURRENT.remove();else CURRENT.set(previous);
    }
}
