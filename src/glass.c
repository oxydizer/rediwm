// CSS backdrop-filter for the compositor-owned glass surfaces. Capture only
// the scene prefix behind each surface, then blur on the GPU. No readback.
// The wlroots scene ABI is deliberately pinned to 0.20 by build.zig.zon.
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <assert.h>
#include <drm_fourcc.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <wlr/render/allocator.h>
#include <wlr/render/egl.h>
#include <wlr/render/gles2.h>
#include <wlr/render/pass.h>
#include <wlr/render/wlr_texture.h>
#include <wlr/types/wlr_buffer.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/util/log.h>
#include <wlr/util/transform.h>
#include "explicit_sync.h"
#include "projection.h"

enum glass_kind { GLASS_TITLEBAR, GLASS_TASKBAR, GLASS_PANEL };
struct glass_engine;
struct glass_effect {
	struct glass_engine *engine;
	struct wl_list link;
	struct wlr_scene_buffer *node, *target;
    struct wlr_scene_buffer *projected_node, *projected_target;
    float zoom;
	struct wl_listener destroy, target_destroy;
	struct wl_list dependencies;
	enum glass_kind kind;
	float radius, opacity;
	uint64_t hash, revision;
	bool valid;
	// Logical size and scale of the current output buffer.
	int width, height;
	float scale;
	struct wlr_buffer *capture, *output[2];
	struct wlr_texture *capture_texture;
	GLuint intermediate[2], intermediate_fbo[2];
	int intermediate_width, intermediate_height;
};
struct glass_engine {
	struct wlr_renderer *renderer;
	struct wlr_allocator *allocator;
	struct wlr_scene *scene;
	// Release points for explicit-sync clients read by backdrop captures.
	struct rediwm_read_fence *read_fence;
	struct wl_list effects;
	GLuint blur, finish, vertices;
	bool failed;
	bool warned;
	// A held effect keeps its last blur; releasing it forces one update.
	struct glass_effect *held;
	bool resync;
	// Camera motion holds every effect; dropping it forces one update.
	bool hold_all;
	struct wlr_box bounds;
};

// Each effect observes the source damage independently. Scene output damage is
// visibility-culled, but backdrop capture also samples beneath opaque windows.
// Keep all commits until this effect next examines the source, including while
// its blur is held or it is outside the outputs.
struct glass_dependency {
	struct wl_list link;
	struct glass_effect *effect;
	struct wlr_scene_buffer *node;
	struct wlr_surface *surface;
	struct wl_listener commit, node_destroy, surface_destroy;
	pixman_region32_t damage;
	int width, height;
	bool full_damage, seen;
	uint64_t revision;
};

static void dependency_destroy(struct glass_dependency *dependency)
{
	wl_list_remove(&dependency->commit.link);
	wl_list_remove(&dependency->node_destroy.link);
	wl_list_remove(&dependency->surface_destroy.link);
	wl_list_remove(&dependency->link);
	pixman_region32_fini(&dependency->damage);
	free(dependency);
}
static void dependency_schedule(struct glass_dependency *dependency)
{
	dependency->effect->engine->resync = true;
	struct wlr_scene_output *out;
	wl_list_for_each(out, &dependency->effect->engine->scene->outputs, link)
		wlr_output_schedule_frame(out->output);
}
static void dependency_node_destroy(struct wl_listener *listener, void *data)
{
	(void)data;
	struct glass_dependency *dependency = wl_container_of(listener, dependency, node_destroy);
	dependency_schedule(dependency);
	dependency_destroy(dependency);
}
static void dependency_surface_destroy(struct wl_listener *listener, void *data)
{
	(void)data;
	struct glass_dependency *dependency = wl_container_of(listener, dependency, surface_destroy);
	dependency_schedule(dependency);
	dependency_destroy(dependency);
}
static void dependency_commit(struct wl_listener *listener, void *data)
{
	(void)data;
	struct glass_dependency *dependency = wl_container_of(listener, dependency, commit);
	const struct wlr_surface_state *state = &dependency->surface->current;
	if (state->buffer_width != dependency->width || state->buffer_height != dependency->height ||
	    rediwm_surface_state_remapped(state))
		dependency->full_damage = true;
	dependency->width = state->buffer_width;
	dependency->height = state->buffer_height;
	if (!dependency->full_damage &&
	    !pixman_region32_union(&dependency->damage, &dependency->damage,
				  &dependency->surface->buffer_damage))
		dependency->full_damage = true;
	if (dependency->full_damage || pixman_region32_not_empty(&dependency->damage))
		dependency_schedule(dependency);
}
static struct glass_dependency *dependency_get(struct glass_effect *effect,
		struct wlr_scene_buffer *node, struct wlr_surface *surface)
{
	struct glass_dependency *dependency;
	wl_list_for_each(dependency, &effect->dependencies, link)
		if (dependency->node == node) {
			dependency->seen = true;
			return dependency;
		}
	dependency = calloc(1, sizeof(*dependency));
	if (!dependency)
		return NULL;
	dependency->effect = effect;
	dependency->node = node;
	dependency->surface = surface;
	dependency->width = surface->current.buffer_width;
	dependency->height = surface->current.buffer_height;
	dependency->revision = 1;
	dependency->seen = true;
	pixman_region32_init(&dependency->damage);
	dependency->commit.notify = dependency_commit;
	dependency->node_destroy.notify = dependency_node_destroy;
	dependency->surface_destroy.notify = dependency_surface_destroy;
	wl_signal_add(&surface->events.commit, &dependency->commit);
	wl_signal_add(&surface->events.destroy, &dependency->surface_destroy);
	wl_signal_add(&node->node.events.destroy, &dependency->node_destroy);
	wl_list_insert(&effect->dependencies, &dependency->link);
	return dependency;
}

