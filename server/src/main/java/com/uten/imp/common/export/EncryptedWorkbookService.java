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

/**
 * 用 OOXML Agile 加密（AES-256）把明文 .xlsx 字节包装成加密容器。
 *
 * <p>Excel / WPS / LibreOffice 双击即弹密码框（优于 ZIP 套壳，免二次解压）。Agile 模式由
 * 已注册的 BouncyCastle provider 支撑（见 {@code BouncyCastleRegistrar}）。
 *
 * <p>用法：{@code byte[] enc = enc.encrypt(xlsxExportService.build(cols, rows), password);}。
 * 校验：写加密后可用 {@code WorkbookFactory.create(new ByteArrayInputStream(enc), password)} 读回。
 */
@Service
public class EncryptedWorkbookService {

    public byte[] encrypt(byte[] xlsx, String password) {
        if (password == null || password.isEmpty()) {
            throw new IllegalArgumentException("导出密码不能为空");
        }
        POIFSFileSystem fs = null;
        OPCPackage pkg = null;
        try {
            fs = new POIFSFileSystem();
            pkg = OPCPackage.open(new ByteArrayInputStream(xlsx));
            EncryptionInfo info = new EncryptionInfo(EncryptionMode.agile);
            Encryptor enc = info.getEncryptor();
            enc.confirmPassword(password);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try (OutputStream os = enc.getDataStream(fs)) {
                pkg.save(os);
            }
            fs.writeFilesystem(out);
            return out.toByteArray();
        } catch (Exception e) {
            throw new RuntimeException("Excel 加密失败", e);
        } finally {
            if (pkg != null) {
                try { pkg.revert(); } catch (Exception ignored) {}
            }
            if (fs != null) {
                try { fs.close(); } catch (Exception ignored) {}
            }
        }
    }
}
