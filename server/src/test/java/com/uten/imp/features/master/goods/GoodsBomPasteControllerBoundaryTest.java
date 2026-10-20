package com.uten.imp.features.master.goods;

import com.uten.imp.common.web.GlobalExceptionHandler;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.goods.dto.BomPasteResult;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.List;
import java.util.UUID;

import static org.hamcrest.Matchers.containsString;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/** The legacy public transport cannot bypass overwrite preview; internal REPLACE remains reusable. */
class GoodsBomPasteControllerBoundaryTest {
    private final GoodsBomPasteService service=mock(GoodsBomPasteService.class);
    private final MockMvc mvc=MockMvcBuilders.standaloneSetup(new GoodsBomPasteController(service))
            .setControllerAdvice(new GlobalExceptionHandler()).build();

    @Test void legacyReplaceIsRejectedBeforeAnyBusinessCommand() throws Exception {
        mvc.perform(post("/api/master/goods/bom/paste").contentType(MediaType.APPLICATION_JSON).content(body("REPLACE")))
                .andExpect(status().isConflict()).andExpect(jsonPath("$.code").value("CONFLICT"))
                .andExpect(jsonPath("$.message").value(containsString("预览")));
        verifyNoInteractions(service);
    }

    @Test void appendStillServesTheExistingCopyGoodsWorkflow() throws Exception {
        when(service.paste(any())).thenReturn(new BomPasteResult(1,1,0,List.of(),List.of()));
        mvc.perform(post("/api/master/goods/bom/paste").contentType(MediaType.APPLICATION_JSON).content(body("APPEND")))
                .andExpect(status().isOk()).andExpect(jsonPath("$.added").value(1));
        ArgumentCaptor<BomPasteRequest> request=ArgumentCaptor.forClass(BomPasteRequest.class);
        verify(service).paste(request.capture());
        assertEquals(BomPasteRequest.Mode.APPEND,request.getValue().mode());
        assertEquals(1,request.getValue().targets().size());assertEquals(1,request.getValue().items().size());
    }

    private String body(String mode) {
        return "{\"mode\":\""+mode+"\",\"targets\":[{\"goodsId\":\""+UUID.randomUUID()
                +"\"}],\"items\":[{\"componentGoodsId\":\""+UUID.randomUUID()+"\",\"qty\":1}]}";
    }
}
