package com.uten.imp.common.export;

import org.junit.jupiter.api.Test;
import java.util.*;
import java.util.concurrent.atomic.AtomicReference;
import static org.junit.jupiter.api.Assertions.*;

class DocumentPageSinkTest {
    private static DocumentPageSink.Consumer sink(){return new DocumentPageSink.Consumer(){public void begin(DocumentPageSink.Header header){}public void accept(DocumentPageSink.Page page){}};}
    @Test void nestedScopesRestoreAndWrongThreadCannotRetireAnActiveSink()throws Exception {
        var first=sink();var second=sink();assertNull(DocumentPageSink.current());
        try(var outer=DocumentPageSink.open(first)) {
            try(var inner=DocumentPageSink.open(second)){assertSame(second,DocumentPageSink.current());}
            assertSame(first,DocumentPageSink.current());
            var failure=new AtomicReference<Throwable>();Thread thread=new Thread(()->{try{outer.close();}catch(Throwable error){failure.set(error);}});
            thread.start();thread.join();assertInstanceOf(IllegalStateException.class,failure.get());assertSame(first,DocumentPageSink.current());
        }
        assertNull(DocumentPageSink.current());
    }
    @Test void pagesAreBoundedImmutableAndNullCellsArePreserved() {
        var values=new LinkedHashMap<String,Object>();values.put("nullable",null);values.put("qty","1.00000001");
        var page=new DocumentPageSink.Page("main",List.of(values));values.put("qty","wrong");
        assertEquals("1.00000001",page.rows().getFirst().get("qty"));assertTrue(page.rows().getFirst().containsKey("nullable"));
        assertThrows(UnsupportedOperationException.class,()->page.rows().getFirst().put("x",1));
        assertThrows(IllegalArgumentException.class,()->new DocumentPageSink.Page("main",Collections.nCopies(201,Map.of())));
        var columns=List.of(new ExportColumn("q","数量",ExportColumn.QTY));
        assertThrows(IllegalArgumentException.class,()->new DocumentPageSink.Header("t",List.of(),List.of(
                new DocumentPageSink.Section("same","a",columns,true,false),new DocumentPageSink.Section("same","b",columns,false,false))));
    }
    @Test void rowBudgetPreservesTheOriginalPerSectionBoundAndDoesNotSumSources() {
        var columns=List.of(new ExportColumn("q","数量",ExportColumn.QTY));
        var header=new DocumentPageSink.Header("t",List.of(),List.of(
                new DocumentPageSink.Section("a","当前",columns,true,false),new DocumentPageSink.Section("b","历史",columns,false,false)));
        var budget=new DocumentPageSink.RowBudget();budget.begin(header);
        var rows=Collections.nCopies(200,Map.<String,Object>of("q",1));
        for(int index=0;index<ExportDocument.MAX_SECTION_ROWS/200;index++) {
            budget.accept(new DocumentPageSink.Page("a",rows));budget.accept(new DocumentPageSink.Page("b",rows));
        }
        assertThrows(com.uten.imp.common.web.ApiException.class,()->budget.accept(new DocumentPageSink.Page("a",List.of(Map.of("q",1)))));
        var known=new DocumentPageSink.RowBudget();
        assertThrows(com.uten.imp.common.web.ApiException.class,()->known.begin(new DocumentPageSink.Header("t",List.of(),header.sections(),ExportDocument.MAX_SECTION_ROWS+1L)));
    }
}
