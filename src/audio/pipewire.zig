// Basic system audio control via libpulse — the PulseAudio-compatible
// client API PipeWire ships as a drop-in on every modern system (see
// `pkg-config libpulse`). `pa_threaded_mainloop` owns a real pthread of its
// own; there is no way to drive it from the compositor's `wl_event_loop`, so
// every public entry point here locks/unlocks around it instead.
//
// Two operation shapes, both load-bearing (verified against a live PipeWire
// session before writing this): a *query* (get_sink_info_list and friends)
// is issued, then the calling thread blocks in `pa_threaded_mainloop_wait`
// until the query's own `eol` callback calls `pa_threaded_mainloop_signal` —
// PA does not wake threaded-mainloop waiters on its own. A *command*
// (set_sink_volume_by_index, subscribe, ...) is fire-and-forget: issue it,
// unref the operation immediately, and never wait — waiting on a command
// whose callback is `null` hangs forever, since nothing will ever call
// `pa_threaded_mainloop_signal` for it.
//
// State-change notifications reach the compositor thread only through
// `generation` (bumped with `.monotonic` from the PA thread) plus a
// self-pipe (`wake_fd`) registered with the compositor's `wl.EventLoop` —
// never a direct call back into compositor code from PA's thread. Callers
// needing to read `sinks`/`sources`/`sink_inputs` must hold `lock()` for the
// duration of the read and copy out anything needed before `unlock()` —
// those lists are mutated in place, under the same lock, by PA's own thread.
//
// libpulse never revives a failed context, and the server goes away whenever
// pipewire-pulse restarts. A lost connection drops the device lists (the UI
// then shows no audio rather than stale levels) and connects a new context
// (`connectionLostLocked`, `reconnectCallback`); it waits for the server with
// `PA_CONTEXT_NOFAIL`, which watches org.pulseaudio.Server on D-Bus, so a
// missing server costs no wakeups.
const std = @import("std");
const Allocator = std.mem.Allocator;

const pa = @import("c_pulse");

const log = std.log.scoped(.audio);
const Bass = opaque {};
extern fn rediwm_bass_create(notify: *const fn (?*anyopaque) callconv(.c) void, data: ?*anyopaque) ?*Bass;
extern fn rediwm_bass_destroy(bass: ?*Bass) void;
extern fn rediwm_bass_get(bass: ?*Bass, gain: *f32, treble: *f32) c_int;
extern fn rediwm_bass_set(bass: ?*Bass, gain: f32) bool;
extern fn rediwm_bass_set_treble(bass: ?*Bass, treble: f32) bool;
extern fn rediwm_bass_set_mute(bass: ?*Bass, muted: bool) bool;
extern fn rediwm_bass_reconnect(bass: ?*Bass) void;

/// How long a mute waits for the bass filter's fade before muting the sink:
/// the fade (bass_dsp.c MUTE_FADE_OUT, 200 ms) plus time for its last samples
/// to reach the speakers (up to a 2048-frame quantum to process, then the
/// device buffer). The sink reads as muted throughout.
const mute_fade_delay_us: pa.pa_usec_t = 350_000;

/// Reconnect delays after a failure double from this up to `<< 7` (32 s),
/// so a server that crashes as it starts is not hammered.
const reconnect_base_us: pa.pa_usec_t = 250_000;
/// Consecutive failures without ever reaching READY before giving up. Only a
/// server that keeps failing counts: one that is absent leaves a NOFAIL
/// context connecting, not failed (unless there is no D-Bus to watch it on).
const reconnect_max_failures = 12;

/// `gain` is the bass boost (0..12 dB), `treble` a cut or boost (-6..6 dB).
pub const BassState = struct { gain: f32, treble: f32, available: bool, save_failed: bool };

const pa_volume_norm: f32 = @floatFromInt(pa.PA_VOLUME_NORM);

pub const SinkInfo = struct {
    index: u32,
    name: []const u8,
    description: []const u8,
    volume: f32, // loudest channel, 0.0 - 1.0
    balance: f32, // -1 = left, 0 = centre, +1 = right
    can_balance: bool,
    channel_map: pa.pa_channel_map,
    muted: bool,
    is_default: bool,
    channels: u8,
};

pub const SourceInfo = struct {
    index: u32,
    name: []const u8,
    description: []const u8,
    volume: f32,
    muted: bool,
    is_default: bool,
    channels: u8,
};

pub const SinkInputInfo = struct {
    index: u32,
    name: []const u8, // app name, e.g. "Firefox"
    app_id: []const u8, // e.g. "org.mozilla.firefox", "" if unset
    pid: u32, // 0 if unavailable
    volume: f32,
    muted: bool,
    sink_index: u32,
    channels: u8,
};