static void dependencies_begin(struct glass_effect *effect)
{
	struct glass_dependency *dependency;
	wl_list_for_each(dependency, &effect->dependencies, link)
		dependency->seen = false;
}
static void dependencies_prune(struct glass_effect *effect)
{
	struct glass_dependency *dependency, *next;
	wl_list_for_each_safe(dependency, next, &effect->dependencies, link)
		if (!dependency->seen)
			dependency_destroy(dependency);
}

static uint64_t dependency_revision(struct glass_dependency *dependency,
		const struct wlr_box *bounds, const struct wlr_box *intersection,
		double capture_pixel_width, double capture_pixel_height)
{
	struct wlr_scene_buffer *node = dependency->node;
	bool changed = dependency->full_damage;
	if (pixman_region32_not_empty(&dependency->damage)) {
		// Non-normal transforms remain conservative until their texture mapping
		// is supported here. Buffer scale and viewporter cropping are represented
		// by the scene's source box and destination dimensions.
		if (node->transform != WL_OUTPUT_TRANSFORM_NORMAL || bounds->width <= 0 || bounds->height <= 0) {
			changed = true;
		} else {
			struct wlr_fbox src = node->src_box;
			if (wlr_fbox_empty(&src))
				src = (struct wlr_fbox){0, 0, dependency->width, dependency->height};
			double sx = src.width / bounds->width, sy = src.height / bounds->height;
			// The quarter-size destination is rounded and bilinearly sampled.
			// Include one capture pixel plus one source texel on each edge.
			double pad_x = capture_pixel_width * sx + 1, pad_y = capture_pixel_height * sy + 1;
			pixman_box32_t sample = {
				.x1 = floor(src.x + (intersection->x - bounds->x) * sx - pad_x),
				.y1 = floor(src.y + (intersection->y - bounds->y) * sy - pad_y),
				.x2 = ceil(src.x + (intersection->x + intersection->width - bounds->x) * sx + pad_x),
				.y2 = ceil(src.y + (intersection->y + intersection->height - bounds->y) * sy + pad_y),
			};
			changed |= pixman_region32_contains_rectangle(&dependency->damage, &sample) != PIXMAN_REGION_OUT;
		}
	}
	if (changed)
		dependency->revision++;
	dependency->full_damage = false;
	pixman_region32_clear(&dependency->damage);
	return dependency->revision;
}

// Save both EGL and the GL state touched here. All custom GL work happens
// outside a wlroots render pass, in the renderer's own context.
struct gl_context {
	EGLDisplay display, previous_display;
	EGLContext previous_context;
	EGLSurface draw, read;
	GLint fbo, program, array_buffer, active_texture, texture, alpha_texture, viewport[4];
	GLint attr_enabled, attr_size, attr_type, attr_normalized, attr_stride, attr_buffer;
	void *attr_pointer;
	GLboolean blend, scissor;
};
static bool enter(struct glass_engine *engine, struct gl_context *state)
{
	struct wlr_egl *egl = wlr_gles2_renderer_get_egl(engine->renderer);
	state->display = wlr_egl_get_display(egl);
	state->previous_display = eglGetCurrentDisplay();
	state->previous_context = eglGetCurrentContext();
	state->draw = eglGetCurrentSurface(EGL_DRAW);
	state->read = eglGetCurrentSurface(EGL_READ);
	if (!eglMakeCurrent(state->display, EGL_NO_SURFACE, EGL_NO_SURFACE,
			    wlr_egl_get_context(egl)))
		return false;
	glGetIntegerv(GL_FRAMEBUFFER_BINDING, &state->fbo);
	glGetIntegerv(GL_CURRENT_PROGRAM, &state->program);
	glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &state->array_buffer);
	glGetIntegerv(GL_ACTIVE_TEXTURE, &state->active_texture);
	glActiveTexture(GL_TEXTURE1);
	glGetIntegerv(GL_TEXTURE_BINDING_2D, &state->alpha_texture);
	glActiveTexture(GL_TEXTURE0);
	glGetIntegerv(GL_TEXTURE_BINDING_2D, &state->texture);
	glGetIntegerv(GL_VIEWPORT, state->viewport);
	state->blend = glIsEnabled(GL_BLEND);
	state->scissor = glIsEnabled(GL_SCISSOR_TEST);
	glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &state->attr_enabled);
	glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_SIZE, &state->attr_size);
	glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_TYPE, &state->attr_type);
	glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &state->attr_normalized);
	glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &state->attr_stride);
	glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &state->attr_buffer);
	glGetVertexAttribPointerv(0, GL_VERTEX_ATTRIB_ARRAY_POINTER, &state->attr_pointer);
	glDisable(GL_BLEND);
	glDisable(GL_SCISSOR_TEST);
	return true;
}
static void leave(struct gl_context *state)
{
	glBindFramebuffer(GL_FRAMEBUFFER, state->fbo);
	glUseProgram(state->program);
	glBindTexture(GL_TEXTURE_2D, state->texture);
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, state->alpha_texture);
	glActiveTexture(state->active_texture);
	glViewport(state->viewport[0], state->viewport[1], state->viewport[2], state->viewport[3]);
	if (state->blend)
		glEnable(GL_BLEND);
	else
		glDisable(GL_BLEND);
	if (state->scissor)
		glEnable(GL_SCISSOR_TEST);
	else
		glDisable(GL_SCISSOR_TEST);
	glBindBuffer(GL_ARRAY_BUFFER, state->attr_buffer);
	glVertexAttribPointer(0, state->attr_size, state->attr_type, state->attr_normalized,
			      state->attr_stride, state->attr_pointer);
	if (state->attr_enabled)
		glEnableVertexAttribArray(0);
	else
		glDisableVertexAttribArray(0);
	glBindBuffer(GL_ARRAY_BUFFER, state->array_buffer);
	if (state->previous_display != EGL_NO_DISPLAY) {
		eglMakeCurrent(state->previous_display, state->draw, state->read,
			       state->previous_context);
	} else {
		eglMakeCurrent(state->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	}
}

