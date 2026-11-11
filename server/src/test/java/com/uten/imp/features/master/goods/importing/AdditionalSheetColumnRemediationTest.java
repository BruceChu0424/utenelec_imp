package com.uten.imp.features.master.goods.importing;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.goods.*;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;
import org.junit.jupiter.api.Test;
import java.io.*;
import java.util.*;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;
class AdditionalSheetColumnRemediationTest {
    @org.junit.jupiter.api.AfterEach void clearActor(){org.springframework.security.core.context.SecurityContextHolder.clearContext();}
    @Test void exactSecondSheetAttacksCannotIssueAPlanOrReachAnyBomCommitMode() throws Exception {
        byte[] goods=file("goods-extra-second-true.xlsx"),bom=file("bom-extra-second-true.xlsx");
        var importer=new GoodsImportService(null,null,null,null,null,null,null,null,null,null,null);
        assertThatThrownBy(()->importer.detect(goods)).isInstanceOf(ApiException.class).hasMessageContaining("第一张表");
        assertThatThrownBy(()->importer.commit(UUID.randomUUID(),goods,"source.xlsx")).isInstanceOf(ApiException.class).hasMessageContaining("第一张表");
        var repo=mock(GoodsRepository.class);var paste=mock(GoodsBomPasteService.class);var target=new Goods();UUID id=UUID.randomUUID();target.setId(id);when(repo.findById(id)).thenReturn(Optional.of(target));
        var service=new GoodsBomImportService(repo,paste);
        var principal=new com.uten.imp.security.AuthUser(UUID.randomUUID(),UUID.randomUUID(),"bom-import-fixture",Set.of("goods:bom:create","goods:bom:delete"),false,true,false);
        org.springframework.security.core.context.SecurityContextHolder.getContext().setAuthentication(new org.springframework.security.authentication.UsernamePasswordAuthenticationToken(principal,null,principal.getAuthorities()));
        assertThatThrownBy(()->service.detect(id,bom)).isInstanceOf(ApiException.class).hasMessageContaining("第一张表");
        for(var mode:BomPasteRequest.Mode.values())assertThatThrownBy(()->service.commit(id,bom,mode,"v1:old"))
                .isInstanceOf(ApiException.class).hasMessageContaining("第一张表");
        assertThatThrownBy(()->service.commitMerged(id,bom,"v1:old",Set.of())).isInstanceOf(ApiException.class).hasMessageContaining("第一张表");
        verifyNoInteractions(paste);
    }
    @Test void extraSheetFormulaIsContentButPureStylesAreEmpty() throws Exception {
        for(boolean formula:List.of(false,true))try(var book=new XSSFWorkbook();var out=new ByteArrayOutputStream()) {
            book.createSheet("首表").createRow(0).createCell(0).setCellValue("名称");
            var extra=book.createSheet("第二张").createRow(3).createCell(2);
            if(formula)extra.setCellFormula("IF(1=1,\"\",\"\")");else extra.setCellStyle(book.createCellStyle());
            if(formula)assertThatThrownBy(()->GoodsImportWorkbookSecurity.inspectWorkbook(book)).hasMessageContaining("第二张!C4");
            else assertThatCode(()->GoodsImportWorkbookSecurity.inspectWorkbook(book)).doesNotThrowAnyException();
        }
    }
    private byte[] file(String name)throws Exception {try(var in=getClass().getResourceAsStream("/import-column-remediation/"+name)){return Objects.requireNonNull(in).readAllBytes();}}
}
