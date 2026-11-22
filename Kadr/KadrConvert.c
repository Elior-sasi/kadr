#include "KadrConvert.h"

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/imgutils.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <stdio.h>
#include <string.h>

#define MAX_SUBS 32

typedef struct {
    AVFormatContext *ic, *oc;
    int vi, ai;
    AVStream *vin, *ain, *vout, *aout;
    int vcopy, acopy;

    AVCodecContext *vdec, *venc;
    struct SwsContext *sws;
    int sws_w, sws_h, sws_fmt;
    AVFrame *vframe, *vscaled;
    int64_t v_last_pts;

    AVCodecContext *adec, *aenc;
    SwrContext *swr;
    AVAudioFifo *fifo;
    AVFrame *aframe;
    int64_t a_next_pts;
    int a_started;

    AVFormatContext *soc[MAX_SUBS];
    int *sub_slot;          /* input stream index -> slot in soc, or -1 */
    int nsubs;

    AVPacket *opkt;
    char *err;
    int err_len;
} Conv;

static void seterr(Conv *c, const char *msg, const char *detail) {
    if (!c->err || c->err_len <= 0 || c->err[0]) return;
    if (detail && detail[0]) snprintf(c->err, c->err_len, "%s (%s)", msg, detail);
    else snprintf(c->err, c->err_len, "%s", msg);
}

static int video_can_copy(const AVCodecParameters *p) {
    int f = p->format;
    if (p->codec_id == AV_CODEC_ID_HEVC)
        return f == AV_PIX_FMT_NONE || f == AV_PIX_FMT_YUV420P || f == AV_PIX_FMT_YUVJ420P ||
               f == AV_PIX_FMT_YUV420P10LE;
    if (p->codec_id == AV_CODEC_ID_H264) {
        int prof = p->profile & ~AV_PROFILE_H264_INTRA;
        if (prof == AV_PROFILE_H264_HIGH_10 || prof == AV_PROFILE_H264_HIGH_422 ||
            prof == AV_PROFILE_H264_HIGH_444_PREDICTIVE || prof == AV_PROFILE_H264_HIGH_444)
            return 0;
        return f == AV_PIX_FMT_NONE || f == AV_PIX_FMT_YUV420P || f == AV_PIX_FMT_YUVJ420P;
    }
    return 0;
}

static int audio_can_copy(const AVCodecParameters *p) {
    return p->codec_id == AV_CODEC_ID_AAC || p->codec_id == AV_CODEC_ID_MP3 ||
           p->codec_id == AV_CODEC_ID_ALAC;
}

static int write_encoded(Conv *c, AVCodecContext *enc, AVStream *ost) {
    int ret;
    while ((ret = avcodec_receive_packet(enc, c->opkt)) >= 0) {
        av_packet_rescale_ts(c->opkt, enc->time_base, ost->time_base);
        c->opkt->stream_index = ost->index;
        av_interleaved_write_frame(c->oc, c->opkt);   /* a bad packet is dropped, not fatal */
        av_packet_unref(c->opkt);
    }
    return (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) ? 0 : ret;
}

/* ---------- video ---------- */

static const AVCodec *find_h264_encoder(void) {
    const AVCodec *e = avcodec_find_encoder_by_name("h264_videotoolbox");
    if (!e) e = avcodec_find_encoder_by_name("libx264");   /* desktop test builds only */
    return e;
}

