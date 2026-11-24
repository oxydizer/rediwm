/* `c_av`: FFmpeg, VAAPI export and DRM device lookup for rediwm-video. */
#undef _FORTIFY_SOURCE
#define _GNU_SOURCE 1
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/hwcontext_vaapi.h>
#include <libavutil/imgutils.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
#include <va/va_drmcommon.h>
#include <xf86drm.h>
#include <drm_fourcc.h>