pub const AudioManager = struct {
    pub const HardwareAction = enum { volume_up, volume_down, volume_mute, mic_mute };
    const Action = union(enum) {
        volume_up,
        volume_down,
        volume_mute,
        mic_mute,
        set_volume: f32,
        set_balance: f32,
    };
    bass: ?*Bass = null,
    action_queue: [128]Action = undefined,
    action_head: usize = 0,
    action_len: usize = 0,
    action_current: ?Action = null,
    allocator: Allocator,
    mainloop: *pa.pa_threaded_mainloop,
    context: *pa.pa_context,
    /// The PA thread populates startup state when the connection becomes ready.
    initial_population_pending: bool = false,
    /// Write end of a self-pipe (eventfd) the compositor registers with its
    /// own `wl.EventLoop`; `-1` once `deinit` has closed it.
    wake_fd: std.posix.fd_t,
    /// Bumped (`.monotonic`, no compositor calls) from the PA thread on any
    /// subscribed state change. Compare against a last-seen value to know
    /// whether cached state needs re-reading; see `Taskbar.tick`.
    generation: std.atomic.Value(u32) = .init(0),
    /// A mute fading out through the bass filter: the sink is muted when
    /// this fires (`muteTimerCallback`), and reads as muted until then.
    mute_timer: ?*pa.pa_time_event = null,
    pending_mute_sink: u32 = 0,
    /// Pending replacement of a failed context (`reconnectCallback`).
    reconnect_timer: ?*pa.pa_time_event = null,
    reconnect_failures: u8 = 0,
    /// Set by `deinit`: the context terminating then is not a lost server.
    shutting_down: bool = false,

    sinks: std.ArrayList(SinkInfo) = .empty,
    sources: std.ArrayList(SourceInfo) = .empty,
    sink_inputs: std.ArrayList(SinkInputInfo) = .empty,
    sinks_scratch: std.ArrayList(SinkInfo) = .empty,
    sources_scratch: std.ArrayList(SourceInfo) = .empty,
    sink_inputs_scratch: std.ArrayList(SinkInputInfo) = .empty,

    default_sink_name: [128]u8 = undefined,
    default_sink_name_len: usize = 0,
    default_source_name: [128]u8 = undefined,
    default_source_name_len: usize = 0,

    fn defaultSinkNameSlice(self: *const AudioManager) []const u8 {
        return self.default_sink_name[0..self.default_sink_name_len];
    }

    fn defaultSourceNameSlice(self: *const AudioManager) []const u8 {
        return self.default_source_name[0..self.default_source_name_len];
    }

    /// Connect and populate on PA's existing thread. A slow or unresponsive
    /// sound server must not delay the first frame or the compositor event
    /// loop; one that is not running yet is waited for. Returns an error
    /// (never crashes) only if libpulse itself cannot start — callers log a
    /// warning and leave audio support disabled, matching every other
    /// optional subsystem in this compositor.
    pub fn createAsync(allocator: Allocator) !*AudioManager {
        const mainloop = pa.pa_threaded_mainloop_new() orelse return error.MainloopCreateFailed;
        errdefer pa.pa_threaded_mainloop_free(mainloop);

        const api = pa.pa_threaded_mainloop_get_api(mainloop);
        const context = pa.pa_context_new(api, "rediwm") orelse return error.ContextCreateFailed;
        errdefer pa.pa_context_unref(context);

        const self = try allocator.create(AudioManager);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .mainloop = mainloop,
            .context = context,
            .initial_population_pending = true,
            .wake_fd = -1,
        };

        pa.pa_context_set_state_callback(context, stateCallback, self);

        // A server that refuses now (NOFAIL cannot wait on D-Bus with
        // PULSE_SERVER set, or without a bus) is retried like a lost one.
        // PA's thread is not running yet, so no lock is needed.
        if (pa.pa_context_connect(context, null, pa.PA_CONTEXT_NOFAIL, null) < 0) self.connectionLostLocked();
        if (pa.pa_threaded_mainloop_start(mainloop) < 0) return error.MainloopStartFailed;
        self.bass = rediwm_bass_create(bassChanged, self);
        return self;
    }

    /// Runs on PA's thread for every connection that becomes ready.
    fn populateLocked(self: *AudioManager) void {
        pa.pa_context_set_subscribe_callback(self.context, subscribeCallback, self);
        const mask: pa.pa_subscription_mask_t = pa.PA_SUBSCRIPTION_MASK_SINK |
            pa.PA_SUBSCRIPTION_MASK_SOURCE | pa.PA_SUBSCRIPTION_MASK_SINK_INPUT |
            pa.PA_SUBSCRIPTION_MASK_SERVER;
        // Fire-and-forget: see the module doc comment on why this must not wait.
        if (pa.pa_context_subscribe(self.context, mask, null, null)) |op| pa.pa_operation_unref(op);

        self.refreshServerInfoLocked(false);
        self.refreshSinksLocked(false);
        self.refreshSourcesLocked(false);
        self.refreshSinkInputsLocked(false);
        // Bumped once so `generation` starts at 1: every fresh consumer
        // (a Taskbar's `audio_generation_seen` defaults to 0) then sees a
        // mismatch on its very first check and reads the real initial state,
        // rather than only reacting to the first *external* change.
        _ = self.generation.fetchAdd(1, .monotonic);
        self.wake();
    }

    pub fn deinit(self: *AudioManager) void {
        pa.pa_threaded_mainloop_lock(self.mainloop);
        // Before the lock is next released: a failure from now on must not
        // schedule (or run) a reconnect.
        self.shutting_down = true;
        // A mute still fading out happens now: the fade dies with the filter.
        if (self.mute_timer != null) {
            self.cancelSinkMute();
            if (pa.pa_context_set_sink_mute_by_index(self.context, self.pending_mute_sink, 1, signalDone, self)) |op| {
                while (pa.pa_operation_get_state(op) == pa.PA_OPERATION_RUNNING) pa.pa_threaded_mainloop_wait(self.mainloop);
                pa.pa_operation_unref(op);
            }
        }
        // PA callbacks use the filter; drop it before freeing it.
        const bass = self.bass;
        self.bass = null;
        pa.pa_threaded_mainloop_unlock(self.mainloop);
        // The native loop may notify through the PA lock; stop it unlocked.
        rediwm_bass_destroy(bass);
        pa.pa_threaded_mainloop_lock(self.mainloop);
        self.initial_population_pending = false;
        if (self.reconnect_timer) |timer| {
            const api = pa.pa_threaded_mainloop_get_api(self.mainloop);
            if (api.*.time_free) |free_fn| free_fn(timer);
            self.reconnect_timer = null;
        }
        pa.pa_context_disconnect(self.context);
        pa.pa_threaded_mainloop_unlock(self.mainloop);
        pa.pa_threaded_mainloop_stop(self.mainloop);
        pa.pa_context_unref(self.context);
        pa.pa_threaded_mainloop_free(self.mainloop);

        // Shutdown can interrupt asynchronous list responses (scratch lists).
        self.clearDevicesLocked();
        self.sinks.deinit(self.allocator);
        self.sources.deinit(self.allocator);
        self.sink_inputs.deinit(self.allocator);
        self.sinks_scratch.deinit(self.allocator);
        self.sources_scratch.deinit(self.allocator);
        self.sink_inputs_scratch.deinit(self.allocator);

        if (self.wake_fd >= 0) _ = std.posix.system.close(self.wake_fd);

        self.allocator.destroy(self);
    }

    /// Registers the eventfd `fd` this manager should write to (from the PA
    /// thread) whenever state changes, so the compositor thread wakes up and
    /// repaints. Owned by the caller (`Server`), which is responsible for
    /// registering it with `wl.EventLoop.addFd` and closing it.
    pub fn setWakeFd(self: *AudioManager, fd: std.posix.fd_t) void {
        self.lock();
        defer self.unlock();
        self.wake_fd = fd;
    }

    pub fn lock(self: *AudioManager) void {
        pa.pa_threaded_mainloop_lock(self.mainloop);
    }

    pub fn unlock(self: *AudioManager) void {
        pa.pa_threaded_mainloop_unlock(self.mainloop);
    }

    /// Do not call while holding the PA lock: native notifications take it.
    pub fn getBass(self: *AudioManager) BassState {
        var gain: f32 = 0;
        var treble: f32 = 0;
        const status = rediwm_bass_get(self.bass, &gain, &treble);
        return .{ .gain = gain, .treble = treble, .available = status != 0, .save_failed = status == 2 };
    }

    pub fn setBass(self: *AudioManager, gain: f32) bool {
        return rediwm_bass_set(self.bass, gain);
    }

    pub fn setTreble(self: *AudioManager, treble: f32) bool {
        return rediwm_bass_set_treble(self.bass, treble);
    }

    fn wake(self: *AudioManager) void {
        if (self.wake_fd < 0) return;
        // eventfd accepts exactly eight bytes; a one-byte self-pipe write
        // fails with EINVAL and leaves the compositor asleep.
        const increment: u64 = 1;
        _ = std.posix.system.write(self.wake_fd, @ptrCast(&increment), @sizeOf(u64));
    }

    /// Frees every device list, partial (scratch) ones included.
    fn clearDevicesLocked(self: *AudioManager) void {
        freeSinks(self.allocator, self.sinks.items);
        self.sinks.clearRetainingCapacity();
        freeSinks(self.allocator, self.sinks_scratch.items);
        self.sinks_scratch.clearRetainingCapacity();
        freeSources(self.allocator, self.sources.items);
        self.sources.clearRetainingCapacity();
        freeSources(self.allocator, self.sources_scratch.items);
        self.sources_scratch.clearRetainingCapacity();
        freeSinkInputs(self.allocator, self.sink_inputs.items);
        self.sink_inputs.clearRetainingCapacity();
        freeSinkInputs(self.allocator, self.sink_inputs_scratch.items);
        self.sink_inputs_scratch.clearRetainingCapacity();
        self.default_sink_name_len = 0;
        self.default_source_name_len = 0;
    }

    /// The context failed (on PA's thread): forget the old server's state and
    /// schedule a new context. Its pending operations were cancelled without
    /// callbacks, so the action in flight is dropped here.
    fn connectionLostLocked(self: *AudioManager) void {
        if (self.shutting_down or self.reconnect_timer != null) return;
        // Presses queued now would land long after they were made.
        self.initial_population_pending = false;
        self.action_current = null;
        self.action_len = 0;
        // The sink a fade-out was for is gone, never muted; the filter
        // follows the reconnected server's mute state from its first list.
        if (self.mute_timer != null) {
            self.cancelSinkMute();
            _ = rediwm_bass_set_mute(self.bass, false);
        }
        self.clearDevicesLocked();
        _ = self.generation.fetchAdd(1, .monotonic);
        self.wake();

        const reason = std.mem.span(pa.pa_strerror(pa.pa_context_errno(self.context)));
        if (self.reconnect_failures >= reconnect_max_failures) {
            log.warn("PipeWire/PulseAudio connection failed ({s}); giving up after {d} attempts", .{ reason, self.reconnect_failures });
            return;
        }
        const delay = reconnect_base_us << @intCast(@min(self.reconnect_failures, 7));
        self.reconnect_failures += 1;
        self.reconnect_timer = pa.pa_context_rttime_new(self.context, pa.pa_rtclock_now() + delay, reconnectCallback, self);
        log.warn("PipeWire/PulseAudio connection lost ({s}); reconnecting in {d} ms", .{ reason, delay / 1000 });
    }

    // ---- Refresh (query) operations. `wait`: block until the initial list
    // is populated (safe only when called from a thread other than PA's
    // own — see the module doc comment); `false` fires the query
    // asynchronously and lets the `eol` callback swap the result in whenever
    // it arrives, which is the only safe option from inside a PA callback. ----

    pub fn refreshSinks(self: *AudioManager) void {
        self.lock();
        defer self.unlock();
        self.refreshSinksLocked(true);
    }

    pub fn refreshSources(self: *AudioManager) void {
        self.lock();
        defer self.unlock();
        self.refreshSourcesLocked(true);
    }

    pub fn refreshSinkInputs(self: *AudioManager) void {
        self.lock();
        defer self.unlock();
        self.refreshSinkInputsLocked(true);
    }

    fn refreshSinksLocked(self: *AudioManager, wait: bool) void {
        const op = pa.pa_context_get_sink_info_list(self.context, sinkInfoCallback, self) orelse return;
        if (wait) while (pa.pa_operation_get_state(op) == pa.PA_OPERATION_RUNNING) pa.pa_threaded_mainloop_wait(self.mainloop);
        pa.pa_operation_unref(op);
    }

    fn refreshSourcesLocked(self: *AudioManager, wait: bool) void {
        const op = pa.pa_context_get_source_info_list(self.context, sourceInfoCallback, self) orelse return;
        if (wait) while (pa.pa_operation_get_state(op) == pa.PA_OPERATION_RUNNING) pa.pa_threaded_mainloop_wait(self.mainloop);
        pa.pa_operation_unref(op);
    }

    fn refreshSinkInputsLocked(self: *AudioManager, wait: bool) void {
        const op = pa.pa_context_get_sink_input_info_list(self.context, sinkInputInfoCallback, self) orelse return;
        if (wait) while (pa.pa_operation_get_state(op) == pa.PA_OPERATION_RUNNING) pa.pa_threaded_mainloop_wait(self.mainloop);
        pa.pa_operation_unref(op);
    }

    fn refreshServerInfoLocked(self: *AudioManager, wait: bool) void {
        const op = pa.pa_context_get_server_info(self.context, serverInfoCallback, self) orelse return;
        if (wait) while (pa.pa_operation_get_state(op) == pa.PA_OPERATION_RUNNING) pa.pa_threaded_mainloop_wait(self.mainloop);
        pa.pa_operation_unref(op);
    }

    // ---- Master volume/mute: always the current default sink. ----

    /// Serialize read/modify/write operations against server state. Reusing
    /// the subscription cache here loses fast key presses before it refreshes.
    pub fn hardwareAction(self: *AudioManager, action: HardwareAction) void {
        self.enqueueAction(switch (action) {
            .volume_up => .volume_up,
            .volume_down => .volume_down,
            .volume_mute => .volume_mute,
            .mic_mute => .mic_mute,
        });
    }

    fn enqueueAction(self: *AudioManager, action: Action) void {
        self.lock();
        defer self.unlock();
        if (self.action_len == self.action_queue.len) return;
        self.action_queue[(self.action_head + self.action_len) % self.action_queue.len] = action;
        self.action_len += 1;
        self.nextActionLocked();
    }

    fn nextActionLocked(self: *AudioManager) void {
        if (self.initial_population_pending or self.action_current != null or self.action_len == 0) return;
        self.action_current = self.action_queue[self.action_head];
        self.action_head = (self.action_head + 1) % self.action_queue.len;
        self.action_len -= 1;
        const op = if (self.action_current.? == .mic_mute)
            pa.pa_context_get_source_info_by_name(self.context, "@DEFAULT_SOURCE@", actionSource, self)
        else
            pa.pa_context_get_sink_info_by_name(self.context, "@DEFAULT_SINK@", actionSink, self);
        if (op) |operation| pa.pa_operation_unref(operation) else {
            self.action_current = null;
            self.action_len = 0;
        }
    }

    pub fn getMasterVolume(self: *AudioManager) f32 {
        self.lock();
        defer self.unlock();
        for (self.sinks.items) |sink| {
            if (sink.is_default) return sink.volume;
        }
        return 0;
    }

    pub fn isMasterMuted(self: *AudioManager) bool {
        self.lock();
        defer self.unlock();
        if (self.mute_timer != null) return true;
        for (self.sinks.items) |sink| {
            if (sink.is_default) return sink.muted;
        }
        return false;
    }

    pub fn setMasterVolume(self: *AudioManager, volume: f32) void {
        if (!std.math.isFinite(volume)) return;
        self.enqueueAction(.{ .set_volume = std.math.clamp(volume, 0, 1) });
    }

    pub fn setMasterBalance(self: *AudioManager, balance: f32) void {
        if (!std.math.isFinite(balance)) return;
        self.enqueueAction(.{ .set_balance = std.math.clamp(balance, -1, 1) });
    }

    // An all-zero channel vector cannot encode balance. Keep the last
    // balance for this device/map until output volume is raised again.
    fn balanceForSink(self: *AudioManager, sink: *const pa.pa_sink_info) f32 {
        if (pa.pa_cvolume_max(&sink.volume) != 0)
            return pa.pa_cvolume_get_balance(&sink.volume, &sink.channel_map);
        for (self.sinks.items) |previous| {
            if (previous.index == sink.index and
                std.mem.eql(u8, previous.name, std.mem.span(sink.name)) and
                pa.pa_channel_map_equal(&previous.channel_map, &sink.channel_map) != 0)
                return previous.balance;
        }
        return 0;
    }

    /// Mutes or unmutes the default sink (`sink_index`) with a fade through
    /// the bass filter. Muting fades out first and mutes the sink once the
    /// fade has played; without the filter it mutes at once. Unmuting unmutes
    /// the sink now and fades in once the server reports it unmuted
    /// (`syncFilterMuteLocked`): fading in first would play into a muted
    /// device. Returns the sink operation, if one was sent, with `callback`.
    fn setMasterMuteLocked(self: *AudioManager, sink_index: u32, mute: bool, callback: pa.pa_context_success_cb_t) ?*pa.pa_operation {
        if (mute) {
            if (rediwm_bass_set_mute(self.bass, true)) {
                self.cancelSinkMute();
                self.pending_mute_sink = sink_index;
                self.mute_timer = pa.pa_context_rttime_new(self.context, pa.pa_rtclock_now() + mute_fade_delay_us, muteTimerCallback, self);
                if (self.mute_timer != null) return null;
            }
            return pa.pa_context_set_sink_mute_by_index(self.context, sink_index, 1, callback, self);
        }
        // Still fading out: the sink was never muted, so no server event will
        // come to fade back in.
        if (self.mute_timer != null) {
            self.cancelSinkMute();
            _ = rediwm_bass_set_mute(self.bass, false);
        }
        return pa.pa_context_set_sink_mute_by_index(self.context, sink_index, 0, callback, self);
    }

    fn cancelSinkMute(self: *AudioManager) void {
        if (self.mute_timer) |timer| {
            const api = pa.pa_threaded_mainloop_get_api(self.mainloop);
            if (api.*.time_free) |free_fn| free_fn(timer);
            self.mute_timer = null;
        }
    }

    /// The filter follows the default sink's mute, including changes made
    /// elsewhere (pavucontrol, a new default device).
    fn syncFilterMuteLocked(self: *AudioManager) void {
        for (self.sinks.items) |sink| {
            if (sink.is_default) _ = rediwm_bass_set_mute(self.bass, sink.muted);
        }
    }

    pub fn toggleMasterMute(self: *AudioManager) void {
        self.lock();
        defer self.unlock();
        for (self.sinks.items) |sink| {
            if (!sink.is_default) continue;
            // `muted` includes a mute still fading out.
            if (self.setMasterMuteLocked(sink.index, !sink.muted, null)) |op| pa.pa_operation_unref(op);
            return;
        }
    }

    // ---- Input device (microphone), same shape as master output. ----

    pub fn getInputVolume(self: *AudioManager) f32 {
        self.lock();
        defer self.unlock();
        for (self.sources.items) |source| {
            if (source.is_default) return source.volume;
        }
        return 0;
    }

    pub fn isInputMuted(self: *AudioManager) bool {
        self.lock();
        defer self.unlock();
        for (self.sources.items) |source| {
            if (source.is_default) return source.muted;
        }
        return false;
    }

    pub fn setInputVolume(self: *AudioManager, volume: f32) void {
        self.lock();
        defer self.unlock();
        const clamped = std.math.clamp(volume, 0, 1);
        for (self.sources.items) |source| {
            if (!source.is_default) continue;
            var cv: pa.pa_cvolume = undefined;
            _ = pa.pa_cvolume_set(&cv, source.channels, volumeToPa(clamped));
            if (pa.pa_context_set_source_volume_by_index(self.context, source.index, &cv, null, null)) |op| pa.pa_operation_unref(op);
            return;
        }
    }

    pub fn toggleInputMute(self: *AudioManager) void {
        self.lock();
        defer self.unlock();
        for (self.sources.items) |source| {
            if (!source.is_default) continue;
            const want: c_int = if (source.muted) 0 else 1;
            if (pa.pa_context_set_source_mute_by_index(self.context, source.index, want, null, null)) |op| pa.pa_operation_unref(op);
            return;
        }
    }

    // ---- Per-app volume, keyed by the sink input's own `index` — not
    // `pid`, which PipeWire clients don't always report and which isn't
    // unique per stream (one app can own several sink inputs). ----

    pub fn setSinkInputVolume(self: *AudioManager, index: u32, volume: f32) void {
        self.lock();
        defer self.unlock();
        const clamped = std.math.clamp(volume, 0, 1);
        for (self.sink_inputs.items) |si| {
            if (si.index != index) continue;
            var cv: pa.pa_cvolume = undefined;
            _ = pa.pa_cvolume_set(&cv, si.channels, volumeToPa(clamped));
            if (pa.pa_context_set_sink_input_volume(self.context, si.index, &cv, null, null)) |op| pa.pa_operation_unref(op);
            return;
        }
    }

    pub fn setSinkInputMute(self: *AudioManager, index: u32, muted: bool) void {
        self.lock();
        defer self.unlock();
        for (self.sink_inputs.items) |si| {
            if (si.index != index) continue;
            const want: c_int = if (muted) 1 else 0;
            if (pa.pa_context_set_sink_input_mute(self.context, si.index, want, null, null)) |op| pa.pa_operation_unref(op);
            return;
        }
    }

    // ---- Default device selection. ----

    pub fn setDefaultSink(self: *AudioManager, name: []const u8) void {
        var buf: [256]u8 = undefined;
        const name_z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return;
        self.lock();
        defer self.unlock();
        if (pa.pa_context_set_default_sink(self.context, name_z, null, null)) |op| pa.pa_operation_unref(op);
    }

    pub fn setDefaultSource(self: *AudioManager, name: []const u8) void {
        var buf: [256]u8 = undefined;
        const name_z = std.fmt.bufPrintSentinel(&buf, "{s}", .{name}, 0) catch return;
        self.lock();
        defer self.unlock();
        if (pa.pa_context_set_default_source(self.context, name_z, null, null)) |op| pa.pa_operation_unref(op);
    }
};