static int open_video_transcode(Conv *c) {
    AVCodecParameters *p = c->vin->codecpar;
    const AVCodec *dec = avcodec_find_decoder(p->codec_id);
    if (!dec) { seterr(c, "אין מפענח לסוג הווידאו הזה", avcodec_get_name(p->codec_id)); return AVERROR_DECODER_NOT_FOUND; }
    c->vdec = avcodec_alloc_context3(dec);
    if (!c->vdec) return AVERROR(ENOMEM);
    avcodec_parameters_to_context(c->vdec, p);
    c->vdec->pkt_timebase = c->vin->time_base;
    c->vdec->thread_count = 0;
    if (avcodec_open2(c->vdec, dec, NULL) < 0) { seterr(c, "לא הצלחתי לפתוח את מפענח הווידאו", dec->name); return AVERROR(EINVAL); }

    const AVCodec *enc = find_h264_encoder();
    if (!enc) { seterr(c, "מקודד H.264 לא זמין", NULL); return AVERROR_ENCODER_NOT_FOUND; }
    c->venc = avcodec_alloc_context3(enc);
    if (!c->venc) return AVERROR(ENOMEM);

    int w = p->width & ~1, h = p->height & ~1;
    if (w <= 0 || h <= 0) { seterr(c, "גודל הווידאו לא ידוע", NULL); return AVERROR(EINVAL); }
    AVRational fr = av_guess_frame_rate(c->ic, c->vin, NULL);
    if (fr.num <= 0 || fr.den <= 0 || av_q2d(fr) > 240) fr = (AVRational){30, 1};

    c->venc->width = w;
    c->venc->height = h;
    c->venc->pix_fmt = AV_PIX_FMT_YUV420P;
    c->venc->framerate = fr;
    c->venc->time_base = c->vin->time_base;
    c->venc->sample_aspect_ratio = p->sample_aspect_ratio;
    c->venc->gop_size = (int)(av_q2d(fr) * 2 + 0.5);
    c->venc->max_b_frames = 0;
    int64_t br = (int64_t)((double)w * h * av_q2d(fr) * 0.12);
    if (br < 1500000) br = 1500000;
    if (br > 25000000) br = 25000000;
    c->venc->bit_rate = br;
    if (c->oc->oformat->flags & AVFMT_GLOBALHEADER) c->venc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    av_opt_set_int(c->venc->priv_data, "allow_sw", 1, 0);   /* videotoolbox: simulator has no hardware */
    av_opt_set(c->venc->priv_data, "preset", "veryfast", 0); /* libx264 only */
    int ret = avcodec_open2(c->venc, enc, NULL);
    if (ret < 0) { seterr(c, "לא הצלחתי להפעיל את מקודד הווידאו", av_err2str(ret)); return ret; }

    c->vout = avformat_new_stream(c->oc, NULL);
    if (!c->vout) return AVERROR(ENOMEM);
    avcodec_parameters_from_context(c->vout->codecpar, c->venc);
    c->vout->time_base = c->venc->time_base;
    c->vout->avg_frame_rate = fr;

    c->vframe = av_frame_alloc();
    c->vscaled = av_frame_alloc();
    if (!c->vframe || !c->vscaled) return AVERROR(ENOMEM);
    c->vscaled->format = AV_PIX_FMT_YUV420P;
    c->vscaled->width = w;
    c->vscaled->height = h;
    if ((ret = av_frame_get_buffer(c->vscaled, 0)) < 0) return ret;
    c->v_last_pts = AV_NOPTS_VALUE;
    return 0;
}

static int encode_video(Conv *c, AVFrame *f) {
    int ret = avcodec_send_frame(c->venc, f);
    if (ret < 0 && ret != AVERROR_EOF) return ret;
    return write_encoded(c, c->venc, c->vout);
}

static int decode_video(Conv *c, const AVPacket *pkt) {
    int ret = avcodec_send_packet(c->vdec, pkt);
    if (ret < 0 && ret != AVERROR_EOF) return 0;   /* skip a broken packet */
    while ((ret = avcodec_receive_frame(c->vdec, c->vframe)) >= 0) {
        AVFrame *f = c->vframe;
        if (!c->sws || f->width != c->sws_w || f->height != c->sws_h || f->format != c->sws_fmt) {
            sws_freeContext(c->sws);
            c->sws = sws_getContext(f->width, f->height, f->format, c->venc->width, c->venc->height,
                                    AV_PIX_FMT_YUV420P, SWS_BILINEAR, NULL, NULL, NULL);
            if (!c->sws) { seterr(c, "המרת התמונה נכשלה", NULL); return AVERROR(EINVAL); }
            c->sws_w = f->width; c->sws_h = f->height; c->sws_fmt = f->format;
        }
        if ((ret = av_frame_make_writable(c->vscaled)) < 0) return ret;
        sws_scale(c->sws, (const uint8_t *const *)f->data, f->linesize, 0, f->height,
                  c->vscaled->data, c->vscaled->linesize);

        int64_t step = av_rescale_q(1, av_inv_q(c->venc->framerate), c->venc->time_base);
        if (step < 1) step = 1;
        int64_t pts = f->best_effort_timestamp;
        if (pts == AV_NOPTS_VALUE) pts = (c->v_last_pts == AV_NOPTS_VALUE) ? 0 : c->v_last_pts + step;
        if (c->v_last_pts != AV_NOPTS_VALUE && pts <= c->v_last_pts) pts = c->v_last_pts + 1;
        c->v_last_pts = pts;
        c->vscaled->pts = pts;
        av_frame_unref(f);
        if ((ret = encode_video(c, c->vscaled)) < 0) return ret;
    }
    return (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) ? 0 : ret;
}

