/* sill-vkenc: HEVC through Vulkan video (FFmpeg's hevc_vulkan) for the Sill Linux host.
 *
 * On NVIDIA, NVENC through CUDA holds the GPU at P2 and full clocks while it encodes (about 126 W on
 * a 3080 Ti); the same encode through Vulkan lets it stay at P5 (about 54 W).
 *
 *   sill-vkenc DEVICE FPS KBPS GOP     encode: frames in on stdin, access units out on stdout
 *   sill-vkenc DEVICE probe            encode a few frames, exit 0 if a keyframe came out
 *
 * DEVICE is a Vulkan device name (or part of one), e.g. "NVIDIA GeForce RTX 3080 Ti".
 * In:  per frame, 7 native uint32: flags (1 = make this a keyframe), width, height, Y stride,
 *      UV stride, UV offset, size; then `size` bytes of NV12.
 * Out: per access unit, 2 native uint32: size, flags (1 = keyframe); then Annex B bytes. A
 *      keyframe starts with VPS/SPS/PPS. One frame in gives its access unit out before the next
 *      frame is read: no B-frames, no lookahead, one frame in flight.
 * Any error: a message on stderr and a non-zero exit. The host then uses its other encoders. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/opt.h>

static AVBufferRef *dev, *frames;
static AVCodecContext *enc;
static int cur_w, cur_h, fps = 60, kbps = 20000, gop = 240;
static int64_t pts;

static void die(const char *what, int err) {
    char buf[128] = "";
    if (err < 0) av_strerror(err, buf, sizeof buf);
    fprintf(stderr, "sill-vkenc: %s%s%s\n", what, err < 0 ? ": " : "", buf);
    exit(1);
}

static void close_encoder(void) {
    avcodec_free_context(&enc);
    av_buffer_unref(&frames);
}

static void open_encoder(int w, int h) {
    const AVCodec *codec = avcodec_find_encoder_by_name("hevc_vulkan");
    if (!codec) die("this FFmpeg has no hevc_vulkan", 0);
    close_encoder();
    frames = av_hwframe_ctx_alloc(dev);
    if (!frames) die("hw frames", 0);
    AVHWFramesContext *fc = (AVHWFramesContext *)frames->data;
    fc->format = AV_PIX_FMT_VULKAN;
    fc->sw_format = AV_PIX_FMT_NV12;
    fc->width = w;
    fc->height = h;
    int r = av_hwframe_ctx_init(frames);
    if (r < 0) die("hw frames init", r);
    enc = avcodec_alloc_context3(codec);
    enc->width = w;
    enc->height = h;
    enc->pix_fmt = AV_PIX_FMT_VULKAN;
    enc->hw_frames_ctx = av_buffer_ref(frames);
    enc->time_base = (AVRational){1, fps};
    enc->framerate = (AVRational){fps, 1};
    enc->bit_rate = (int64_t)kbps * 1000;
    enc->rc_max_rate = (int64_t)kbps * 2000;
    /* About three frames: low latency, room for detail (as the GStreamer encoders get). */
    int vbv = kbps / (fps > 0 ? fps : 1) * 3;
    enc->rc_buffer_size = (vbv < 200 ? 200 : vbv) * 1000;
    enc->gop_size = gop;
    enc->max_b_frames = 0;
    enc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER | AV_CODEC_FLAG_LOW_DELAY;
    av_opt_set(enc->priv_data, "rc_mode", "vbr", 0);
    /* "ull" draws about 20 W more than "ll" on a 3080 Ti under motion, for no less latency here:
     * one frame in flight either way. */
    av_opt_set(enc->priv_data, "tune", "ll", 0);
    av_opt_set(enc->priv_data, "usage", "stream", 0);
    av_opt_set(enc->priv_data, "content", "desktop", 0);
    av_opt_set_int(enc->priv_data, "async_depth", 1, 0);
    av_opt_set(enc->priv_data, "profile", "main", 0);
    r = avcodec_open2(enc, codec, NULL);
    if (r < 0) die("hevc_vulkan open", r);
    if (enc->extradata_size <= 0) die("hevc_vulkan gave no VPS/SPS/PPS", 0);
    cur_w = w;
    cur_h = h;
    pts = 0;
}

static void put(const void *p, size_t n) {
    if (fwrite(p, 1, n, stdout) != n) exit(0);   /* the host went away */
}

/* Whether an Annex B access unit has a VPS (NAL type 32). */
static int has_vps(const uint8_t *d, int n) {
    for (int i = 0; i + 3 < n; i++)
        if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 && ((d[i + 3] >> 1) & 0x3f) == 32) return 1;
    return 0;
}