fn bassChanged(userdata: ?*anyopaque) callconv(.c) void {
    const self: *AudioManager = @ptrCast(@alignCast(userdata.?));
    self.lock();
    defer self.unlock();
    _ = self.generation.fetchAdd(1, .monotonic);
    self.wake();
}

fn actionDone(_: ?*pa.pa_context, success: c_int, userdata: ?*anyopaque) callconv(.c) void {
    const self: *AudioManager = @ptrCast(@alignCast(userdata.?));
    if (success == 0) log.warn("audio device rejected volume/mute action", .{});
    // Refresh even on failure: the OSD always follows actual server state.
    if (self.action_current != null and self.action_current.? == .mic_mute) self.refreshSourcesLocked(false) else self.refreshSinksLocked(false);
    self.action_current = null;
    self.nextActionLocked();
}

/// The fade out has played: mute the sink itself.
fn muteTimerCallback(api: ?*pa.pa_mainloop_api, e: ?*pa.pa_time_event, tv: ?*const pa.struct_timeval, userdata: ?*anyopaque) callconv(.c) void {
    _ = tv;
    const self: *AudioManager = @ptrCast(@alignCast(userdata.?));
    if (e) |timer| {
        if (api) |a| if (a.time_free) |free_fn| free_fn(timer);
    }
    self.mute_timer = null;
    if (pa.pa_context_set_sink_mute_by_index(self.context, self.pending_mute_sink, 1, null, null)) |op| {
        pa.pa_operation_unref(op);
    }
}

