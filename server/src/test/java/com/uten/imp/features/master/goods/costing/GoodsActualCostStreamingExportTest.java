package com.uten.imp.features.master.goods.costing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.GoodsActualCostQueryPort;
import com.uten.imp.application.port.GoodsActualCostQueryPort.*;
import com.uten.imp.common.export.*;
import com.uten.imp.common.web.*;
import org.junit.jupiter.api.*;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.*;
import java.util.concurrent.CancellationException;
import java.util.function.Consumer;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsActualCostStreamingExportTest {
    private final ObjectMapper json=new ObjectMapper().findAndRegisterModules();
    private final GoodsActualCostQueryPort actual=mock(GoodsActualCostQueryPort.class);
    private final GoodsCostSheetService sheets=mock(GoodsCostSheetService.class);
    private final GoodsActualCostSnapshotService service=new GoodsActualCostSnapshotService(actual,sheets,new GoodsCostJson(json),json);
    @BeforeEach void actor(){SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("synthetic",null,
            List.of(new SimpleGrantedAuthority("goods:cost:view"),new SimpleGrantedAuthority("goods:cost:export"))));}
    @AfterEach void clear(){SecurityContextHolder.clearContext();}
    private ActualCostSnapshot fixture() throws Exception {
        return json.readValue("""
            {"goodsId":"00000000-0000-4000-8000-000000000001","capturedAt":"2026-10-26T00:00:00Z",
             "currencyBasis":"LOCAL","periodBasis":"PHYSICAL_OUTPUT_BUSINESS_DATE","inputScope":"FULL_ORIGINAL_COST_OBJECT",
             "filter":{"goodsId":"00000000-0000-4000-8000-000000000001"},
             "summary":{"knownInputCostLocal":"123456789.000000000000000123","outputQtyBase":"2.500000000000001","pending":true,"coverageCode":"INVENTORY_PRODUCTION_COST_ONLY"},
             "costObjects":[{"costObjectId":"00000000-0000-4000-8000-000000000002","revisionId":"00000000-0000-4000-8000-000000000003","state":"PROVISIONAL","historicalRevision":true,"pendingReasons":["INPUT_COST_PENDING"]}],
             "inputs":[{"goodsId":"00000000-0000-4000-8000-000000000004","goodsCode":"0001","goodsName":"原始名龘","unitName":"PCS","grossQtyBase":"0.000000000000000123","returnedQtyBase":"0","knownAmountLocal":null,"laterCostRevision":true}],
             "outputs":[{"businessDate":"2026-10-25","originalQtyBase":"2.500000000000001","effectiveQtyBase":"0","knownAmountLocal":"0","withdrawn":true,"laterCostRevision":true}],
             "revisions":[{"revisionId":"00000000-0000-4000-8000-000000000003","version":1},{"revisionId":"00000000-0000-4000-8000-000000000005","version":2}],
             "gaps":[{"code":"原始未归集","component":"MATERIAL"}]}
            """,ActualCostSnapshot.class);
    }
    private static final class Read implements StreamingRead {
        final ActualCostSnapshot snapshot;boolean closed,fail;
        Read(ActualCostSnapshot snapshot){this.snapshot=snapshot;}
        @Override public StreamingHeader header(){
            var selected=snapshot.costObjects().stream().map(CostObject::revisionId).collect(java.util.stream.Collectors.toSet());
            return new StreamingHeader(snapshot.goodsId(),snapshot.capturedAt().plusDays(1),snapshot.currencyBasis(),snapshot.periodBasis(),snapshot.inputScope(),
                    snapshot.filter(),snapshot.summary(),snapshot.costObjects(),snapshot.revisions().stream().filter(r->selected.contains(r.revisionId())).toList(),
                    snapshot.inputs().size(),snapshot.outputs().size(),snapshot.gaps().size());
        }
        @Override public void inputs(Consumer<InputLine> sink){if(fail)throw new CancellationException();snapshot.inputs().forEach(sink);}
        @Override public void outputs(Consumer<OutputLine> sink){snapshot.outputs().forEach(sink);}
        @Override public void gaps(Consumer<Gap> sink){snapshot.gaps().forEach(sink);}
        @Override public void close(){closed=true;}
    }
    private Read prepare(ActualCostSnapshot snapshot){
        var read=new Read(snapshot);when(actual.snapshot(any())).thenReturn(snapshot);
        when(actual.openStream(any(),anyInt(),any())).thenAnswer(call->{
            @SuppressWarnings("unchecked") Consumer<List<InputLine>> inspect=call.getArgument(2);inspect.accept(snapshot.inputs());return read;
        });return read;
    }
    @Test void everySectionAndCanonicalDigestMatchTheExistingSnapshotProjectionExactly() throws Exception {
        var snapshot=fixture();var read=prepare(snapshot);String digest=service.read(snapshot.filter()).digest();
        var expected=GoodsActualCostDocumentMapper.map(snapshot,digest);
        var rows=new LinkedHashMap<String,List<Map<String,Object>>>();
        var header=new java.util.concurrent.atomic.AtomicReference<DocumentPageSink.Header>();
        try(var scope=DocumentPageSink.open(new DocumentPageSink.Consumer(){
            @Override public void begin(DocumentPageSink.Header value){header.set(value);}
            @Override public void accept(DocumentPageSink.Page page){assertThat(page.rows().size()).isLessThanOrEqualTo(100);rows.computeIfAbsent(page.sectionId(),id->new ArrayList<>()).addAll(page.rows());}
        })) {service.streamExport(snapshot.filter(),digest,ExportDocument.MAX_SECTION_ROWS);}
        assertThat(read.closed).isTrue();assertThat(header.get().expectedPrimaryRows()).isEqualTo(1);
        for(int index=0;index<expected.sections().size();index++){
            assertThat(header.get().sections().get(index).columns()).isEqualTo(expected.sections().get(index).columns());
            assertThat(rows.get("actual-"+index)).isEqualTo(expected.sections().get(index).rows());
        }
        assertThat(header.get().metadata()).contains("内容摘要: "+digest);
    }
    @Test void changedDigestOrCancellationNeverBeginsAPartialDocument() throws Exception {
        var snapshot=fixture();var read=prepare(snapshot);var sink=mock(DocumentPageSink.Consumer.class);
        try(var scope=DocumentPageSink.open(sink)){
            assertThatThrownBy(()->service.streamExport(snapshot.filter(),"a".repeat(64),ExportDocument.MAX_SECTION_ROWS))
                    .isInstanceOfSatisfying(ApiException.class,error->assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT));
        }
        verifyNoInteractions(sink);assertThat(read.closed).isTrue();
        read.closed=false;read.fail=true;
        try(var scope=DocumentPageSink.open(sink)){
            assertThatThrownBy(()->service.streamExport(snapshot.filter(),"a".repeat(64),ExportDocument.MAX_SECTION_ROWS)).isInstanceOf(CancellationException.class);
        }
        verifyNoInteractions(sink);assertThat(read.closed).isTrue();
    }
    @Test void anUnseenInputCannotLeakEvenTheAggregateHeader() throws Exception {
        var snapshot=fixture();prepare(snapshot);var sink=mock(DocumentPageSink.Consumer.class);
        doThrow(new ApiException(ErrorCode.FORBIDDEN)).when(sheets).requireGoodsScopeBatch(any());
        try(var scope=DocumentPageSink.open(sink)){
            assertThatThrownBy(()->service.streamExport(snapshot.filter(),"a".repeat(64),ExportDocument.MAX_SECTION_ROWS)).isInstanceOf(ApiException.class);
        }
        verifyNoInteractions(sink);
    }
    @Test void writerCanonicalHashUsesTheExactSameBytesWithoutAWholeString() {
        var canonical=new GoodsCostJson(json);
        var values=new LinkedHashMap<String,Object>();values.put("z","龘\n\"\\");values.put("a",new java.math.BigDecimal("1.000000000000000001"));
        values.put("nested",List.of(Map.of("b","0001","a",true)));
        assertThat(canonical.hashStreaming(values)).isEqualTo(canonical.hash(values));
    }
}