/* ---------- audio ---------- */

static int open_audio_transcode(Conv *c) {
    AVCodecParameters *p = c->ain->codecpar;
    const AVCodec *dec = avcodec_find_decoder(p->codec_id);
    if (!dec) return AVERROR_DECODER_NOT_FOUND;
    c->adec = avcodec_alloc_context3(dec);
    if (!c->adec) return AVERROR(ENOMEM);
    avcodec_parameters_to_context(c->adec, p);
    c->adec->pkt_timebase = c->ain->time_base;
    if (avcodec_open2(c->adec, dec, NULL) < 0) return AVERROR(EINVAL);

    const AVCodec *enc = avcodec_find_encoder(AV_CODEC_ID_AAC);
    if (!enc) return AVERROR_ENCODER_NOT_FOUND;
    c->aenc = avcodec_alloc_context3(enc);
    if (!c->aenc) return AVERROR(ENOMEM);
    int rate = p->sample_rate;
    if (rate != 44100 && rate != 48000) rate = 48000;
    c->aenc->sample_rate = rate;
    av_channel_layout_default(&c->aenc->ch_layout, 2);
    c->aenc->sample_fmt = AV_SAMPLE_FMT_FLTP;
    c->aenc->bit_rate = 192000;
    c->aenc->time_base = (AVRational){1, rate};
    if (c->oc->oformat->flags & AVFMT_GLOBALHEADER) c->aenc->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
    int ret = avcodec_open2(c->aenc, enc, NULL);
    if (ret < 0) return ret;

    c->aout = avformat_new_stream(c->oc, NULL);
    if (!c->aout) return AVERROR(ENOMEM);
    avcodec_parameters_from_context(c->aout->codecpar, c->aenc);
    c->aout->time_base = c->aenc->time_base;
    av_dict_copy(&c->aout->metadata, c->ain->metadata, 0);

    c->fifo = av_audio_fifo_alloc(c->aenc->sample_fmt, 2, 4096);
    c->aframe = av_frame_alloc();
    if (!c->fifo || !c->aframe) return AVERROR(ENOMEM);
    return 0;
}

static int drain_fifo(Conv *c, int final) {
    int fs = c->aenc->frame_size > 0 ? c->aenc->frame_size : 1024;
    while (av_audio_fifo_size(c->fifo) >= fs || (final && av_audio_fifo_size(c->fifo) > 0)) {
        int n = FFMIN(fs, av_audio_fifo_size(c->fifo));
        AVFrame *o = av_frame_alloc();
        if (!o) return AVERROR(ENOMEM);
        o->nb_samples = fs;
        o->format = c->aenc->sample_fmt;
        o->sample_rate = c->aenc->sample_rate;
        av_channel_layout_copy(&o->ch_layout, &c->aenc->ch_layout);
        int ret = av_frame_get_buffer(o, 0);
        if (ret < 0) { av_frame_free(&o); return ret; }
        if (n < fs) av_samples_set_silence(o->data, 0, fs, 2, o->format);
        av_audio_fifo_read(c->fifo, (void **)o->data, n);
        o->pts = c->a_next_pts;
        c->a_next_pts += fs;
        ret = avcodec_send_frame(c->aenc, o);
        av_frame_free(&o);
        if (ret < 0) return ret;
        if ((ret = write_encoded(c, c->aenc, c->aout)) < 0) return ret;
    }
    return 0;
}

static int push_samples(Conv *c, const uint8_t **in, int in_n) {
    int out_n = swr_get_out_samples(c->swr, in_n);
    if (out_n <= 0) return 0;
    uint8_t **buf = NULL;
    int ret = av_samples_alloc_array_and_samples(&buf, NULL, 2, out_n, c->aenc->sample_fmt, 0);
    if (ret < 0) return ret;
    int got = swr_convert(c->swr, buf, out_n, in, in_n);
    if (got > 0) av_audio_fifo_write(c->fifo, (void **)buf, got);
    av_freep(&buf[0]);
    av_freep(&buf);
    return got < 0 ? got : 0;
}