/* Returns the number of access units written. */
static int drain(void) {
    AVPacket *pkt = av_packet_alloc();
    int n = 0;
    for (;;) {
        int r = avcodec_receive_packet(enc, pkt);
        if (r == AVERROR(EAGAIN) || r == AVERROR_EOF) break;
        if (r < 0) die("encode", r);
        int key = (pkt->flags & AV_PKT_FLAG_KEY) != 0;
        int extra = key && !has_vps(pkt->data, pkt->size);   /* hevc_vulkan repeats them itself */
        uint32_t hdr[2] = {(uint32_t)(pkt->size + (extra ? enc->extradata_size : 0)), (uint32_t)key};
        put(hdr, sizeof hdr);
        if (extra) put(enc->extradata, enc->extradata_size);
        put(pkt->data, pkt->size);
        av_packet_unref(pkt);
        n++;
    }
    av_packet_free(&pkt);
    fflush(stdout);
    return n;
}

static int encode(const uint8_t *nv12, int w, int h, int sy, int suv, int ouv, int key) {
    if (!enc || w != cur_w || h != cur_h) open_encoder(w, h);
    AVFrame *sw = av_frame_alloc(), *hw = av_frame_alloc();
    sw->format = AV_PIX_FMT_NV12;
    sw->width = w;
    sw->height = h;
    sw->data[0] = (uint8_t *)nv12;
    sw->linesize[0] = sy;
    sw->data[1] = (uint8_t *)nv12 + ouv;
    sw->linesize[1] = suv;
    int r = av_hwframe_get_buffer(frames, hw, 0);
    if (r < 0) die("hw frame", r);
    r = av_hwframe_transfer_data(hw, sw, 0);
    if (r < 0) die("upload", r);
    hw->pts = pts++;
    if (key) {
        hw->pict_type = AV_PICTURE_TYPE_I;
        hw->flags |= AV_FRAME_FLAG_KEY;
    }
    r = avcodec_send_frame(enc, hw);
    if (r < 0) die("send frame", r);
    av_frame_free(&sw);
    av_frame_free(&hw);
    return drain();
}

static int probe(void) {
    int w = 640, h = 360, out = 0;
    if (!freopen("/dev/null", "w", stdout)) die("/dev/null", 0);
    uint8_t *buf = malloc(w * h * 3 / 2);
    for (int i = 0; i < 4; i++) {
        memset(buf, 16 + i * 40, w * h);
        memset(buf + w * h, 128, w * h / 2);
        int n = encode(buf, w, h, w, w, w * h, i == 3);
        if (n == 0) die("no access unit came out right after its frame (would add latency)", 0);
        out += n;
    }
    free(buf);
    fprintf(stderr, "sill-vkenc: ok, %d access units\n", out);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: sill-vkenc DEVICE FPS KBPS GOP | sill-vkenc DEVICE probe\n");
        return 2;
    }
    av_log_set_level(AV_LOG_ERROR);
    int r = av_hwdevice_ctx_create(&dev, AV_HWDEVICE_TYPE_VULKAN, argv[1], NULL, 0);
    if (r < 0) die("Vulkan device", r);
    if (!strcmp(argv[2], "probe")) return probe();
    if (argc < 5) die("missing FPS KBPS GOP", 0);
    fps = atoi(argv[2]);
    kbps = atoi(argv[3]);
    gop = atoi(argv[4]);
    uint8_t *buf = NULL;
    size_t cap = 0;
    for (;;) {
        uint32_t h[7];
        if (fread(h, sizeof h, 1, stdin) != 1) break;   /* the host closed: done */
        if (h[1] == 0 || h[2] == 0 || h[1] > 8192 || h[2] > 8192 || h[6] > 256u << 20) die("bad frame header", 0);
        if (h[6] > cap) {
            cap = h[6];
            buf = realloc(buf, cap);
            if (!buf) die("out of memory", 0);
        }
        if (fread(buf, 1, h[6], stdin) != h[6]) break;
        if ((size_t)h[5] + (size_t)h[4] * (h[2] / 2) > h[6] || (size_t)h[3] * h[2] > h[5]) die("frame too small", 0);
        if (encode(buf, h[1], h[2], h[3], h[4], h[5], h[0] & 1) == 0)
            die("no access unit came out right after its frame", 0);
    }
    close_encoder();
    av_buffer_unref(&dev);
    return 0;
}
