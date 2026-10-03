package com.uten.imp.common.files.document;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;
import static org.assertj.core.api.Assertions.*;

class DocxTextReaderTest {
    private static final String HEAD = "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>";
    private static final String TAIL = "</w:body></w:document>";
    static byte[] archive(Map<String,String> entries) throws Exception {
        var out=new ByteArrayOutputStream();
        try(var zip=new ZipOutputStream(out)) {
            for(var entry:entries.entrySet()) {zip.putNextEntry(new ZipEntry(entry.getKey()));zip.write(entry.getValue().getBytes(StandardCharsets.UTF_8));zip.closeEntry();}
        }
        return out.toByteArray();
    }
    byte[] doc(String xml) throws Exception {return archive(Map.of("[Content_Types].xml","<Types/>","word/document.xml",xml));}
    @Test void readsBodyAndTableParagraphsWithoutFieldInstructions() throws Exception {
        var bytes=doc(HEAD+"<w:p><w:r><w:t>电子发票</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>价税合计：123.00</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p><w:r><w:instrText>DDE AUTO OPEN</w:instrText></w:r></w:p>"+TAIL);
        assertThat(DocumentSniffer.sniff(bytes,"bill.docx")).isEqualTo(DocumentKind.DOCX);
        assertThat(DocxTextReader.read(bytes)).containsExactly("电子发票","价税合计：123.00");
    }
    @Test void rejectsExternalEntityWithoutOpeningIt() throws Exception {
        byte[] bytes=doc("<!DOCTYPE document [<!ENTITY stolen SYSTEM 'file:///not-readable'>]>"+HEAD+"<w:p><w:r><w:t>&stolen;</w:t></w:r></w:p>"+TAIL);
        assertThatThrownBy(()->DocxTextReader.read(bytes)).isInstanceOf(ApiException.class);
    }
    @Test void rejectsEmbeddedActiveContentAndMacroExtension() throws Exception {
        byte[] bytes=archive(Map.of("[Content_Types].xml","<Types/>","word/document.xml",HEAD+TAIL,"word/vbaProject.bin","binary"));
        assertThatThrownBy(()->DocxTextReader.read(bytes)).isInstanceOf(ApiException.class);
        assertThat(DocumentSniffer.sniff(bytes,"unsafe.docm")).isEqualTo(DocumentKind.UNSUPPORTED);
    }
    @Test void rejectsZipExpansionAndTraversal() throws Exception {
        byte[] oversized=doc(HEAD+"<w:p><w:r><w:t>"+"A".repeat(2_000_000)+"</w:t></w:r></w:p>"+TAIL);
        assertThatThrownBy(()->DocxTextReader.read(oversized)).isInstanceOf(ApiException.class);
        byte[] traversal=archive(Map.of("word/document.xml",HEAD+TAIL,"../escape.txt","data","[Content_Types].xml","<Types/>"));
        assertThatThrownBy(()->DocxTextReader.read(traversal)).isInstanceOf(ApiException.class);
    }
    @Test void multipleInvoiceAnchorsCannotProduceASingleTotal() {
        assertThat(InvoiceMultiplicity.multiple(java.util.List.of("价税合计 100.00","价税合计 200.00"))).isTrue();
        assertThat(InvoiceMultiplicity.multiple(java.util.List.of("Invoice No. ABC-1","Invoice number ABC-2"))).isTrue();
        assertThat(InvoiceMultiplicity.multiple(java.util.List.of("价税合计 100.00","发票号码 12345678"))).isFalse();
        assertThat(InvoiceMultiplicity.multiple(java.util.List.of("价税合计（小写）100.00","价税合计（大写）壹佰元整"))).isFalse();
    }
}
