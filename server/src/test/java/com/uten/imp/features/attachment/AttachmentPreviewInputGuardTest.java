package com.uten.imp.features.attachment;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.files.document.ZipSafety;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

import static org.junit.jupiter.api.Assertions.*;

class AttachmentPreviewInputGuardTest {
    @TempDir Path directory;

    @Test void aNormalOfficeContainerPassesWithoutExtractingItsEntries() throws Exception {
        Path file = zip("normal.docx", "word/document.xml", 400, 2);
        ZipSafety.inspectOfficePreview(file, 1024, 10, Duration.ofSeconds(2));
        try (var listing = Files.list(directory)) { assertEquals(1, listing.count()); }
    }

    @Test void countsActualExpansionEvenWhenZipUsesUnknownSizesInDataDescriptors() throws Exception {
        Path file = zip("bomb.xlsx", "xl/worksheets/sheet", 1000000, 1);
        assertTrue(Files.size(file) < 2000, "highly compressible fixture exercises the expansion boundary");
        ApiException error = assertThrows(ApiException.class, () ->
                ZipSafety.inspectOfficePreview(file, 4096, 10, Duration.ofSeconds(2)));
        assertTrue(error.getMessage().contains("展开后过大"));
    }

    @Test void rejectsTooManyEntriesAndTraversalWithoutExtractingAnyContent() throws Exception {
        Path many = zip("many.pptx", "ppt/slides/slide", 1, 6);
        assertThrows(ApiException.class, () ->
                ZipSafety.inspectOfficePreview(many, 4096, 5, Duration.ofSeconds(2)));
        Path unsafe = zip("unsafe.docx", "../../outside", 1, 1);
        assertThrows(ApiException.class, () ->
                ZipSafety.inspectOfficePreview(unsafe, 4096, 5, Duration.ofSeconds(2)));
        assertFalse(Files.exists(directory.resolve("../outside0")));
    }

    @Test void nonArchiveFormatsAreUnchangedAndMalformedZipIsRefused() throws Exception {
        Path ordinary = directory.resolve("legacy.doc"); Files.writeString(ordinary, "legacy OLE fixture");
        ZipSafety.inspectOfficePreview(ordinary, 4096, 5, Duration.ofSeconds(2));
        Path corrupt = directory.resolve("corrupt.docx"); Files.write(corrupt, new byte[]{'P','K',3,4,0});
        assertThrows(Exception.class, () ->
                ZipSafety.inspectOfficePreview(corrupt, 4096, 5, Duration.ofSeconds(2)));
    }

    @Test void archiveTraversalAppliesTheXmlPolicyAndRetainsInternalRelativeRelationships() throws Exception {
        Path file = directory.resolve("relationships.docx");
        for (String target : new String[]{"../media/image1.png", "file:///etc/private"}) {
            try (var output = new ZipOutputStream(Files.newOutputStream(file))) {
                output.putNextEntry(new ZipEntry("word/_rels/document.xml.rels"));
                output.write(("<Relationships><Relationship Type='urn:type/image' Target='" + target
                        + "'/></Relationships>").getBytes(java.nio.charset.StandardCharsets.UTF_8));
                output.closeEntry();
            }
            if (target.startsWith("..")) {
                ZipSafety.inspectOfficePreview(file, 4096, 5, Duration.ofSeconds(2));
            } else {
                assertThrows(ApiException.class, () -> ZipSafety.inspectOfficePreview(file, 4096, 5, Duration.ofSeconds(2)));
            }
        }
    }

    private Path zip(String name, String entryPrefix, int size, int entries) throws Exception {
        Path path = directory.resolve(name);
        try (var output = new ZipOutputStream(Files.newOutputStream(path))) {
            for (int index = 0; index < entries; index++) {
                output.putNextEntry(new ZipEntry(entryPrefix + index));
                output.write(new byte[size]); output.closeEntry();
            }
        }
        return path;
    }
}
