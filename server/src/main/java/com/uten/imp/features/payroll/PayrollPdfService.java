package com.uten.imp.features.payroll;

import com.uten.imp.features.payroll.dto.PayrollItemDto;
import com.uten.imp.features.payroll.dto.PayrollPdf;
import com.uten.imp.features.payroll.dto.PayrollSlipDto;
import org.springframework.stereotype.Service;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;

/**
 * 小型、无共享状态的工资条 PDF 生成器。
 *
 * <p>使用 PDF 标准 Type0/CID 字体描述与 UniGB-UCS2-H 编码，正文以
 * UTF-16BE 十六进制字符串写入；输出包含完整对象表、xref 和 trailer，
 * 不是把文本伪装成 application/pdf。
 */
@Service
public class PayrollPdfService {

    public PayrollPdf render(PayrollSlipDto slip) {
        List<String> lines = new ArrayList<>();
        lines.add("优腾智能管理平台 - 工资条");
        lines.add("工资期间：" + slip.year() + "年" + slip.month() + "月");
        lines.add("员工：" + slip.employeeName() + "（" + slip.employeeCode() + "）");
        lines.add("----------------------------------------");
        for (PayrollItemDto item : slip.items()) {
            String sign = "DEDUCTION".equals(item.type()) ? "-" : "+";
            lines.add(item.name() + "  " + sign + money(item.amount()));
        }
        lines.add("----------------------------------------");
        lines.add("应发合计：" + money(slip.grossIncome()));
        lines.add("扣除合计：" + money(slip.totalDeduction()));
        lines.add("实发合计：" + money(slip.netIncome()));
        lines.add("本工资条包含敏感个人信息，请妥善保管。");

        byte[] content = contentStream(lines);
        List<byte[]> objects = List.of(
                ascii("<< /Type /Catalog /Pages 2 0 R >>"),
                ascii("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
                ascii("""
                        << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842]
                           /Resources << /Font << /F1 4 0 R >> >>
                           /Contents 6 0 R >>
                        """),
                ascii("""
                        << /Type /Font /Subtype /Type0 /BaseFont /STSong-Light
                           /Encoding /UniGB-UCS2-H /DescendantFonts [5 0 R] >>
                        """),
                ascii("""
                        << /Type /Font /Subtype /CIDFontType0 /BaseFont /STSong-Light
                           /CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 4 >>
                           /DW 1000 >>
                        """),
                stream(content)
        );

        ByteArrayOutputStream pdf = new ByteArrayOutputStream();
        write(pdf, "%PDF-1.4\n%");
        pdf.writeBytes(new byte[]{(byte) 0xE2, (byte) 0xE3, (byte) 0xCF, (byte) 0xD3});
        write(pdf, "\n");
        List<Integer> offsets = new ArrayList<>();
        offsets.add(0);
        for (int i = 0; i < objects.size(); i++) {
            offsets.add(pdf.size());
            write(pdf, (i + 1) + " 0 obj\n");
            pdf.writeBytes(objects.get(i));
            write(pdf, "\nendobj\n");
        }
        int xrefOffset = pdf.size();
        write(pdf, "xref\n0 " + (objects.size() + 1) + "\n");
        write(pdf, "0000000000 65535 f \n");
        for (int i = 1; i < offsets.size(); i++) {
            write(pdf, String.format(Locale.ROOT, "%010d 00000 n \n", offsets.get(i)));
        }
        write(pdf, "trailer\n<< /Size " + (objects.size() + 1) + " /Root 1 0 R >>\n");
        write(pdf, "startxref\n" + xrefOffset + "\n%%EOF\n");

        String filename = "payroll-%04d-%02d-%s.pdf".formatted(
                slip.year(), slip.month(), safeFilenamePart(slip.employeeCode()));
        return new PayrollPdf(pdf.toByteArray(), filename);
    }

    private static byte[] contentStream(List<String> lines) {
        StringBuilder content = new StringBuilder("BT\n/F1 16 Tf\n50 790 Td\n");
        for (int i = 0; i < lines.size(); i++) {
            if (i > 0) {
                content.append("0 -26 Td\n");
            }
            content.append('<')
                    .append(HexFormat.of().formatHex(lines.get(i).getBytes(StandardCharsets.UTF_16BE)))
                    .append("> Tj\n");
        }
        content.append("ET\n");
        return ascii(content.toString());
    }

    private static byte[] stream(byte[] content) {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        write(out, "<< /Length " + content.length + " >>\nstream\n");
        out.writeBytes(content);
        write(out, "endstream");
        return out.toByteArray();
    }

    private static byte[] ascii(String value) {
        return value.getBytes(StandardCharsets.ISO_8859_1);
    }

    private static void write(ByteArrayOutputStream output, String value) {
        output.writeBytes(ascii(value));
    }

    private static String money(java.math.BigDecimal amount) {
        return amount.setScale(2).toPlainString();
    }

    private static String safeFilenamePart(String value) {
        String safe = value == null ? "employee" : value.replaceAll("[^A-Za-z0-9_-]", "_");
        return safe.isBlank() ? "employee" : safe;
    }
}