fn signalDone(_: ?*pa.pa_context, _: c_int, userdata: ?*anyopaque) callconv(.c) void {
    const self: *AudioManager = @ptrCast(@alignCast(userdata.?));
    pa.pa_threaded_mainloop_signal(self.mainloop, 0);
}

fn actionSink(_: ?*pa.pa_context, info: ?*const pa.pa_sink_info, eol: c_int, userdata: ?*anyopaque) callconv(.c) void {
    const self: *AudioManager = @ptrCast(@alignCast(userdata.?));
    if (eol != 0) {
        if (eol < 0) actionDone(null, 0, userdata);
        return;
    }
    const sink = info orelse return;
    const action = self.action_current orelse return;
    const op = if (action == .volume_mute) blk: {
        const muted = sink.mute != 0 or self.mute_timer != null;
        break :blk self.setMasterMuteLocked(sink.index, !muted, actionDone) orelse {
            // Fading out; report it as muted now.
            actionDone(null, 1, userdata);
            return;
        };
    } else blk: {
        var volume = sink.volume;
        const balance = self.balanceForSink(sink);
        switch (action) {
            .set_balance => |value| {
                if (pa.pa_channel_map_can_balance(&sink.channel_map) == 0) {
                    actionDone(null, 1, userdata);
                    return;
                }
                _ = pa.pa_cvolume_set_balance(&volume, &sink.channel_map, value);
                // With silent channels the server cannot remember this. This
                // also makes the setting visible without an audio event.
                if (pa.pa_cvolume_max(&volume) == 0) {
                    for (self.sinks.items) |*cached| {
                        if (cached.index == sink.index) cached.balance = value;
                    }
                }
            },
            .volume_up, .volume_down, .set_volume => {
                const current = @as(f32, @floatFromInt(pa.pa_cvolume_max(&sink.volume))) / pa_volume_norm;
                const target = switch (action) {
                    .set_volume => |value| value,
                    .volume_up => current + 0.05,
                    .volume_down => current - 0.05,
                    else => unreachable,
                };
                // Raising the volume of a muted sink unmutes it, whatever
                // asked (keys, taskbar scroll, sliders, IPC). `volume_up`
                // counts even when already at the maximum.
                const raising = switch (action) {
                    .volume_up => true,
                    .set_volume => volumeToPa(target) > pa.pa_cvolume_max(&sink.volume),
                    else => false,
                };
                if (raising and (sink.mute != 0 or self.mute_timer != null)) {
                    if (self.setMasterMuteLocked(sink.index, false, null)) |unmute| pa.pa_operation_unref(unmute);
                }
                if (pa.pa_cvolume_max(&volume) == 0) {
                    _ = pa.pa_cvolume_set(&volume, volume.channels, volumeToPa(target));
                    _ = pa.pa_cvolume_set_balance(&volume, &sink.channel_map, balance);
                } else {
                    _ = pa.pa_cvolume_scale(&volume, volumeToPa(target));
                }
                // A query may already report zero by the time subscription
                // state arrives; remember the authoritative pre-zero balance.
                if (pa.pa_cvolume_max(&volume) == 0) {
                    for (self.sinks.items) |*cached| {
                        if (cached.index == sink.index) cached.balance = balance;
                    }
                }
            },
            .volume_mute, .mic_mute => unreachable,
        }
        break :blk pa.pa_context_set_sink_volume_by_index(self.context, sink.index, &volume, actionDone, self);
    };
    if (op) |operation| pa.pa_operation_unref(operation) else actionDone(null, 0, userdata);
}

