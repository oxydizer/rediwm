// SDR captures of outputs that blend in linear light.
//
// wlroots' screencopy frames and ext-image-copy-capture output sources copy
// the buffer an output commits, which on an HDR output holds PQ in 10 bits.
// For any output whose frames come from the linear pass, this hands them an
// sRGB encode of that pass's FP16 image instead (rediwm_scene_output_sdr_copy),
// the same frame as SDR. Elsewhere nothing changes: wlroots copies as before.
#pragma once
#include <stdbool.h>

struct rediwm_capture_sdr;
struct rediwm_output_renderer;
struct rediwm_scene_outputs;
struct wlr_ext_image_capture_source_v1;
struct wlr_screencopy_frame_v1;
struct wlr_output;

// One per compositor (the screencopy hook has no other way to find it).
struct rediwm_capture_sdr *rediwm_capture_sdr_create(struct rediwm_output_renderer *, struct rediwm_scene_outputs *);
void rediwm_capture_sdr_destroy(struct rediwm_capture_sdr *);

// Copies of a wlroots output source come from the SDR encode while its output
// is linear; the rest of its interface is wlroots'. A no-op for other sources
// and ones already wrapped. Wrapping hides the source from
// wlr_output_try_from_ext_image_capture_source_v1: ask the function below.
void rediwm_capture_sdr_wrap_source(struct rediwm_capture_sdr *, struct wlr_ext_image_capture_source_v1 *);
// The output a source captures, wrapped or not; NULL for other sources.
struct wlr_output *rediwm_capture_sdr_source_output(struct rediwm_capture_sdr *, struct wlr_ext_image_capture_source_v1 *);

// A screencopy frame whose copy is requested is completed from the SDR encode at
// a linear output's commit. wlroots handles damage, completion and releases.
// Also track negotiated 10-bit shm so a mode change can invalidate the request.
void rediwm_capture_sdr_take_screencopy(struct rediwm_capture_sdr *, struct wlr_screencopy_frame_v1 *, bool linear_wanted);
