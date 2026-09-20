package com.uten.imp.common.files;

import com.uten.imp.common.web.ApiException;
import org.junit.jupiter.api.Test;
import java.awt.image.BufferedImage;
import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import static org.assertj.core.api.Assertions.*;

class ImageDimensionGuardTest {
    @Test void realJpegAndPngHeadersAreAccepted() throws Exception {
        for (String format : new String[]{"jpeg", "png"}) {
            var bytes = new ByteArrayOutputStream();
            javax.imageio.ImageIO.write(new BufferedImage(2, 3, BufferedImage.TYPE_INT_RGB), format, bytes);
            byte[] content = bytes.toByteArray();
            assertThatCode(() -> ImageDimensionGuard.requireSafe(content, content.length, "image/" + format, true))
                    .doesNotThrowAnyException();
        }
    }
    @Test void unsignedOverflowAndSkinnyHugePngCannotBypassPixelChecks() {
        for (int[] size : new int[][]{{30001,1},{1,30001},{10000,10000},{-1,-1},{0,1}}) {
            byte[] png = new byte[24];
            System.arraycopy("IHDR".getBytes(StandardCharsets.US_ASCII),0,png,12,4);
            ByteBuffer.wrap(png).putInt(16,size[0]).putInt(20,size[1]);
            assertThatThrownBy(() -> ImageDimensionGuard.requireSafe(png,png.length,"image/png",true))
                    .isInstanceOf(ApiException.class);
        }
    }
    @Test void eachWebpHeaderShapeHasTheSamePixelBound() {
        byte[] extended = header("VP8X");
        extended[24]=(byte)255; extended[25]=(byte)255; extended[26]=(byte)255;
        byte[] lossy = header("VP8 ");
        lossy[23]=(byte)157;lossy[24]=1;lossy[25]=42;
        lossy[26]=(byte)255;lossy[27]=63;lossy[28]=(byte)255;lossy[29]=63;
        byte[] lossless = header("VP8L");
        lossless[20]=47;lossless[21]=(byte)255;lossless[22]=(byte)255;lossless[23]=(byte)255;lossless[24]=15;
        for(byte[] content : new byte[][]{extended,lossy,lossless}) {
            assertThatThrownBy(() -> ImageDimensionGuard.requireSafe(content,content.length,"image/webp",true))
                    .isInstanceOf(ApiException.class);
        }
    }
    @Test void malformedOrUnrecognizableRasterHeadersFailClosedForOcr() {
        for(String type : new String[]{"image/png","image/jpeg","image/webp"}) {
            assertThatThrownBy(() -> ImageDimensionGuard.requireSafe(new byte[12],12,type,true))
                    .isInstanceOf(ApiException.class);
        }
    }
    private byte[] header(String kind) {
        byte[] content = new byte[30];
        System.arraycopy(kind.getBytes(StandardCharsets.US_ASCII),0,content,12,4);
        return content;
    }
}