fn actionSource(_: ?*pa.pa_context, info: ?*const pa.pa_source_info, eol: c_int, userdata: ?*anyopaque) callconv(.c) void {
    if (eol != 0) {
        if (eol < 0) actionDone(null, 0, userdata);
        return;
    }
    const self: *AudioManager = @ptrCast(@alignCast(userdata.?));
    const source = info orelse return;
    if (pa.pa_context_set_source_mute_by_index(self.context, source.index, if (source.mute == 0) 1 else 0, actionDone, self)) |op| pa.pa_operation_unref(op) else actionDone(null, 0, userdata);
}

fn volumeToPa(volume: f32) pa.pa_volume_t {
    return @intFromFloat(std.math.clamp(volume, 0, 1) * pa_volume_norm);
}

fn stateCallback(context: ?*pa.pa_context, userdata: ?*anyopaque) callconv(.c) void {
    const self: *AudioManager = @ptrCast(@alignCast(userdata.?));
    switch (pa.pa_context_get_state(context)) {
        pa.PA_CONTEXT_READY => {
            const first = self.initial_population_pending;
            self.initial_population_pending = false;
            self.reconnect_failures = 0;
            self.populateLocked();
            self.nextActionLocked();
            if (first)
                log.info("connected to PipeWire/PulseAudio; loading devices asynchronously", .{})
            else {
                log.info("reconnected to PipeWire/PulseAudio", .{});
                // pipewire-pulse runs on PipeWire: if the filter lost the
                // daemon too, it is worth retrying now (lock-free call).
                rediwm_bass_reconnect(self.bass);
            }
        },
        pa.PA_CONTEXT_FAILED, pa.PA_CONTEXT_TERMINATED => self.connectionLostLocked(),
        else => {},
    }
    pa.pa_threaded_mainloop_signal(self.mainloop, 0);
}

