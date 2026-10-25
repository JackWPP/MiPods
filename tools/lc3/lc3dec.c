/*
 * lc3dec — 把小米耳机录音的裸 LC3 流解码成 WAV
 *
 * 背景：小米耳夹式耳机把录音以 LC3 编码存在本体里（format=1 = LC3），
 * 通过 config 52 大文件通道以裸帧形式传出（无容器、无头）。
 * 手机 App 解码后转 AAC 存成 .m4a，所以抓到的字节和 m4a 对不上。
 *
 * 设备上报的码流参数（config 0x56 响应）：
 *   采样率 16000  声道 1  位深 16
 *   profile A: 32000bps, 40 字节/帧, 解码 320 样点
 *   profile B: 16000bps, 20 字节/帧, 解码 320 样点
 *
 * LC3 帧时长 10ms → 16kHz 下每帧 160 样点。
 *
 * 编译:
 *   cc -O2 -o lc3dec lc3dec.c -I/opt/homebrew/opt/liblc3/include \
 *      -L/opt/homebrew/opt/liblc3/lib -llc3
 * 用法:
 *   ./lc3dec <raw.bin> <out.wav> [frame_bytes=40] [sr=16000]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <lc3.h>

static void put32(FILE *f, uint32_t v) { fwrite(&v, 4, 1, f); }
static void put16(FILE *f, uint16_t v) { fwrite(&v, 2, 1, f); }

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: %s <raw.bin> <out.wav> [frame_bytes=40] [sr=16000]\n", argv[0]);
        return 2;
    }
    const char *inpath = argv[1], *outpath = argv[2];
    int frame_bytes = (argc > 3) ? atoi(argv[3]) : 40;
    int sr = (argc > 4) ? atoi(argv[4]) : 16000;
    const int dt_us = 10000;                 /* LC3 10ms 帧 */
    const int nsamples = sr * dt_us / 1000000;   /* 16kHz → 160 */

    FILE *fi = fopen(inpath, "rb");
    if (!fi) { perror("open in"); return 1; }
    fseek(fi, 0, SEEK_END);
    long insize = ftell(fi);
    fseek(fi, 0, SEEK_SET);
    uint8_t *inbuf = malloc(insize);
    if (fread(inbuf, 1, insize, fi) != (size_t)insize) { perror("read"); return 1; }
    fclose(fi);

    int nframes = insize / frame_bytes;
    long total_samples = (long)nframes * nsamples;
    fprintf(stderr, "input=%ld B  frame=%d B  frames=%d  samples=%ld (%.2f s)\n",
            insize, frame_bytes, nframes, total_samples, (double)total_samples / sr);

    unsigned dec_size = lc3_decoder_size(dt_us, sr);
    void *mem = malloc(dec_size);
    lc3_decoder_t dec = lc3_setup_decoder(dt_us, sr, 0, mem);
    if (!dec) { fprintf(stderr, "lc3_setup_decoder failed\n"); return 1; }

    int16_t *pcm = malloc(total_samples * sizeof(int16_t));
    long got = 0;
    int plc = 0, err = 0;
    for (int i = 0; i < nframes; i++) {
        int rc = lc3_decode(dec, inbuf + (long)i * frame_bytes, frame_bytes,
                            LC3_PCM_FORMAT_S16, pcm + got, 1);
        if (rc == 1) plc++;
        else if (rc < 0) { err++; }
        got += nsamples;
    }
    fprintf(stderr, "decoded %ld samples, plc=%d err=%d\n", got, plc, err);

    /* 写 WAV (PCM16 mono) */
    FILE *fo = fopen(outpath, "wb");
    if (!fo) { perror("open out"); return 1; }
    uint32_t data_bytes = (uint32_t)(got * 2);
    fwrite("RIFF", 1, 4, fo); put32(fo, 36 + data_bytes); fwrite("WAVE", 1, 4, fo);
    fwrite("fmt ", 1, 4, fo); put32(fo, 16); put16(fo, 1); put16(fo, 1);
    put32(fo, sr); put32(fo, sr * 2); put16(fo, 2); put16(fo, 16);
    fwrite("data", 1, 4, fo); put32(fo, data_bytes);
    fwrite(pcm, 2, got, fo);
    fclose(fo);
    fprintf(stderr, "wrote %s\n", outpath);
    return 0;
}