static const char vertex_source[] =
    "attribute vec2 position; varying vec2 uv;"
    "void main(){ uv=position*.5+.5; gl_Position=vec4(position,0.,1.); }";
// CSS blur length is Gaussian sigma. A 3-sigma kernel on a quarter-size
// capture keeps the filter inexpensive; geometry and corner AA stay native.
static const char blur_source[] =
    "precision highp float; varying vec2 uv; uniform sampler2D tex;"
    "uniform vec2 step_uv; uniform float sigma; uniform vec4 limits;"
    "void main(){ vec4 sum=vec4(0.); float weight=0.;"
    "for(int i=-24;i<=24;i++){ float x=float(i);"
    "float w=exp(-.5*x*x/(sigma*sigma));"
    "sum+=texture2D(tex,clamp(uv+x*step_uv,limits.xy,limits.zw))*w; weight+=w; }"
    "gl_FragColor=sum/weight; }";
static const char finish_source[] =
    "precision highp float; varying vec2 uv; uniform sampler2D tex, alpha_tex;"
    "uniform float has_alpha_tex, target_opacity;"
    "uniform vec2 capture_size, size; uniform float padding, radius, scale, saturation, opacity, "
    "top_only;"
    "void main(){ vec2 p=uv*size; vec2 at=(p+padding)/capture_size;"
    "vec3 rgb=texture2D(tex,at).rgb; float l=dot(rgb,vec3(.213,.715,.072));"
    "rgb=clamp(vec3(l)+(rgb-vec3(l))*saturation,0.,1.);"
    "vec2 frame=size; if(top_only>.5) frame.y+=2.*radius;"
    "vec2 q=abs(p-frame*.5)-(frame*.5-vec2(radius));"
    "float d=length(max(q,0.))+min(max(q.x,q.y),0.)-radius;"
    "float coverage=clamp(.5-d*scale,0.,1.)*opacity;"
    // Target pixels already contain their tint, text, coverage and panel fade.
    // Choose the backing alpha so the pair has exactly coverage*opacity,
    // avoiding double coverage on curved edges and a double fade on panels.
    "float front=texture2D(alpha_tex,uv).a*has_alpha_tex*target_opacity;"
    "float a=front>=.99999?0.:clamp((coverage-front)/(1.-front),0.,1.);"
    "gl_FragColor=vec4(rgb*a,a); }";

static GLuint shader(GLenum type, const char *source)
{
	GLuint id = glCreateShader(type);
	glShaderSource(id, 1, &source, NULL);
	glCompileShader(id);
	GLint ok;
	glGetShaderiv(id, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		char log[1024];
		glGetShaderInfoLog(id, sizeof(log), NULL, log);
		wlr_log(WLR_ERROR, "glass shader: %s", log);
		glDeleteShader(id);
		return 0;
	}
	return id;
}
static GLuint program(const char *fragment)
{
	GLuint vs = shader(GL_VERTEX_SHADER, vertex_source),
	       fs = shader(GL_FRAGMENT_SHADER, fragment);
	if (!vs || !fs) {
		glDeleteShader(vs);
		glDeleteShader(fs);
		return 0;
	}
	GLuint id = glCreateProgram();
	glAttachShader(id, vs);
	glAttachShader(id, fs);
	glBindAttribLocation(id, 0, "position");
	glLinkProgram(id);
	glDeleteShader(vs);
	glDeleteShader(fs);
	GLint ok;
	glGetProgramiv(id, GL_LINK_STATUS, &ok);
	if (!ok) {
		glDeleteProgram(id);
		return 0;
	}
	return id;
}

struct glass_engine *rediwm_glass_create(struct wlr_renderer *renderer,
					 struct wlr_allocator *allocator, struct wlr_scene *scene,
					 struct rediwm_read_fence *read_fence)
{
	if (!wlr_renderer_is_gles2(renderer)) {
		wlr_log(WLR_INFO, "glass: backdrop filters require GLES2; using CSS tints only");
		return NULL;
	}
	struct glass_engine *engine = calloc(1, sizeof(*engine));
	if (!engine)
		return NULL;
	engine->renderer = renderer;
	engine->allocator = allocator;
	engine->scene = scene;
	engine->read_fence = read_fence;
	wl_list_init(&engine->effects);
	struct gl_context state;
	if (!enter(engine, &state)) {
		free(engine);
		return NULL;
	}
	engine->blur = program(blur_source);
	engine->finish = program(finish_source);
	const GLfloat vertices[] = {-1, -1, 1, -1, -1, 1, 1, 1};
	glGenBuffers(1, &engine->vertices);
	glBindBuffer(GL_ARRAY_BUFFER, engine->vertices);
	glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
	engine->failed = !engine->blur || !engine->finish;
	leave(&state);
	return engine;
}