/// Replaces the failed context with a new one (on PA's thread). The old
/// one's callbacks are detached first: it must never report into `self`.
fn reconnectCallback(api: ?*pa.pa_mainloop_api, e: ?*pa.pa_time_event, tv: ?*const pa.struct_timeval, userdata: ?*anyopaque) callconv(.c) void {
    _ = tv;
    const self: *AudioManager = @ptrCast(@alignCast(userdata.?));
    if (e) |timer| {
        if (api) |a| if (a.time_free) |free_fn| free_fn(timer);
    }
    self.reconnect_timer = null;
    if (self.shutting_down) return;
    const context = pa.pa_context_new(pa.pa_threaded_mainloop_get_api(self.mainloop), "rediwm") orelse {
        self.connectionLostLocked();
        return;
    };
    const old = self.context;
    pa.pa_context_set_state_callback(old, null, null);
    pa.pa_context_set_subscribe_callback(old, null, null);
    self.context = context;
    pa.pa_context_unref(old);
    pa.pa_context_set_state_callback(context, stateCallback, self);
    // A synchronous failure has already reported FAILED; the timer guard in
    // `connectionLostLocked` keeps this from scheduling twice.
    if (pa.pa_context_connect(context, null, pa.PA_CONTEXT_NOFAIL, null) < 0) self.connectionLostLocked();
}