static int decode_audio(Conv *c, const AVPacket *pkt) {
    int ret = avcodec_send_packet(c->adec, pkt);
    if (ret < 0 && ret != AVERROR_EOF) return 0;
    while ((ret = avcodec_receive_frame(c->adec, c->aframe)) >= 0) {
        AVFrame *f = c->aframe;
        if (!c->swr) {
            AVChannelLayout in_l = {0};
            if (f->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC || f->ch_layout.nb_channels == 0)
                av_channel_layout_default(&in_l, f->ch_layout.nb_channels > 0 ? f->ch_layout.nb_channels : 2);
            else
                av_channel_layout_copy(&in_l, &f->ch_layout);
            ret = swr_alloc_set_opts2(&c->swr, &c->aenc->ch_layout, c->aenc->sample_fmt, c->aenc->sample_rate,
                                      &in_l, f->format, f->sample_rate, 0, NULL);
            av_channel_layout_uninit(&in_l);
            if (ret < 0 || swr_init(c->swr) < 0) { av_frame_unref(f); return AVERROR(EINVAL); }
        }
        if (!c->a_started) {
            int64_t pts = f->best_effort_timestamp;
            c->a_next_pts = pts == AV_NOPTS_VALUE ? 0 : av_rescale_q(pts, c->ain->time_base, c->aenc->time_base);
            if (c->a_next_pts < 0) c->a_next_pts = 0;
            c->a_started = 1;
        }
        ret = push_samples(c, (const uint8_t **)f->extended_data, f->nb_samples);
        av_frame_unref(f);
        if (ret < 0) return ret;
        if ((ret = drain_fifo(c, 0)) < 0) return ret;
    }
    return (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) ? 0 : ret;
}

/* ---------- subtitles ---------- */

static void clean_field(char *dst, size_t len, const char *src) {
    size_t j = 0;
    for (size_t i = 0; src && src[i] && j + 1 < len; i++)
        dst[j++] = (src[i] == '\t' || src[i] == '\n' || src[i] == '\r') ? ' ' : src[i];
    dst[j] = 0;
}

static void open_subtitles(Conv *c, const char *subs_dir) {
    if (!subs_dir) return;
    char idx_path[2048];
    snprintf(idx_path, sizeof idx_path, "%s/subs.tsv", subs_dir);
    FILE *idx = fopen(idx_path, "w");
    if (!idx) return;
    for (unsigned i = 0; i < c->ic->nb_streams && c->nsubs < MAX_SUBS; i++) {
        AVStream *st = c->ic->streams[i];
        if (st->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) continue;
        const char *fmt = NULL, *ext = NULL;
        switch (st->codecpar->codec_id) {
            case AV_CODEC_ID_ASS: fmt = "ass"; ext = "ass"; break;
            case AV_CODEC_ID_SUBRIP: fmt = "srt"; ext = "srt"; break;
            case AV_CODEC_ID_WEBVTT: fmt = "webvtt"; ext = "vtt"; break;
            default: continue;   /* picture subtitles (PGS, VobSub) are not text */
        }
        char name[64], path[2048];
        snprintf(name, sizeof name, "s%02u.%s", i, ext);
        snprintf(path, sizeof path, "%s/%s", subs_dir, name);
        AVFormatContext *soc = NULL;
        if (avformat_alloc_output_context2(&soc, NULL, fmt, path) < 0 || !soc) continue;
        AVStream *os = avformat_new_stream(soc, NULL);
        if (!os || avcodec_parameters_copy(os->codecpar, st->codecpar) < 0 ||
            avio_open(&soc->pb, path, AVIO_FLAG_WRITE) < 0) {
            avformat_free_context(soc);
            continue;
        }
        os->codecpar->codec_tag = 0;
        os->time_base = st->time_base;
        if (avformat_write_header(soc, NULL) < 0) {
            avio_closep(&soc->pb);
            avformat_free_context(soc);
            remove(path);
            continue;
        }
        AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", NULL, 0);
        AVDictionaryEntry *title = av_dict_get(st->metadata, "title", NULL, 0);
        char l[64], t[256];
        clean_field(l, sizeof l, lang ? lang->value : "");
        clean_field(t, sizeof t, title ? title->value : "");
        fprintf(idx, "%s\t%s\t%s\n", name, l, t);
        c->sub_slot[i] = c->nsubs;
        c->soc[c->nsubs++] = soc;
    }
    fclose(idx);
}

/* ---------- main ---------- */