static void release_capture(struct glass_effect *effect)
{
	if (effect->capture_texture)
		wlr_texture_destroy(effect->capture_texture);
	if (effect->capture)
		wlr_buffer_drop(effect->capture);
	effect->capture_texture = NULL;
	effect->capture = NULL;
}
static void handle_destroy(struct wl_listener *listener, void *data)
{
	(void)data;
	struct glass_effect *effect = wl_container_of(listener, effect, destroy);
	if (effect->engine->held == effect)
		effect->engine->held = NULL;
	wl_list_remove(&effect->destroy.link);
	wl_list_remove(&effect->target_destroy.link);
	wl_list_remove(&effect->link);
	struct glass_dependency *dependency, *next;
	wl_list_for_each_safe(dependency, next, &effect->dependencies, link)
		dependency_destroy(dependency);
	release_capture(effect);
	for (int i = 0; i < 2; i++)
		if (effect->output[i])
			wlr_buffer_drop(effect->output[i]);
	struct gl_context state;
	if (enter(effect->engine, &state)) {
		glDeleteTextures(2, effect->intermediate);
		glDeleteFramebuffers(2, effect->intermediate_fbo);
		leave(&state);
	}
	free(effect);
}
static void handle_target_destroy(struct wl_listener *listener, void *data)
{
	(void)data;
	struct glass_effect *effect = wl_container_of(listener, effect, target_destroy);
	wlr_scene_node_destroy(&effect->node->node);
}
static bool accepts_input(struct wlr_scene_buffer *buffer, double *x, double *y)
{
	(void)buffer;
	(void)x;
	(void)y;
	return false;
}
struct glass_effect *rediwm_glass_attach(struct glass_engine *engine,
					 struct wlr_scene_buffer *target,
					 struct wlr_scene_node *before, enum glass_kind kind)
{
	if (!engine || engine->failed)
		return NULL;
	struct glass_effect *effect = calloc(1, sizeof(*effect));
	if (!effect)
		return NULL;
	effect->node = wlr_scene_buffer_create(target->node.parent, NULL);
	if (!effect->node) {
		free(effect);
		return NULL;
	}
	effect->engine = engine;
	wl_list_init(&effect->dependencies);
	effect->target = target;
	effect->kind = kind;
	effect->opacity = 1;
    effect->zoom = 1;
	effect->node->point_accepts_input = accepts_input;
	wlr_scene_buffer_set_filter_mode(effect->node, WLR_SCALE_FILTER_NEAREST);
	wlr_scene_node_place_below(&effect->node->node, before);
	effect->destroy.notify = handle_destroy;
	wl_signal_add(&effect->node->node.events.destroy, &effect->destroy);
	effect->target_destroy.notify = handle_target_destroy;
	wl_signal_add(&target->node.events.destroy, &effect->target_destroy);
	wl_list_insert(&engine->effects, &effect->link);
	return effect;
}
// Moving a nearly opaque surface would repaint its blur every frame for an
// imperceptible change. The caller decides opacity and schedules a frame on
// release; that frame refreshes the formerly held effect even without damage.
void rediwm_glass_hold(struct glass_engine *engine, struct glass_effect *effect)
{
	if (!engine || engine->held == effect)
		return;
	engine->held = effect;
	engine->resync = true;
}
void rediwm_glass_hold_all(struct glass_engine *engine, bool hold)
{
	if (!engine || engine->hold_all == hold)
		return;
	engine->hold_all = hold;
	engine->resync = true;
}
void rediwm_glass_configure(struct glass_effect *effect, float radius, float opacity)
{
	if (!effect)
		return;
	if (effect->radius != radius || effect->opacity != opacity)
		effect->valid = false;
	effect->radius = radius;
	effect->opacity = opacity;
}
void rediwm_glass_destroy(struct glass_engine *engine)
{
	if (!engine)
		return;
	struct glass_effect *effect, *tmp;
	wl_list_for_each_safe(effect, tmp, &engine->effects, link)
	    wlr_scene_node_destroy(&effect->node->node);
	struct gl_context state;
	if (enter(engine, &state)) {
		glDeleteProgram(engine->blur);
		glDeleteProgram(engine->finish);
		glDeleteBuffers(1, &engine->vertices);
		leave(&state);
	}
	free(engine);
}

static struct wlr_buffer *allocate(struct glass_engine *engine, int width, int height)
{
	// Implicit modifiers let GBM choose a renderable layout. Using all the
	// sampling modifiers can select a layout that cannot be a render target.
	uint64_t modifier = DRM_FORMAT_MOD_INVALID;
	struct wlr_drm_format format = {
	    .format = DRM_FORMAT_ARGB8888,
	    .len = 1,
	    .capacity = 1,
	    .modifiers = &modifier,
	};
	return wlr_allocator_create_buffer(engine->allocator, width, height, &format);
}
static struct glass_effect *effect_for(struct glass_engine *engine, struct wlr_scene_node *node)
{
	struct glass_effect *effect;
	wl_list_for_each(effect, &engine->effects,
			 link) if (&effect->node->node == node || (effect->projected_node && &effect->projected_node->node == node)) return effect;
	return NULL;
}
static void hash_bytes(uint64_t *hash, const void *data, size_t size)
{
	const uint8_t *p = data;
	for (size_t i = 0; i < size; i++) {
		*hash ^= p[i];
		*hash *= UINT64_C(1099511628211);
	}
}
#define HASH(h, value) hash_bytes(h, &(value), sizeof(value))
struct capture {
	struct glass_effect *effect;
	struct wlr_box box;
	int width, height;
	uint64_t hash;
	struct wlr_render_pass *pass;
	bool failed;
	// The prefix includes an explicit-sync client buffer; found while hashing.
	bool explicit_sync;
	struct wl_list textures;
};
struct temporary_texture {
	struct wl_list link;
	struct wlr_texture *texture;
};
static struct wlr_box destination(struct capture *capture, int x, int y, int w, int h)
{
	double sx = (double)capture->width / capture->box.width;
	double sy = (double)capture->height / capture->box.height;
	int left = lround((x - capture->box.x) * sx), top = lround((y - capture->box.y) * sy);
	return (struct wlr_box){left, top, lround((x + w - capture->box.x) * sx) - left,
				lround((y + h - capture->box.y) * sy) - top};
}