/// Fires on any subscribed state change, running on the PA thread — must
/// never wait or call into compositor code directly (see module doc
/// comment). Re-issues the relevant async (non-waiting) refresh and bumps
/// `generation` so the compositor notices next time it looks.
fn subscribeCallback(context: ?*pa.pa_context, event_type: pa.pa_subscription_event_type_t, idx: u32, userdata: ?*anyopaque) callconv(.c) void {
    _ = context;
    _ = idx;
    const self: *AudioManager = @ptrCast(@alignCast(userdata.?));
    const facility = event_type & pa.PA_SUBSCRIPTION_EVENT_FACILITY_MASK;
    switch (facility) {
        pa.PA_SUBSCRIPTION_EVENT_SINK => self.refreshSinksLocked(false),
        pa.PA_SUBSCRIPTION_EVENT_SOURCE => self.refreshSourcesLocked(false),
        pa.PA_SUBSCRIPTION_EVENT_SINK_INPUT => self.refreshSinkInputsLocked(false),
        pa.PA_SUBSCRIPTION_EVENT_SERVER => {
            // The default device itself changed, not just a device's
            // properties — re-derive every sink/source's `is_default` flag.
            self.refreshServerInfoLocked(false);
            self.refreshSinksLocked(false);
            self.refreshSourcesLocked(false);
        },
        else => {},
    }
    _ = self.generation.fetchAdd(1, .monotonic);
    self.wake();
}

fn serverInfoCallback(context: ?*pa.pa_context, info: ?*const pa.pa_server_info, userdata: ?*anyopaque) callconv(.c) void {
    _ = context;
    const self: *AudioManager = @ptrCast(@alignCast(userdata.?));
    if (info) |i| {
        const sink_name = std.mem.span(i.default_sink_name);
        self.default_sink_name_len = @min(sink_name.len, self.default_sink_name.len);
        @memcpy(self.default_sink_name[0..self.default_sink_name_len], sink_name[0..self.default_sink_name_len]);

        const source_name = std.mem.span(i.default_source_name);
        self.default_source_name_len = @min(source_name.len, self.default_source_name.len);
        @memcpy(self.default_source_name[0..self.default_source_name_len], source_name[0..self.default_source_name_len]);
    }
    pa.pa_threaded_mainloop_signal(self.mainloop, 0);
}

