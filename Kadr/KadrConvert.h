#ifndef KADR_CONVERT_H
#define KADR_CONVERT_H

/// mode bits reported with progress: 1 = video is re-encoded, 2 = audio is re-encoded.
typedef void (*KadrProgressFn)(double fraction, int mode, void *ctx);

static const int KADR_CANCELLED = -1000;
/// flags: always re-encode the audio (used when the copied audio turns out unplayable).
static const int KADR_FORCE_AUDIO = 1;

/// Converts any FFmpeg-readable video into an MP4 the iPhone can play.
/// H.264 (8-bit 4:2:0) and HEVC video is copied as-is; anything else is re-encoded
/// to H.264. AAC/MP3/ALAC/Opus/FLAC/AC-3/E-AC-3 audio is copied (unless flags has
/// KADR_FORCE_AUDIO); anything else becomes stereo AAC.
/// Text subtitles (ASS, SRT, WebVTT) are written to `subs_dir`, with an index in
/// `subs_dir/subs.tsv` (file \t language \t title per line).
/// Returns 0 on success, KADR_CANCELLED if *cancel became non-zero, or a negative
/// error with a Hebrew message in `err`.
int kadr_convert(const char *in_path, const char *out_path, const char *subs_dir,
                 int flags, const volatile int *cancel, KadrProgressFn progress, void *ctx,
                 char *err, int err_len);

#endif
