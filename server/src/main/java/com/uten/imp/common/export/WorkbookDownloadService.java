package com.uten.imp.common.export;

import org.apache.poi.openxml4j.opc.OPCPackage;
import org.apache.poi.poifs.crypt.EncryptionInfo;
import org.apache.poi.poifs.crypt.EncryptionMode;
import org.apache.poi.poifs.crypt.Encryptor;
import org.apache.poi.poifs.filesystem.POIFSFileSystem;
import org.springframework.stereotype.Service;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.util.Objects;

/**
 * Prepares an OOXML workbook for download, with optional Agile AES-256 encryption.
 */
@Service
public class WorkbookDownloadService {

    /**
     * Returns the original workbook when no password is supplied, otherwise returns an encrypted container.
     */
    public byte[] protect(byte[] xlsx, String password) {
        Objects.requireNonNull(xlsx, "xlsx must not be null");
        if (password == null || password.isEmpty()) {
            return xlsx;
        }
        if (password.length() > 128) {
            throw new IllegalArgumentException("导出密码长度不能超过 128 位");
        }

        try (POIFSFileSystem fileSystem = new POIFSFileSystem();
             OPCPackage packageToEncrypt = OPCPackage.open(new ByteArrayInputStream(xlsx));
             ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            EncryptionInfo encryptionInfo = new EncryptionInfo(EncryptionMode.agile);
            Encryptor encryptor = encryptionInfo.getEncryptor();
            encryptor.confirmPassword(password);
            try (OutputStream encryptedStream = encryptor.getDataStream(fileSystem)) {
                packageToEncrypt.save(encryptedStream);
            }
            fileSystem.writeFilesystem(output);
            return output.toByteArray();
        } catch (Exception exception) {
            throw new IllegalStateException("Excel 加密失败", exception);
        }
    }
}
