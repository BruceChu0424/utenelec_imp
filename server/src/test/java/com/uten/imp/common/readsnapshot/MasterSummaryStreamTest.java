package com.uten.imp.common.readsnapshot;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.*;
import jakarta.persistence.EntityManager;
import jakarta.servlet.ServletOutputStream;
import jakarta.servlet.WriteListener;
import org.junit.jupiter.api.*;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.io.IOException;
import java.sql.Connection;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.BiFunction;
import java.util.stream.IntStream;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@SuppressWarnings({"rawtypes","unchecked"})
class MasterSummaryStreamTest {
    record Row(int id) { }
    private final ObjectMapper json = new ObjectMapper();
    private final EntityManager em = mock(EntityManager.class);
    private final VersionedSummaryPages pages = mock(VersionedSummaryPages.class);
    private final MasterSummaryReadSupport summaries = new MasterSummaryReadSupport(pages,json,em);
    private final VersionedSummaryPages.ReadProof proof = new VersionedSummaryPages.ReadProof("a".repeat(64),"b".repeat(64),"c".repeat(64));
    private final AtomicInteger loads = new AtomicInteger();
    private final MasterSummaryReadSupport.Query<Map<String,Object>> query =
            new MasterSummaryReadSupport.Query<>(Map.of("code","original"),1,100,"code","asc");

