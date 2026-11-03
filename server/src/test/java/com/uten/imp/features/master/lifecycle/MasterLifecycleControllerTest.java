package com.uten.imp.features.master.lifecycle;

import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.master.lifecycle.dto.MasterBatchResult;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.List;
import java.util.UUID;
import java.util.stream.Collectors;
import java.util.stream.IntStream;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

/**
 * 主档批量命令的 HTTP 边界(ADR-111)：越界请求在进服务层、开事务之前就被挡掉；
 * 合法请求原样交给对应主档种类，逐条结果按约定键返回。
 */
class MasterLifecycleControllerTest {

    private final MasterLifecycleService service = mock(MasterLifecycleService.class);
    private final MockMvc mvc = MockMvcBuilders.standaloneSetup(new MasterLifecycleController(service))
            .setControllerAdvice(new GlobalExceptionHandler())
            .build();

    @Test
    void moreThanFiveHundredItemsAreRejectedBeforeReachingTheService() throws Exception {
        String items = IntStream.range(0, 501)
                .mapToObj(i -> "{\"id\":\"" + UUID.randomUUID() + "\"}")
                .collect(Collectors.joining(","));
        mvc.perform(post("/api/master/goods/batch-delete")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"items\":[" + items + "]}"))
                .andExpect(status().isUnprocessableContent())
                .andExpect(jsonPath("$.code").value(ErrorCode.VALIDATION_FAILED.name()));
        mvc.perform(post("/api/master/clients/batch-status")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"status\":\"禁用\",\"items\":[]}"))
                .andExpect(status().isUnprocessableContent());
        verifyNoInteractions(service);
    }

    @Test
    void validRequestReachesTheMatchingMasterKindAndReturnsPerItemResults() throws Exception {
        UUID id = UUID.randomUUID();
        when(service.batchStatus(eq(MasterEntityKind.SUPPLIER), eq("禁用"), anyList()))
                .thenReturn(MasterBatchResult.of(List.of(
                        new MasterBatchResult.ItemResult(id, "S-1 供应商", false, "已被他人修改，请刷新后重试"))));
        mvc.perform(post("/api/master/suppliers/batch-status")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{\"status\":\"禁用\",\"items\":[{\"id\":\"" + id + "\",\"version\":3}]}"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.succeeded").value(0))
                .andExpect(jsonPath("$.failed").value(1))
                .andExpect(jsonPath("$.results[0].id").value(id.toString()))
                .andExpect(jsonPath("$.results[0].ok").value(false))
                .andExpect(jsonPath("$.results[0].reason").value("已被他人修改，请刷新后重试"));
        verify(service).batchStatus(eq(MasterEntityKind.SUPPLIER), eq("禁用"), any());
    }

    @Test
    void partyConfirmationIsExplicitAndOtherMasterKindsCannotOptOutOfReferenceGuards() throws Exception {
        UUID id=UUID.randomUUID();
        when(service.batchDelete(eq(MasterEntityKind.CLIENT), anyList(), eq(true)))
                .thenReturn(MasterBatchResult.of(List.of(new MasterBatchResult.ItemResult(id,"客户",true,null))));
        mvc.perform(post("/api/master/clients/batch-delete").contentType(MediaType.APPLICATION_JSON)
                        .content("{\"items\":[{\"id\":\""+id+"\",\"version\":4}],\"confirmReferencedHide\":true}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.succeeded").value(1));
        verify(service).batchDelete(eq(MasterEntityKind.CLIENT), anyList(), eq(true));
        when(service.batchDelete(eq(MasterEntityKind.GOODS), anyList()))
                .thenReturn(MasterBatchResult.of(List.of(new MasterBatchResult.ItemResult(id,"货品",false,"BOM引用"))));
        mvc.perform(post("/api/master/goods/batch-delete").contentType(MediaType.APPLICATION_JSON)
                        .content("{\"items\":[{\"id\":\""+id+"\"}],\"confirmReferencedHide\":true}"))
                .andExpect(status().isOk()).andExpect(jsonPath("$.results[0].confirmationRequired").value(false));
        verify(service).batchDelete(eq(MasterEntityKind.GOODS), anyList());
    }

    @Test
    void omittedNullAndFalseConfirmationKeepEveryExistingDeleteRequestCompatible() throws Exception {
        UUID id=UUID.randomUUID();
        for(var kind:MasterEntityKind.values()) {
            var result=MasterBatchResult.of(List.of(new MasterBatchResult.ItemResult(id,"资料",true,null)));
            boolean party=kind==MasterEntityKind.CLIENT||kind==MasterEntityKind.SUPPLIER;
            if(party)when(service.batchDelete(eq(kind),anyList(),eq(false))).thenReturn(result);
            else when(service.batchDelete(eq(kind),anyList())).thenReturn(result);
            for(String confirmation:List.of("",",\"confirmReferencedHide\":null",",\"confirmReferencedHide\":false")) {
                mvc.perform(post("/api/master/"+kind.table()+"/batch-delete").contentType(MediaType.APPLICATION_JSON)
                        .content("{\"items\":[{\"id\":\""+id+"\"}]"+confirmation+"}"))
                        .andExpect(status().isOk()).andExpect(jsonPath("$.succeeded").value(1));
            }
        }
    }
}