int kadr_convert(const char *in_path, const char *out_path, const char *subs_dir,
                 const volatile int *cancel, KadrProgressFn progress, void *ctx,
                 char *err, int err_len) {
    Conv conv;
    memset(&conv, 0, sizeof conv);
    Conv *c = &conv;
    c->err = err;
    c->err_len = err_len;
    if (err && err_len > 0) err[0] = 0;
    c->vi = c->ai = -1;
    int ret = 0, mode = 0, header_done = 0;
    AVPacket *pkt = NULL;

    av_log_set_level(AV_LOG_ERROR);

    if ((ret = avformat_open_input(&c->ic, in_path, NULL, NULL)) < 0) { seterr(c, "לא הצלחתי לפתוח את הקובץ", av_err2str(ret)); goto end; }
    if ((ret = avformat_find_stream_info(c->ic, NULL)) < 0) { seterr(c, "לא הצלחתי לקרוא את מבנה הקובץ", av_err2str(ret)); goto end; }

    c->vi = av_find_best_stream(c->ic, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (c->vi >= 0 && (c->ic->streams[c->vi]->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
        c->vi = -1;   /* a cover picture is not the video */
        for (unsigned i = 0; i < c->ic->nb_streams; i++) {
            AVStream *s = c->ic->streams[i];
            if (s->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && !(s->disposition & AV_DISPOSITION_ATTACHED_PIC)) { c->vi = (int)i; break; }
        }
    }
    if (c->vi < 0) { seterr(c, "לא נמצא וידאו בקובץ", NULL); ret = AVERROR_STREAM_NOT_FOUND; goto end; }
    c->ai = av_find_best_stream(c->ic, AVMEDIA_TYPE_AUDIO, -1, c->vi, NULL, 0);

    c->sub_slot = av_malloc_array(c->ic->nb_streams, sizeof(int));
    if (!c->sub_slot) { ret = AVERROR(ENOMEM); goto end; }
    for (unsigned i = 0; i < c->ic->nb_streams; i++) c->sub_slot[i] = -1;

    if ((ret = avformat_alloc_output_context2(&c->oc, NULL, "mp4", out_path)) < 0 || !c->oc) {
        seterr(c, "לא הצלחתי ליצור קובץ פלט", NULL); if (ret >= 0) ret = AVERROR(ENOMEM); goto end;
    }

    /* video */
    c->vin = c->ic->streams[c->vi];
    c->vcopy = video_can_copy(c->vin->codecpar);
    if (c->vcopy) {
        c->vout = avformat_new_stream(c->oc, NULL);
        if (!c->vout) { ret = AVERROR(ENOMEM); goto end; }
        avcodec_parameters_copy(c->vout->codecpar, c->vin->codecpar);
        c->vout->codecpar->codec_tag =
            c->vin->codecpar->codec_id == AV_CODEC_ID_HEVC ? MKTAG('h', 'v', 'c', '1') : 0;
        c->vout->time_base = c->vin->time_base;
        c->vout->avg_frame_rate = c->vin->avg_frame_rate;
    } else {
        if ((ret = open_video_transcode(c)) < 0) goto end;
        mode |= 1;
    }

    /* audio: if it can't be set up, the video still converts without sound */
    if (c->ai >= 0) {
        c->ain = c->ic->streams[c->ai];
        c->acopy = audio_can_copy(c->ain->codecpar);
        if (c->acopy) {
            c->aout = avformat_new_stream(c->oc, NULL);
            if (!c->aout) { ret = AVERROR(ENOMEM); goto end; }
            avcodec_parameters_copy(c->aout->codecpar, c->ain->codecpar);
            c->aout->codecpar->codec_tag = 0;
            c->aout->time_base = c->ain->time_base;
            av_dict_copy(&c->aout->metadata, c->ain->metadata, 0);
        } else if (open_audio_transcode(c) < 0) {
            avcodec_free_context(&c->adec);
            avcodec_free_context(&c->aenc);
            c->ai = -1;
        } else {
            mode |= 2;
        }
    }

    open_subtitles(c, subs_dir);

    if ((ret = avio_open(&c->oc->pb, out_path, AVIO_FLAG_WRITE)) < 0) { seterr(c, "לא הצלחתי לכתוב את הקובץ", av_err2str(ret)); goto end; }
    if ((ret = avformat_write_header(c->oc, NULL)) < 0) { seterr(c, "לא הצלחתי להתחיל את קובץ ה-MP4", av_err2str(ret)); goto end; }
    header_done = 1;

    c->opkt = av_packet_alloc();
    pkt = av_packet_alloc();
    if (!c->opkt || !pkt) { ret = AVERROR(ENOMEM); goto end; }

    double total = c->ic->duration > 0 ? c->ic->duration / (double)AV_TIME_BASE : 0;
    double start = c->ic->start_time != AV_NOPTS_VALUE ? c->ic->start_time / (double)AV_TIME_BASE : 0;
    double last_report = -1;
    if (progress) progress(0, mode, ctx);

    while ((ret = av_read_frame(c->ic, pkt)) >= 0) {
        if (cancel && *cancel) { ret = KADR_CANCELLED; av_packet_unref(pkt); goto end; }
        int si = pkt->stream_index;
        AVStream *ist = c->ic->streams[si];

        if (progress && total > 0 && (si == c->vi || si == c->ai)) {
            int64_t ts = pkt->dts != AV_NOPTS_VALUE ? pkt->dts : pkt->pts;
            if (ts != AV_NOPTS_VALUE) {
                double frac = (ts * av_q2d(ist->time_base) - start) / total;
                if (frac < 0) frac = 0;
                if (frac > 0.999) frac = 0.999;
                if (frac - last_report >= 0.005) { last_report = frac; progress(frac, mode, ctx); }
            }
        }

        if (si == c->vi) {
            if (c->vcopy) {
                av_packet_rescale_ts(pkt, ist->time_base, c->vout->time_base);
                pkt->stream_index = c->vout->index;
                pkt->pos = -1;
                av_interleaved_write_frame(c->oc, pkt);
            } else if ((ret = decode_video(c, pkt)) < 0) {
                seterr(c, "המרת הווידאו נכשלה", av_err2str(ret)); av_packet_unref(pkt); goto end;
            }
        } else if (si == c->ai) {
            if (c->acopy) {
                av_packet_rescale_ts(pkt, ist->time_base, c->aout->time_base);
                pkt->stream_index = c->aout->index;
                pkt->pos = -1;
                av_interleaved_write_frame(c->oc, pkt);
            } else if (decode_audio(c, pkt) < 0) {
                /* keep going: a damaged audio packet should not stop the whole file */
            }
        } else if (c->sub_slot[si] >= 0) {
            AVFormatContext *soc = c->soc[c->sub_slot[si]];
            av_packet_rescale_ts(pkt, ist->time_base, soc->streams[0]->time_base);
            pkt->stream_index = 0;
            pkt->pos = -1;
            av_write_frame(soc, pkt);
        }
        av_packet_unref(pkt);
    }
    if (ret != AVERROR_EOF && ret < 0) { seterr(c, "קריאת הקובץ נעצרה באמצע", av_err2str(ret)); goto end; }
    ret = 0;

    /* flush */
    if (!c->vcopy) {
        decode_video(c, NULL);
        encode_video(c, NULL);
    }
    if (c->ai >= 0 && !c->acopy) {
        decode_audio(c, NULL);
        if (c->swr) push_samples(c, NULL, 0);
        drain_fifo(c, 1);
        avcodec_send_frame(c->aenc, NULL);
        write_encoded(c, c->aenc, c->aout);
    }
    if ((ret = av_write_trailer(c->oc)) < 0) { seterr(c, "לא הצלחתי לסיים את קובץ ה-MP4", av_err2str(ret)); goto end; }
    for (int i = 0; i < c->nsubs; i++) av_write_trailer(c->soc[i]);
    if (progress) progress(1, mode, ctx);

end:
    (void)header_done;
    av_packet_free(&pkt);
    av_packet_free(&c->opkt);
    for (int i = 0; i < c->nsubs; i++) {
        if (c->soc[i]->pb) avio_closep(&c->soc[i]->pb);
        avformat_free_context(c->soc[i]);
    }
    if (c->oc) {
        if (c->oc->pb) avio_closep(&c->oc->pb);
        avformat_free_context(c->oc);
    }
    avcodec_free_context(&c->vdec);
    avcodec_free_context(&c->venc);
    avcodec_free_context(&c->adec);
    avcodec_free_context(&c->aenc);
    sws_freeContext(c->sws);
    swr_free(&c->swr);
    if (c->fifo) av_audio_fifo_free(c->fifo);
    av_frame_free(&c->vframe);
    av_frame_free(&c->vscaled);
    av_frame_free(&c->aframe);
    av_freep(&c->sub_slot);
    avformat_close_input(&c->ic);
    if (ret == KADR_CANCELLED) return KADR_CANCELLED;
    if (ret < 0) {
        seterr(c, "ההמרה נכשלה", av_err2str(ret));
        return ret;
    }
    return 0;
}
