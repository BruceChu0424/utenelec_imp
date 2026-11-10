package com.uten.imp.features.master.goods.importing;

import com.uten.imp.features.master.goods.*;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import org.junit.jupiter.api.Test;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class GoodsBomImportColumnContractTest {
    @Test void previewAndBothCommitModesRejectUnknownOrAmbiguousColumnsWithoutAnyPaste() throws Exception {
        var repo=mock(GoodsRepository.class);var paste=mock(GoodsBomPasteService.class);UUID targetId=UUID.randomUUID();
        var target=new Goods();target.setId(targetId);when(repo.findById(targetId)).thenReturn(Optional.of(target));
        var service=new GoodsBomImportService(repo,paste);
        for(String extra:List.of("自定义列","数量")) {
            byte[] bytes=GoodsImportColumnContractTest.workbook(new String[]{"序号","编号","设计使用数量",extra},new String[]{"1","C1","1","不能丢"},false);
            var report=service.detect(targetId,bytes);assertThat(report.hasErrors()).isTrue();assertThat(report.stateFingerprint()).isNull();
            assertThat(report.errors()).anyMatch(error->error.message().contains(extra.equals("数量")?"重复":"不支持"));
            assertThatThrownBy(()->service.commitMerged(targetId,bytes,"v1:old",Set.of())).hasMessageContaining("未修正");
            assertThatThrownBy(()->service.commit(targetId,bytes,BomPasteRequest.Mode.APPEND,"v1:old")).hasMessageContaining("问题");
        }
        verifyNoInteractions(paste);
    }
}