    @BeforeEach void prepare() {
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("reader","unused",
                List.of(new SimpleGrantedAuthority("goods:view"))));
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(Connection.TRANSACTION_REPEATABLE_READ);
        when(pages.readWithProof(any(),any(),any())).thenAnswer(call -> {
            call.getArgument(1,Runnable.class).run();
            return proof.snapshot(call.getArgument(2,BiFunction.class).apply(proof,(Runnable)()->{}));
        });
    }
    @AfterEach void clear() {
        SecurityContextHolder.clearContext();
        TransactionSynchronizationManager.clear();
        assertThat(BoundedMasterReadSource.active()).isFalse();
    }
    private PageResponse<Row> page(int page,int size,int total) {
        loads.incrementAndGet();
        return new PageResponse<>(IntStream.range((page-1)*size,Math.min(page*size,total)).mapToObj(Row::new).toList(),
                page,size,total,(total+size-1)/size);
    }
    private List<com.fasterxml.jackson.databind.JsonNode> frames(MockHttpServletResponse response) throws Exception {
        var frames = new ArrayList<com.fasterxml.jackson.databind.JsonNode>();
        for (String line:response.getContentAsString().lines().toList()) frames.add(json.readTree(line));
        return frames;
    }

    @Test void tenThousandRowsStayInHundredRowFramesWithOneProofAndOnePublicationFence() throws Exception {
        var response = new MockHttpServletResponse();
        summaries.stream("goods-master-list","master_goods","goods:view",query,null,
                (filter,page,size,sort,order)->{
                    assertThat(filter).isSameAs(query.filter());assertThat(size).isEqualTo(100);
                    assertThat(sort).isEqualTo("code");assertThat(order).isEqualTo("asc");return page(page,size,10001);
                },response);
        var frames = frames(response);
        assertThat(loads).hasValue(101);
        assertThat(frames).hasSize(102);
        assertThat(frames.getFirst().get("value").get("items")).hasSize(100);
        assertThat(frames.get(100).get("value").get("items")).hasSize(1);
        for (var frame:frames.subList(0,101)) {
            assertThat(frame.get("type").asText()).isEqualTo("page");
            assertThat(frame.get("value").get("readSnapshotRevision").asText()).isEqualTo(proof.readSnapshotRevision());
        }
        assertThat(frames.getLast().get("type").asText()).isEqualTo("complete");
        assertThat(frames.getLast().get("total").asLong()).isEqualTo(10001);
        verify(pages,times(1)).readWithProof(any(),any(),any());
        verify(em,times(102)).clear();
    }

    @Test void streamInvariantFactsResolveOncePerCursorAndLookupsOnlyQueryUnseenKeys() throws Exception {
        var invariant = new AtomicInteger();
        var lookedUp = new ArrayList<List<Integer>>();
        var response = new MockHttpServletResponse();
        summaries.stream("goods-master-list","master_goods","goods:view",query,null,
                (filter,page,size,sort,order)->{
                    // Scope/subtree/keyword-plan style facts: same value for every batch.
                    String fact = BoundedMasterReadSource.memo(List.of("fact",filter),
                            () -> "resolved-" + invariant.incrementAndGet());
                    assertThat(fact).isEqualTo("resolved-1");
                    // Label maps: batch keys overlap (key 0 every batch, key=page new), misses remembered.
                    var labels = BoundedMasterReadSource.<Integer,String>lookup("labels",
                            Arrays.asList(0, page, null, -1), keys -> {
                                lookedUp.add(List.copyOf(keys));
                                Map<Integer,String> found = new HashMap<>();
                                for (Integer key:keys) if (key >= 0) found.put(key,"label-"+key);
                                return found;
                            });
                    assertThat(labels).containsEntry(0,"label-0").containsEntry(page,"label-"+page).doesNotContainKey(-1);
                    return page(page,size,350);
                },response);
        assertThat(frames(response).getLast().get("type").asText()).isEqualTo("complete");
        assertThat(invariant).hasValue(1);
        // First batch asks 0,1,-1; later batches only their new page key; -1 (a miss) is never re-queried.
        assertThat(lookedUp).containsExactly(List.of(0,1,-1),List.of(2),List.of(3),List.of(4));
        // Outside a cursor nothing is cached.
        assertThat(BoundedMasterReadSource.memo("fact",() -> "a")).isEqualTo("a");
        assertThat(BoundedMasterReadSource.<Integer,String>lookup("labels",List.of(7),keys -> Map.of(7,"x"))).containsEntry(7,"x");
        assertThat(BoundedMasterReadSource.<Integer,String>lookup("labels",List.of(7),keys -> Map.of())).isEmpty();
    }

    @Test void finalCommittedDriftRetiresEveryProvisionalFrameAndNeverPublishesCompletion() throws Exception {
        doAnswer(call->{
            call.getArgument(2,BiFunction.class).apply(proof,(Runnable)()->{});
            throw new ApiException(ErrorCode.SNAPSHOT_CHANGED);
        }).when(pages).readWithProof(any(),any(),any());
        var response=new MockHttpServletResponse();
        summaries.stream("goods-master-list","master_goods","goods:view",query,null,
                (filter,page,size,sort,order)->page(page,size,201),response);
        var frames=frames(response);
        assertThat(frames).hasSize(4);
        assertThat(frames.getLast().get("type").asText()).isEqualTo("error");
        assertThat(frames.getLast().get("code").asText()).isEqualTo("SNAPSHOT_CHANGED");
        assertThat(frames.stream().anyMatch(frame->frame.get("type").asText().equals("complete"))).isFalse();
    }

    @Test void shortOrChangedBatchStopsInsteadOfForgingACompleteList() throws Exception {
        var response=new MockHttpServletResponse();
        summaries.stream("goods-master-list","master_goods","goods:view",query,null,
                (filter,page,size,sort,order)->page==1?page(page,size,201):new PageResponse<Row>(List.of(),page,size,201,3),response);
        var frames=frames(response);
        assertThat(frames).hasSize(2);
        assertThat(frames.getLast().get("type").asText()).isEqualTo("error");
        assertThat(frames.getLast().get("code").asText()).isEqualTo("PRIMARY_UNAVAILABLE");
    }

    @Test void aDisconnectedConsumerImmediatelyRetiresItsCursorAndDoesNotReadLaterBatches() throws Exception {
        var response=mock(jakarta.servlet.http.HttpServletResponse.class);
        when(response.getOutputStream()).thenReturn(new ServletOutputStream() {
            @Override public boolean isReady(){return true;}
            @Override public void setWriteListener(WriteListener listener){ }
            @Override public void write(int value)throws IOException {throw new IOException("fixture disconnect");}
        });
        assertThatThrownBy(()->summaries.stream("goods-master-list","master_goods","goods:view",query,null,
                (filter,page,size,sort,order)->page(page,size,10001),response))
                .isInstanceOf(IOException.class).hasMessage("fixture disconnect");
        assertThat(loads).hasValue(1);
    }

    @Test void completeReadCannotRaiseTheOriginalBatchCapOrStartInTheMiddle() {
        for(var invalid:List.of(new MasterSummaryReadSupport.Query<>(Map.of(),1,101,null,null),
                new MasterSummaryReadSupport.Query<>(Map.of(),2,100,null,null))) {
            assertThatThrownBy(()->summaries.stream("goods-master-list","master_goods","goods:view",invalid,null,
                    (filter,page,size,sort,order)->page(page,size,1),new MockHttpServletResponse()))
                    .isInstanceOf(ApiException.class);
        }
        verifyNoInteractions(pages);
    }
}
