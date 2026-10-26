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

    /** Disk-backed equivalent for durable exports; passwords and whole workbooks stay out of the heap. */
    public void protect(java.nio.file.Path source, java.nio.file.Path target, String password) throws java.io.IOException {
        long sourceBytes=java.nio.file.Files.size(source);
        if(sourceBytes>ExportResourceLimits.ARTIFACT_BYTES) throw new java.io.IOException("Export file size limit exceeded");
        long reservation=sourceBytes+sourceBytes/10+1024*1024;
        if(java.nio.file.Files.getFileStore(target.toAbsolutePath().getParent()).getUsableSpace()
                <ExportResourceLimits.FREE_RESERVE_BYTES+reservation)
            throw new java.io.IOException("Export free space reserve reached");
        if (password == null || password.isEmpty()) {
            java.nio.file.Files.copy(source, target);
            return;
        }
        if (password.length() > 128) throw new IllegalArgumentException("导出密码长度不能超过 128 位");
        try (POIFSFileSystem fileSystem = POIFSFileSystem.create(target.toFile())) {
            EncryptionInfo info = new EncryptionInfo(EncryptionMode.agile);
            Encryptor encryptor = info.getEncryptor();
            encryptor.confirmPassword(password);
            try (OutputStream encrypted = encryptor.getDataStream(fileSystem)) {
                java.nio.file.Files.copy(source, encrypted);
            }
            fileSystem.writeFilesystem();
            if(java.nio.file.Files.size(target)>reservation) throw new java.io.IOException("Encrypted export file size limit exceeded");
        } catch (java.security.GeneralSecurityException error) {
            throw new java.io.IOException("Excel 加密失败", error);
        }
    }

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