fn sinkInfoCallback(context: ?*pa.pa_context, info: ?*const pa.pa_sink_info, eol: c_int, userdata: ?*anyopaque) callconv(.c) void {
    _ = context;
    const self: *AudioManager = @ptrCast(@alignCast(userdata.?));
    if (eol != 0) {
        freeSinks(self.allocator, self.sinks.items);
        self.sinks.deinit(self.allocator);
        self.sinks = self.sinks_scratch;
        self.sinks_scratch = .empty;
        self.syncFilterMuteLocked();
        _ = self.generation.fetchAdd(1, .monotonic);
        self.wake();
        pa.pa_threaded_mainloop_signal(self.mainloop, 0);
        return;
    }
    const i = info orelse return;
    const name = self.allocator.dupe(u8, std.mem.span(i.name)) catch return;
    const description = self.allocator.dupe(u8, std.mem.span(i.description)) catch {
        self.allocator.free(name);
        return;
    };
    self.sinks_scratch.append(self.allocator, .{
        .index = i.index,
        .name = name,
        .description = description,
        .volume = @as(f32, @floatFromInt(pa.pa_cvolume_max(&i.volume))) / pa_volume_norm,
        .balance = self.balanceForSink(i),
        .can_balance = pa.pa_channel_map_can_balance(&i.channel_map) != 0,
        .channel_map = i.channel_map,
        .muted = i.mute != 0 or (self.mute_timer != null and i.index == self.pending_mute_sink),
        .is_default = std.mem.eql(u8, std.mem.span(i.name), self.defaultSinkNameSlice()),
        .channels = i.volume.channels,
    }) catch {
        self.allocator.free(name);
        self.allocator.free(description);
    };
}

fn sourceInfoCallback(context: ?*pa.pa_context, info: ?*const pa.pa_source_info, eol: c_int, userdata: ?*anyopaque) callconv(.c) void {
    _ = context;
    const self: *AudioManager = @ptrCast(@alignCast(userdata.?));
    if (eol != 0) {
        freeSources(self.allocator, self.sources.items);
        self.sources.deinit(self.allocator);
        self.sources = self.sources_scratch;
        self.sources_scratch = .empty;
        _ = self.generation.fetchAdd(1, .monotonic);
        self.wake();
        pa.pa_threaded_mainloop_signal(self.mainloop, 0);
        return;
    }
    const i = info orelse return;
    // Skip monitor sources (every sink implicitly has one) — they aren't
    // real microphones and would otherwise double every entry.
    if (i.monitor_of_sink != pa.PA_INVALID_INDEX) return;
    const name = self.allocator.dupe(u8, std.mem.span(i.name)) catch return;
    const description = self.allocator.dupe(u8, std.mem.span(i.description)) catch {
        self.allocator.free(name);
        return;
    };
    self.sources_scratch.append(self.allocator, .{
        .index = i.index,
        .name = name,
        .description = description,
        .volume = @as(f32, @floatFromInt(pa.pa_cvolume_avg(&i.volume))) / pa_volume_norm,
        .muted = i.mute != 0,
        .is_default = std.mem.eql(u8, std.mem.span(i.name), self.defaultSourceNameSlice()),
        .channels = i.volume.channels,
    }) catch {
        self.allocator.free(name);
        self.allocator.free(description);
    };
}

fn sinkInputInfoCallback(context: ?*pa.pa_context, info: ?*const pa.pa_sink_input_info, eol: c_int, userdata: ?*anyopaque) callconv(.c) void {
    _ = context;
    const self: *AudioManager = @ptrCast(@alignCast(userdata.?));
    if (eol != 0) {
        freeSinkInputs(self.allocator, self.sink_inputs.items);
        self.sink_inputs.deinit(self.allocator);
        self.sink_inputs = self.sink_inputs_scratch;
        self.sink_inputs_scratch = .empty;
        _ = self.generation.fetchAdd(1, .monotonic);
        self.wake();
        pa.pa_threaded_mainloop_signal(self.mainloop, 0);
        return;
    }
    const i = info orelse return;
    const proplist_name = if (i.proplist) |p| pa.pa_proplist_gets(p, "application.name") else null;
    const proplist_id = if (i.proplist) |p| pa.pa_proplist_gets(p, "application.id") else null;
    const proplist_pid = if (i.proplist) |p| pa.pa_proplist_gets(p, "application.process.id") else null;
    // The DSP playback leg is plumbing, not an application volume control.
    if (proplist_id) |id| if (std.mem.eql(u8, std.mem.span(id), "rediwm.bass")) return;

    const display_name = proplist_name orelse i.name;
    const name = self.allocator.dupe(u8, std.mem.span(display_name)) catch return;
    const app_id = self.allocator.dupe(u8, if (proplist_id) |v| std.mem.span(v) else "") catch {
        self.allocator.free(name);
        return;
    };
    const pid: u32 = if (proplist_pid) |v| (std.fmt.parseInt(u32, std.mem.span(v), 10) catch 0) else 0;

    self.sink_inputs_scratch.append(self.allocator, .{
        .index = i.index,
        .name = name,
        .app_id = app_id,
        .pid = pid,
        .volume = @as(f32, @floatFromInt(pa.pa_cvolume_avg(&i.volume))) / pa_volume_norm,
        .muted = i.mute != 0,
        .sink_index = i.sink,
        .channels = i.volume.channels,
    }) catch {
        self.allocator.free(name);
        self.allocator.free(app_id);
    };
}

fn freeSinks(allocator: Allocator, items: []const SinkInfo) void {
    for (items) |s| {
        allocator.free(s.name);
        allocator.free(s.description);
    }
}

fn freeSources(allocator: Allocator, items: []const SourceInfo) void {
    for (items) |s| {
        allocator.free(s.name);
        allocator.free(s.description);
    }
}

fn freeSinkInputs(allocator: Allocator, items: []const SinkInputInfo) void {
    for (items) |s| {
        allocator.free(s.name);
        allocator.free(s.app_id);
    }
}
