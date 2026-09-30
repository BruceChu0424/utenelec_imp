package com.uten.imp.features.master.goods.costing;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.application.port.GoodsActualCostQueryPort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContextHolder;
import java.util.List;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsActualCostSnapshotServiceTest {
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }
    @Test void newNavigationRevisionsDoNotChangeTheSelectedHistoricalCostDigest() throws Exception {
        UUID root=UUID.fromString("00000000-0000-0000-0000-000000000001");
        UUID revision=UUID.fromString("00000000-0000-0000-0000-000000000010");
        String json="""
                {"goodsId":"00000000-0000-0000-0000-000000000001","capturedAt":"2026-09-29T00:00:00Z",
                 "costObjects":[{"revisionId":"00000000-0000-0000-0000-000000000010","historicalRevision":false}],
                 "inputs":[{"knownAmountLocal":"20","laterCostRevision":false}],"outputs":[],"gaps":[],
                 "revisions":[{"revisionId":"00000000-0000-0000-0000-000000000010","version":1}]}
                """;
        var mapper=new ObjectMapper().findAndRegisterModules();
        var first=mapper.readValue(json,GoodsActualCostQueryPort.ActualCostSnapshot.class);
        var changed=mapper.readTree(json);
        ((com.fasterxml.jackson.databind.node.ObjectNode)changed).put("capturedAt","2026-09-30T00:00:00Z");
        ((com.fasterxml.jackson.databind.node.ObjectNode)changed.path("costObjects").get(0)).put("historicalRevision",true);
        ((com.fasterxml.jackson.databind.node.ObjectNode)changed.path("inputs").get(0)).put("laterCostRevision",true);
        ((com.fasterxml.jackson.databind.node.ArrayNode)changed.path("revisions")).addObject()
                .put("revisionId","00000000-0000-0000-0000-000000000011").put("version",2);
        var second=mapper.treeToValue(changed,GoodsActualCostQueryPort.ActualCostSnapshot.class);
        var port=mock(GoodsActualCostQueryPort.class);when(port.snapshot(any())).thenReturn(first,second);
        var service=new GoodsActualCostSnapshotService(port,mock(GoodsCostSheetService.class),new GoodsCostJson(mapper),mapper);
        var query=new GoodsActualCostQueryPort.Query(root,null,null,null,revision);
        assertThat(service.read(query).digest()).isEqualTo(service.read(query).digest());
    }
    @Test void unseenComponentPreventsBothDisplayAndDownloadIncludingAggregateSideChannels() throws Exception {
        UUID root = UUID.fromString("00000000-0000-0000-0000-000000000001");
        UUID component = UUID.fromString("00000000-0000-0000-0000-000000000002");
        var port = mock(GoodsActualCostQueryPort.class);
        var sheets = mock(GoodsCostSheetService.class);
        var mapper = new ObjectMapper().findAndRegisterModules();
        var snapshot = mapper.readValue("""
                {"goodsId":"00000000-0000-0000-0000-000000000001","capturedAt":"2026-09-29T00:00:00Z",
                "inputs":[{"goodsId":"00000000-0000-0000-0000-000000000002","goodsName":"不可见材料","knownAmountLocal":"123.0000000000001"}],
                "costObjects":[],"outputs":[],"revisions":[],"gaps":[]}
                """, GoodsActualCostQueryPort.ActualCostSnapshot.class);
        when(port.snapshot(any())).thenReturn(snapshot);
        doThrow(new ApiException(ErrorCode.FORBIDDEN)).when(sheets).requireGoodsScope(component);
        var service = new GoodsActualCostSnapshotService(port, sheets, new GoodsCostJson(mapper), mapper);
        var query = new GoodsActualCostQueryPort.Query(root, null, null, null, null);
        assertThatThrownBy(() -> service.view(query)).isInstanceOf(ApiException.class);
        SecurityContextHolder.getContext().setAuthentication(new UsernamePasswordAuthenticationToken("test", null,
                List.of(new SimpleGrantedAuthority("goods:cost:view"), new SimpleGrantedAuthority("goods:cost:export"))));
        assertThatThrownBy(() -> service.export(query, "a".repeat(64))).isInstanceOf(ApiException.class);
        verify(sheets, times(2)).requireGoodsScope(component);
    }
}
