package com.uten.imp.common.files.document;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertThrows;

class OfficePreviewXmlSafetyTest {
    @Test void selfContainedSvgSupportsGradientsStylingAndEmbeddedBitmaps() {
        inspect("<svg xmlns='http://www.w3.org/2000/svg'><defs><linearGradient id='g'/></defs>"
                + "<style>.cls{fill:url(#g)}</style><path fill='url(#g)' d='M0 0L8 8'/>"
                + "<image href='data:image/png;base64,aGVsbG8='/></svg>", OfficePreviewXmlSafety.Kind.SVG);
    }

    @Test void svgExternalImagesStylesScriptsAndEntitiesAreRefusedBeforeTheNativeParser() {
        for (String body : List.of("<image href='file:///etc/passwd'/>", "<image href='https://127.0.0.1/secret'/>",
                "<image href='local-file.png'/>", "<script>read()</script>", "<path onload='read()'/>",
                "<style>@import 'https://example.invalid/style';</style>",
                "<style>.x{fill:url(https://example.invalid/a)}</style>",
                "<style>.x{fill:url(https://example.invalid/a}</style>",
                "<style>.x{fill:u\\72l(file:///etc/passwd)}</style>",
                "<g xml:base='file:///etc/'><image href='#passwd'/></g>")) {
            assertThrows(ApiException.class, () -> inspect("<svg xmlns='http://www.w3.org/2000/svg'>" + body + "</svg>",
                    OfficePreviewXmlSafety.Kind.SVG), body);
        }
        assertThrows(ApiException.class, () -> inspect("<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///etc/passwd'>]>"
                + "<svg xmlns='http://www.w3.org/2000/svg'><text>&x;</text></svg>", OfficePreviewXmlSafety.Kind.SVG));
        assertThrows(ApiException.class, () -> inspect("<?xml-stylesheet href='file:///etc/private' type='text/css'?>"
                + "<svg xmlns='http://www.w3.org/2000/svg'/>", OfficePreviewXmlSafety.Kind.SVG));
    }

    @Test void officeHyperlinksAndInternalRelativePartsRemainUsableButAutomaticExternalResourcesDoNot() {
        for (String relation : List.of("<Relationship Type='urn:type/hyperlink' TargetMode='External' Target='https://example.com'/>",
                "<Relationship Type='urn:type/drawing' Target='../drawings/drawing1.xml'/>")) {
            assertDoesNotThrow(() -> inspect("<Relationships>" + relation + "</Relationships>", OfficePreviewXmlSafety.Kind.RELATIONSHIPS));
        }
        for (String relation : List.of("<Relationship Type='urn:type/image' TargetMode='External' Target='https://example.com/a.png'/>",
                "<Relationship Type='urn:type/attachedTemplate' Target='file:///etc/private'/>",
                "<Relationship Type='urn:type/image' Target='//host/share/a.png'/>")) {
            assertThrows(ApiException.class, () -> inspect("<Relationships>" + relation + "</Relationships>",
                    OfficePreviewXmlSafety.Kind.RELATIONSHIPS));
        }
    }

    @Test void openDocumentKeepsPackageImagesAndHyperlinksButRefusesExternalImages() {
        inspect("<document xmlns:xlink='http://www.w3.org/1999/xlink'>"
                + "<image xlink:href='Pictures/logo.png'/><a xlink:href='https://example.com'>link</a></document>",
                OfficePreviewXmlSafety.Kind.OPEN_DOCUMENT);
        assertThrows(ApiException.class, () -> inspect("<document xmlns:xlink='http://www.w3.org/1999/xlink'>"
                + "<image xlink:href='file:///etc/private'/></document>", OfficePreviewXmlSafety.Kind.OPEN_DOCUMENT));
    }

    private static void inspect(String text, OfficePreviewXmlSafety.Kind kind) {
        OfficePreviewXmlSafety.inspect(new ByteArrayInputStream(text.getBytes(StandardCharsets.UTF_8)), kind);
    }
}