static void capture_buffer_hash(struct capture *capture, struct wlr_scene_buffer *buffer,
		struct wlr_surface *surface, const struct wlr_box *bounds,
		const struct wlr_box *intersection)
{
	struct glass_dependency *dependency = surface ?
		dependency_get(capture->effect, buffer, surface) : NULL;
	if (dependency) {
		uint64_t revision = dependency_revision(dependency, bounds, intersection,
			(double)capture->box.width / capture->width,
			(double)capture->box.height / capture->height);
		HASH(&capture->hash, revision);
		// Presence is a mapping change; rotating equally sized client buffers
		// with empty damage does not change the sampled content.
		struct wlr_client_buffer *client = buffer->buffer ? wlr_client_buffer_get(buffer->buffer) : NULL;
		bool present = buffer->private.is_single_pixel_buffer || buffer->private.texture ||
			(client && client->texture);
		HASH(&capture->hash, present);
		HASH(&capture->hash, buffer->private.buffer_is_opaque);
	} else {
		HASH(&capture->hash, buffer->buffer);
		HASH(&capture->hash, buffer->private.texture);
		// Allocation failure retains the conservative previous behavior.
		if (surface)
			HASH(&capture->hash, surface->current.seq);
	}
	HASH(&capture->hash, buffer->src_box);
	HASH(&capture->hash, buffer->filter_mode);
	HASH(&capture->hash, buffer->opacity);
	HASH(&capture->hash, buffer->transform);
	HASH(&capture->hash, buffer->transfer_function);
	HASH(&capture->hash, buffer->primaries);
	HASH(&capture->hash, buffer->color_encoding);
	HASH(&capture->hash, buffer->color_range);
	if (buffer->private.is_single_pixel_buffer)
		HASH(&capture->hash, buffer->private.single_pixel_buffer_color);
	struct glass_effect *previous = effect_for(capture->effect->engine, &buffer->node);
	if (previous)
		HASH(&capture->hash, previous->revision);
}

// Iterate in paint order, stopping BEFORE the glass and its own shadow.
// Do not use scene visibility: it culls opaque occluders, whereas the blur
// needs pixels outside the glass and underneath foreground windows too.
static bool capture_prefix(struct capture *capture, struct wlr_scene_node *node, int x, int y)
{
	if (node == &capture->effect->node->node)
		return true;
	if (!node->enabled)
		return false;
	x += node->x;
	y += node->y;
	if (node->type == WLR_SCENE_NODE_TREE) {
		struct wlr_scene_tree *tree = wlr_scene_tree_from_node(node);
		struct wlr_scene_node *child;
		wl_list_for_each(child, &tree->children, link)
		{
			if (capture_prefix(capture, child, x, y))
				return true;
		}
		return false;
	}
	int width, height;
	struct wlr_scene_buffer *buffer = NULL;
	struct wlr_scene_rect *rect = NULL;
	if (node->type == WLR_SCENE_NODE_RECT) {
		rect = wlr_scene_rect_from_node(node);
		width = rect->width;
		height = rect->height;
	} else {
		buffer = wlr_scene_buffer_from_node(node);
		width = buffer->dst_width;
		height = buffer->dst_height;
		if (!width || !height) {
			width = buffer->private.buffer_width;
			height = buffer->private.buffer_height;
			if (buffer->transform & 1) {
				int tmp = width;
				width = height;
				height = tmp;
			}
		}
	}
	struct wlr_box bounds = {x, y, width, height}, intersection;
	if (!wlr_box_intersection(&intersection, &bounds, &capture->box))
		return false;
	HASH(&capture->hash, node);
	HASH(&capture->hash, bounds);
	struct wlr_box dst = destination(capture, x, y, width, height);
	if (dst.width <= 0 || dst.height <= 0)
		return false;
	if (rect) {
		HASH(&capture->hash, rect->color);
		if (capture->pass)
			wlr_render_pass_add_rect(capture->pass,
						 &(struct wlr_render_rect_options){
						     .box = dst,
						     .color = {rect->color[0], rect->color[1],
							       rect->color[2], rect->color[3]},
						 });
		return false;
	}
	struct wlr_scene_node *source = rediwm_projection_source(&buffer->node);
	struct wlr_scene_surface *surface = wlr_scene_surface_try_from_buffer(wlr_scene_buffer_from_node(source));
	capture_buffer_hash(capture, buffer, surface ? surface->surface : NULL, &bounds, &intersection);
	if (surface && rediwm_surface_explicit_sync(surface->surface)) {
		capture->explicit_sync = true;
		rediwm_read_fence_note(capture->effect->engine->read_fence, surface->surface);
	}
	if (!capture->pass)
		return false;
	if (buffer->private.is_single_pixel_buffer) {
		const uint32_t *c = buffer->private.single_pixel_buffer_color;
		double alpha = (double)c[3] / UINT32_MAX * buffer->opacity;
		wlr_render_pass_add_rect(
		    capture->pass,
		    &(struct wlr_render_rect_options){
			.box = dst,
			.color = {(double)c[0] / UINT32_MAX * buffer->opacity,
				  (double)c[1] / UINT32_MAX * buffer->opacity,
				  (double)c[2] / UINT32_MAX * buffer->opacity, alpha},
		    });
		return false;
	}
	struct wlr_texture *texture = buffer->private.texture;
	// wlr_scene keeps a surface's texture on its client buffer, never in
	// private.texture. Re-importing it would upload a whole shm window, or
	// create an EGLImage for each new dmabuf, on every glass repaint. A
	// client buffer without a texture is not drawn by the scene either.
	struct wlr_client_buffer *client_buffer =
	    buffer->buffer ? wlr_client_buffer_get(buffer->buffer) : NULL;
	if (!texture && client_buffer)
		texture = client_buffer->texture;
	else if (!texture && buffer->buffer) {
		// Imports live until submit, including on deferred renderer backends.
		struct temporary_texture *temp = calloc(1, sizeof(*temp));
		if (!temp) {
			capture->failed = true;
			return false;
		}
		temp->texture =
		    wlr_texture_from_buffer(capture->effect->engine->renderer, buffer->buffer);
		if (!temp->texture) {
			free(temp);
			capture->failed = true;
			return false;
		}
		texture = temp->texture;
		wl_list_insert(&capture->textures, &temp->link);
	}
	if (!texture)
		return false;
	struct wlr_color_primaries primaries;
	wlr_color_primaries_from_named(
	    &primaries, buffer->primaries ? buffer->primaries : WLR_COLOR_NAMED_PRIMARIES_SRGB);
	wlr_render_pass_add_texture(capture->pass,
				    &(struct wlr_render_texture_options){
					.texture = texture,
					.src_box = buffer->src_box,
					.dst_box = dst,
					.alpha = &buffer->opacity,
					.transform = wlr_output_transform_invert(buffer->transform),
					.filter_mode = WLR_SCALE_FILTER_BILINEAR,
					.transfer_function = buffer->transfer_function,
					.primaries = &primaries,
					.color_encoding = buffer->color_encoding,
					.color_range = buffer->color_range,
					.wait_timeline = buffer->private.wait_timeline,
					.wait_point = buffer->private.wait_point,
				    });
	return false;
}

