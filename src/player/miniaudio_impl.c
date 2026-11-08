/* The one translation unit that holds miniaudio's implementation.
 *
 * Only what a file player needs is compiled: WAV, FLAC and MP3 decoding and
 * device output. Backends are opened with dlopen at run time, so nothing but
 * libc is linked. Built with its own flags in build/apps.zig, apart from the
 * player's code (third-party code is not held to -Werror). */
#include "ma_config.h"
#define MINIAUDIO_IMPLEMENTATION
#include "../../third_party/miniaudio/miniaudio.h"
