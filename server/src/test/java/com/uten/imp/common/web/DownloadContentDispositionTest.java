package com.uten.imp.common.web;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class DownloadContentDispositionTest {

    @Test
    void ChineseFilenameHasAsciiFallbackAndUtf8ExtendedValue() {
        String header = DownloadContentDisposition.attachment("工资条-张三.xlsx");

        assertTrue(header.startsWith(
                "attachment; filename=\"download.xlsx\"; filename*=UTF-8''"));
        assertTrue(header.contains("%E5%B7%A5%E8%B5%84%E6%9D%A1"));
        assertTrue(header.endsWith(".xlsx"));
    }

    @Test
    void stripsHeaderInjectionAndPathCharacters() {
        String header =
                DownloadContentDisposition.attachment("../报表\r\nX-Evil: yes.xlsx");

        assertFalse(header.contains("\r"));
        assertFalse(header.contains("\n"));
        assertFalse(header.contains("../"));
        assertFalse(header.contains("X-Evil: yes"));
        assertTrue(header.contains("filename*=UTF-8''"));
    }

    @Test
    void preservesSafeAsciiFilename() {
        String header = DownloadContentDisposition.attachment("report-2026.xlsx");

        assertTrue(header.contains("filename=\"report-2026.xlsx\""));
        assertTrue(header.contains("filename*=UTF-8''report-2026.xlsx"));
    }
}