static void uniform1(GLuint program_id, const char *name, float value)
{
	glUniform1f(glGetUniformLocation(program_id, name), value);
}
static void uniform2(GLuint program_id, const char *name, float x, float y)
{
	glUniform2f(glGetUniformLocation(program_id, name), x, y);
}
static void draw_setup(struct glass_engine *engine, GLuint program_id, GLuint texture, GLuint fbo,
		       int w, int h)
{
	glBindFramebuffer(GL_FRAMEBUFFER, fbo);
	glViewport(0, 0, w, h);
	glUseProgram(program_id);
	glBindTexture(GL_TEXTURE_2D, texture);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	glUniform1i(glGetUniformLocation(program_id, "tex"), 0);
	glBindBuffer(GL_ARRAY_BUFFER, engine->vertices);
	glEnableVertexAttribArray(0);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
}

static bool render_effect(struct glass_effect *effect, struct capture *capture, int width,
			  int height, int padding, float sigma, float saturation, float scale)
{
	struct glass_engine *engine = effect->engine;
	if (!effect->capture || effect->capture->width != capture->width ||
	    effect->capture->height != capture->height) {
		release_capture(effect);
		effect->capture = allocate(engine, capture->width, capture->height);
		if (!effect->capture)
			return false;
		effect->capture_texture =
		    wlr_texture_from_buffer(engine->renderer, effect->capture);
		if (!effect->capture_texture) {
			release_capture(effect);
			return false;
		}
	}
	// The scene registers release points only for what outputs draw, and this
	// also samples beneath opaque windows.
	struct wlr_buffer_pass_options options = {0};
	if (capture->explicit_sync)
		rediwm_read_fence_begin(engine->read_fence, &options);
	capture->pass = wlr_renderer_begin_buffer_pass(engine->renderer, effect->capture, &options);
	if (!capture->pass) {
		rediwm_read_fence_end(engine->read_fence, false);
		return false;
	}
	wl_list_init(&capture->textures);
	wlr_render_pass_add_rect(capture->pass, &(struct wlr_render_rect_options){
						    .box = {0, 0, capture->width, capture->height},
						    .color = {0, 0, 0, 1},
						    .blend_mode = WLR_RENDER_BLEND_MODE_NONE,
						});
	capture_prefix(capture, &engine->scene->tree.node, 0, 0);
	bool ok = wlr_render_pass_submit(capture->pass);
	rediwm_read_fence_end(engine->read_fence, ok);
	struct temporary_texture *temp, *tmp;
	wl_list_for_each_safe(temp, tmp, &capture->textures, link)
	{
		wlr_texture_destroy(temp->texture);
		wl_list_remove(&temp->link);
		free(temp);
	}
	if (!ok || capture->failed)
		return false;
	int dw = lround(width * scale), dh = lround(height * scale);
	int slot = effect->output[0] && effect->output[0]->n_locks ? 1 : 0;
	struct wlr_buffer *out = effect->output[slot];
	if (out && (out->width != dw || out->height != dh || out->n_locks)) {
		wlr_buffer_drop(out);
		effect->output[slot] = out = NULL;
	}
	if (!out)
		effect->output[slot] = out = allocate(engine, dw, dh);
	if (!out)
		return false;
	struct wlr_texture *alpha_texture = effect->target->private.texture;
	bool own_alpha = false;
	if (!alpha_texture && effect->target->buffer) {
		alpha_texture = wlr_texture_from_buffer(engine->renderer, effect->target->buffer);
		if (!alpha_texture)
			return false;
		own_alpha = true;
	}
	struct gl_context state;
	if (!enter(engine, &state)) {
		if (own_alpha)
			wlr_texture_destroy(alpha_texture);
		return false;
	}
	GLuint output_fbo = wlr_gles2_renderer_get_buffer_fbo(engine->renderer, out);
	struct wlr_gles2_texture_attribs attribs;
	GLint alpha_min = GL_NEAREST, alpha_mag = GL_NEAREST;
	GLuint alpha_id = 0;
	wlr_gles2_texture_get_attribs(effect->capture_texture, &attribs);
	if (!output_fbo || attribs.target != GL_TEXTURE_2D) {
		ok = false;
		goto done;
	}
	if (!effect->intermediate[0]) {
		glGenTextures(2, effect->intermediate);
		glGenFramebuffers(2, effect->intermediate_fbo);
	}
	for (int i = 0; i < 2; i++) {
		glBindTexture(GL_TEXTURE_2D, effect->intermediate[i]);
		if (effect->intermediate_width != capture->width ||
		    effect->intermediate_height != capture->height) {
			glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, capture->width, capture->height, 0,
				     GL_RGBA, GL_UNSIGNED_BYTE, NULL);
		}
		glBindFramebuffer(GL_FRAMEBUFFER, effect->intermediate_fbo[i]);
		glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
				       effect->intermediate[i], 0);
		if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
			ok = false;
			goto done;
		}
		draw_setup(engine, engine->blur, i ? effect->intermediate[0] : attribs.tex,
			   effect->intermediate_fbo[i], capture->width, capture->height);
		uniform2(engine->blur, "step_uv", i ? 0 : 1.f / capture->width,
			 i ? 1.f / capture->height : 0);
		uniform1(engine->blur, "sigma",
			 sigma * (i ? (float)capture->height / capture->box.height
				    : (float)capture->width / capture->box.width));
		// Duplicate the root backdrop's edge pixels, as CSS filters do, so
		// the taskbar does not mix black from below the output into its glass.
		struct wlr_box root = engine->bounds;
		if (wlr_box_empty(&root))
			root = capture->box;
		float left = fmaxf(.5f / capture->width,
				   (float)(root.x - capture->box.x) / capture->box.width +
				       .5f / capture->width);
		float top = fmaxf(.5f / capture->height,
				  (float)(root.y - capture->box.y) / capture->box.height +
				      .5f / capture->height);
		float right =
		    fminf(1 - .5f / capture->width,
			  (float)(root.x + root.width - capture->box.x) / capture->box.width -
			      .5f / capture->width);
		float bottom =
		    fminf(1 - .5f / capture->height,
			  (float)(root.y + root.height - capture->box.y) / capture->box.height -
			      .5f / capture->height);
		glUniform4f(glGetUniformLocation(engine->blur, "limits"), left, top,
			    fmaxf(left, right), fmaxf(top, bottom));
		glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	}
	effect->intermediate_width = capture->width;
	effect->intermediate_height = capture->height;
	draw_setup(engine, engine->finish, effect->intermediate[1], output_fbo, dw, dh);
	struct wlr_gles2_texture_attribs alpha_attribs = {.target = GL_TEXTURE_2D,
							  .tex = effect->intermediate[1]};
	if (alpha_texture)
		wlr_gles2_texture_get_attribs(alpha_texture, &alpha_attribs);
	if (alpha_attribs.target != GL_TEXTURE_2D) {
		ok = false;
		goto done;
	}
	glActiveTexture(GL_TEXTURE1);
	glBindTexture(GL_TEXTURE_2D, alpha_attribs.tex);
	alpha_id = alpha_attribs.tex;
	glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, &alpha_min);
	glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, &alpha_mag);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	glUniform1i(glGetUniformLocation(engine->finish, "alpha_tex"), 1);
	uniform1(engine->finish, "has_alpha_tex", alpha_texture != NULL);
	uniform1(engine->finish, "target_opacity", effect->target->opacity);
	glActiveTexture(GL_TEXTURE0);
	uniform2(engine->finish, "capture_size", capture->box.width, capture->box.height);
	uniform2(engine->finish, "size", width, height);
	uniform1(engine->finish, "padding", padding);
	uniform1(engine->finish, "radius", fminf(effect->radius, fminf(width, height) / 2));
	uniform1(engine->finish, "scale", scale);
	uniform1(engine->finish, "saturation", saturation);
	uniform1(engine->finish, "opacity", effect->opacity);
	uniform1(engine->finish, "top_only", effect->kind == GLASS_TITLEBAR);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	glFlush();
	ok = glGetError() == GL_NO_ERROR;
done:
	if (alpha_id) {
		glActiveTexture(GL_TEXTURE1);
		glBindTexture(GL_TEXTURE_2D, alpha_id);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, alpha_min);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, alpha_mag);
		glActiveTexture(GL_TEXTURE0);
	}
	leave(&state);
	if (own_alpha)
		wlr_texture_destroy(alpha_texture);
	if (!ok)
		return false;
	wlr_scene_buffer_set_buffer(effect->node, out);
	wlr_scene_buffer_set_dest_size(effect->node, width, height);
	effect->width = width;
	effect->height = height;
	effect->scale = scale;
	effect->revision++;
	return true;
}

static void update_effect_inner(struct glass_effect *effect, float scale)
{
	struct wlr_scene_buffer *target = effect->target;
	int x = 0, y = 0;
	bool visible = wlr_scene_node_coords(&target->node, &x, &y) && target->dst_width > 0 &&
		       target->dst_height > 0;
	struct wlr_box target_box = {x, y, target->dst_width, target->dst_height}, intersection;
	if (visible && !wlr_box_empty(&effect->engine->bounds))
		visible = wlr_box_intersection(&intersection, &target_box, &effect->engine->bounds);
	wlr_scene_node_set_enabled(&effect->node->node, visible);
	if (!visible)
		return;
	wlr_scene_node_set_position(&effect->node->node, target->node.x, target->node.y);
	// The held blur travels with its target. Skip even the hash walk, but
	// never show a buffer rendered for a different size or scale.
	if ((effect == effect->engine->held || effect->engine->hold_all) && effect->valid &&
	    effect->width == target->dst_width && effect->height == target->dst_height &&
	    effect->scale == scale)
		return;
	float sigma = (effect->kind == GLASS_TITLEBAR ? 22 : effect->kind == GLASS_TASKBAR ? 24 : 26) * effect->zoom;
	float saturation = effect->kind == GLASS_PANEL ? 1.6f : 1.5f;
	int padding = ceilf(3 * sigma), width = target->dst_width, height = target->dst_height;
	struct capture capture = {
	    .effect = effect,
	    .box = {x - padding, y - padding, width + 2 * padding, height + 2 * padding},
	    .width = (width + 2 * padding + 3) / 4,
	    .height = (height + 2 * padding + 3) / 4,
	    .hash = UINT64_C(14695981039346656037),
	};
	HASH(&capture.hash, capture.box);
	HASH(&capture.hash, scale);
	HASH(&capture.hash, effect->radius);
	HASH(&capture.hash, effect->opacity);
	HASH(&capture.hash, effect->engine->bounds);
	HASH(&capture.hash, target->buffer);
	HASH(&capture.hash, target->private.texture);
	HASH(&capture.hash, target->opacity);
	dependencies_begin(effect);
	capture_prefix(&capture, &effect->engine->scene->tree.node, 0, 0);
	dependencies_prune(effect);
	uint64_t hash = capture.hash;
	if (effect->valid && effect->hash == hash)
		return;
	if (render_effect(effect, &capture, width, height, padding, sigma, saturation, scale)) {
		effect->hash = hash;
		effect->valid = true;
	} else {
		wlr_scene_buffer_set_buffer(effect->node, NULL);
		effect->valid = false;
		if (!effect->engine->warned)
			wlr_log(WLR_ERROR, "glass: backdrop render failed; using CSS tint");
		effect->engine->warned = true;
	}
}
// Source glass is skipped with the disabled world. Render the same effect into
// its presentation leaf, using projected bounds and world-scaled blur geometry.
static void update_effect(struct glass_effect *effect, float scale) {
    struct wlr_scene_buffer *node = effect->node, *target = effect->target;
    float radius = effect->radius;
    if (effect->projected_node && effect->projected_target) {
        effect->node = effect->projected_node;
        effect->target = effect->projected_target;
        effect->radius *= effect->zoom;
    }
    update_effect_inner(effect, scale);
    effect->node = node; effect->target = target; effect->radius = radius;
}
bool rediwm_glass_is_effect_node(struct wlr_scene_node *node) {
    return node->type == WLR_SCENE_NODE_BUFFER &&
        wlr_scene_buffer_from_node(node)->point_accepts_input == accepts_input;
}
void rediwm_glass_project(struct glass_engine *engine, struct rediwm_projection *p, float zoom) {
    (void)zoom;
    if (!engine) return;
    struct glass_effect *effect;
    wl_list_for_each(effect, &engine->effects, link) {
        struct wlr_scene_node *node = rediwm_projection_node(p, &effect->node->node);
        struct wlr_scene_node *target = rediwm_projection_node(p, &effect->target->node);
        effect->projected_node = node ? wlr_scene_buffer_from_node(node) : NULL;
        effect->projected_target = target ? wlr_scene_buffer_from_node(target) : NULL;
        effect->zoom = node ? rediwm_projection_node_zoom(node) : 1;
    }
}
static void update_tree(struct glass_engine *engine, struct wlr_scene_tree *tree, float scale)
{
	struct wlr_scene_node *node;
	wl_list_for_each(node, &tree->children, link)
	{
		struct glass_effect *effect = effect_for(engine, node);
		if (effect)
			update_effect(effect, scale);
		else if (node->enabled && node->type == WLR_SCENE_NODE_TREE)
			update_tree(engine, wlr_scene_tree_from_node(node), scale);
	}
}
void rediwm_glass_update(struct glass_engine *engine, struct wlr_scene_output *output, float scale)
{
	if (!engine || engine->failed)
		return;
	if (!engine->resync && !pixman_region32_not_empty(&output->damage_ring.current))
		return;
	engine->resync = false;
	engine->bounds = (struct wlr_box){0};
	struct wlr_scene_output *scene_output;
	wl_list_for_each(scene_output, &engine->scene->outputs, link)
	{
		int width, height;
		wlr_output_effective_resolution(scene_output->output, &width, &height);
		struct wlr_box box = {scene_output->x, scene_output->y, width, height};
		if (wlr_box_empty(&engine->bounds))
			engine->bounds = box;
		else {
			int x = engine->bounds.x < box.x ? engine->bounds.x : box.x;
			int y = engine->bounds.y < box.y ? engine->bounds.y : box.y;
			int right = engine->bounds.x + engine->bounds.width > box.x + box.width
					? engine->bounds.x + engine->bounds.width
					: box.x + box.width;
			int bottom = engine->bounds.y + engine->bounds.height > box.y + box.height
					 ? engine->bounds.y + engine->bounds.height
					 : box.y + box.height;
			engine->bounds = (struct wlr_box){x, y, right - x, bottom - y};
		}
	}
	update_tree(engine, &engine->scene->tree, scale);
}
