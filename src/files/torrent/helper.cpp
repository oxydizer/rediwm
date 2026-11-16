// One per-user torrent session. The UI is a disposable subscriber, never the
// owner of a transfer. All libtorrent and GIO state lives on this main loop.
//
// The parts: this file holds the engine, its alerts and the main loop;
// helper_transfers.cpp adds, configures, persists and restores transfers;
// helper_peers.cpp publishes snapshots to the Files windows that subscribe
// and takes their commands; helper_tray.cpp is the StatusNotifierItem and
// its menu. helper.hpp has what they share.
#include "helper.hpp"
#include "../../platform/self_exe.h"

namespace helper {

static GMainLoop *loop;
static int wake_fd = -1;
static guint ticker = 0, idle_exit = 0;
static unsigned ticks = 0;
static bool quitting = false, starting = true;
static void saved(std::string const &id) {
  auto it = saves.find(id);
  if (it != saves.end() && --it->second == 0)
    saves.erase(it);
}
void create_engine() {
  if (session)
    return;
  lt::settings_pack settings;
  settings.set_int(lt::settings_pack::alert_mask,
                   lt::alert_category::error | lt::alert_category::storage |
                       lt::alert_category::status |
                       lt::alert_category::tracker |
                       lt::alert_category::connect |
                       lt::alert_category::peer |
                       lt::alert_category::port_mapping);
  settings.set_int(lt::settings_pack::connections_limit, 100);
  settings.set_int(lt::settings_pack::upload_rate_limit, 1024 * 1024);
  settings.set_bool(lt::settings_pack::enable_dht, false);
  settings.set_bool(lt::settings_pack::enable_lsd, false);
  settings.set_bool(lt::settings_pack::enable_upnp, false);
  settings.set_bool(lt::settings_pack::enable_natpmp, false);
  session = std::make_unique<lt::session>(settings);
  session->set_alert_notify([] {
    uint64_t one = 1;
    const auto written = write(wake_fd, &one, sizeof one);
    (void)written; // EAGAIN means an alert wake is already pending.
  });
}

static void diagnose_alert(lt::alert const *alert) {
  const char *kind = nullptr;
  if (lt::alert_cast<lt::tracker_announce_alert>(alert))
    kind = "tracker announce";
  else if (lt::alert_cast<lt::tracker_reply_alert>(alert))
    kind = "tracker reply";
  else if (lt::alert_cast<lt::tracker_error_alert>(alert))
    kind = "tracker error";
  else if (lt::alert_cast<lt::tracker_warning_alert>(alert))
    kind = "tracker warning";
  else if (lt::alert_cast<lt::peer_connect_alert>(alert))
    kind = "peer connected";
  else if (lt::alert_cast<lt::peer_disconnected_alert>(alert))
    kind = "peer disconnected";
  else if (lt::alert_cast<lt::peer_error_alert>(alert))
    kind = "peer error";
  else if (lt::alert_cast<lt::peer_blocked_alert>(alert))
    kind = "peer blocked";
  else if (lt::alert_cast<lt::portmap_alert>(alert))
    kind = "port mapping";
  else if (lt::alert_cast<lt::portmap_error_alert>(alert))
    kind = "port mapping error";
  else if (lt::alert_cast<lt::listen_failed_alert>(alert))
    kind = "listen failed";
  else if (lt::alert_cast<lt::udp_error_alert>(alert))
    kind = "UDP error";

  if (kind)
    std::cerr << "Transfers: [" << kind << "] "
              << alert->message() << '\n';
}

void wake_engine() {
  if (!session) {
    create_engine();
    restore();
  }
}
static void sleep_engine() {
  if (!session)
    return;
  for (auto &[id, t] : transfers) {
    t.cached = t.status();
    t.cached_info = t.info();
    t.handle = {};
  }
  session->set_alert_notify({});
  session.reset();
}
static bool active() {
  for (auto &[id, t] : transfers)
    if (!(t.status().flags & lt::torrent_flags::paused) || t.moving ||
        t.configuring)
      return true;
  return false;
}
static void maintain() {
  if (!session)
    return;
  for (auto &[id, t] : transfers) {
    auto s = t.status();
    if (!t.pending && s.is_finished && !t.published && !t.moving &&
        t.error.empty()) {
      t.moving = true;
      t.resume_after_publish =
          !(s.flags & lt::torrent_flags::paused) && t.ratio != 0;
      if (s.flags & lt::torrent_flags::paused)
        publish_storage(t);
      else
        t.handle.pause();
    }
    if (!t.pending && s.is_finished && !(s.flags & lt::torrent_flags::paused) &&
        (t.ratio == 0 ||
         s.all_time_upload >= std::max<int64_t>(s.total_wanted, 1) * t.ratio)) {
      t.resume_after_publish = false;
      t.handle.pause();
      request_save(t);
    }
  }
}
static gboolean tick(gpointer) {
  ++ticks;
  if (ticks % 30 == 0)
    for (auto &[id, t] : transfers)
      if (t.handle.is_valid() && t.handle.need_save_resume_data())
        request_save(t);
  maintain();
  publish();
  if (!active()) {
    ticker = 0;
    schedule();
    return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}
void schedule() {
  if (session && active()) {
    lt::settings_pack settings;
    settings.set_bool(lt::settings_pack::enable_dht, true);
    settings.set_bool(lt::settings_pack::enable_lsd, true);
    session->apply_settings(settings);
  }
  if (!active() && saves.empty())
    sleep_engine();
  if (active() && !ticker)
    ticker = g_timeout_add_seconds(1, tick, nullptr);
  if (quitting && saves.empty())
    g_main_loop_quit(loop);
  // Let a concurrently opening Files window finish its connection before
  // retiring a stopped session. This is one deadline, never an idle poll.
  if (!starting && !active() && peers.empty() && saves.empty() && !idle_exit)
    idle_exit = g_timeout_add(
        250,
        [](gpointer) -> gboolean {
          idle_exit = 0;
          if (!active() && peers.empty() && saves.empty())
            g_main_loop_quit(loop);
          return G_SOURCE_REMOVE;
        },
        nullptr);
}
static gboolean alerts(gint, GIOCondition, gpointer) {
  uint64_t value;
  while (read(wake_fd, &value, sizeof value) > 0) {
  }
  if (!session)
    return G_SOURCE_CONTINUE;
  std::vector<lt::alert *> events;
  session->pop_alerts(&events);
  for (auto alert : events) {
    diagnose_alert(alert);
    auto ta = dynamic_cast<lt::torrent_alert *>(alert);
    if (!ta)
      continue;
    Transfer *t = nullptr;
    for (auto &[id, item] : transfers)
      if (item.handle == ta->handle) {
        t = &item;
        break;
      }
    if (!t)
      continue;
    try {
      if (auto a = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
        auto bytes = lt::write_resume_data_buf(a->params);
        atomic_write(state_dir + "/" + t->id + ".resume",
                     std::string(bytes.data(), bytes.size()));
        saved(t->id);
      }
      if (lt::alert_cast<lt::save_resume_data_failed_alert>(alert))
        saved(t->id);
      if (t->configuring && lt::alert_cast<lt::file_prio_alert>(alert) &&
          t->handle.get_file_priorities() == t->requested_priorities) {
        finish_configuration(*t);
      }
      if (t->pending && lt::alert_cast<lt::metadata_received_alert>(alert)) {
        t->handle.pause();
        validate(*t->info());
        if (snapshot().size() > max_packet - 4096)
          throw std::runtime_error(
              "File list exceeds the session metadata limit");
        request_save(*t);
      }
      if (t->moving && lt::alert_cast<lt::torrent_paused_alert>(alert))
        publish_storage(*t);
      if (lt::alert_cast<lt::storage_moved_alert>(alert)) {
        t->moving = false;
        t->published = true;
        if (t->resume_after_publish)
          t->handle.resume();
        persist(*t);
        request_save(*t);
        if (bus)
          g_dbus_connection_call(
              bus, "org.freedesktop.Notifications",
              "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
              "Notify",
              g_variant_new(
                  "(susss@as@a{sv}i)", "Files", 0u, "folder-download",
                  "Download complete", t->status().name.c_str(),
                  g_variant_new_strv(nullptr, 0),
                  g_variant_new_array(G_VARIANT_TYPE("{sv}"), nullptr, 0), -1),
              nullptr, G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, nullptr, nullptr,
              nullptr);
      }
      if (auto a = lt::alert_cast<lt::storage_moved_failed_alert>(alert)) {
        t->moving = false;
        t->error = "Could not publish download: " + a->error.message();
        t->handle.pause();
        request_save(*t);
      }
    } catch (std::exception const &e) {
      t->error = e.what();
      t->handle.pause();
      saved(t->id);
    }
  }
  maintain();
  publish();
  schedule();
  return G_SOURCE_CONTINUE;
}
static gboolean stop(gpointer) {
  quitting = true;
  for (auto &[id, t] : transfers)
    request_save(t);
  schedule();
  g_timeout_add_seconds(
      5,
      [](gpointer) -> gboolean {
        g_main_loop_quit(loop);
        return G_SOURCE_REMOVE;
      },
      nullptr);
  return G_SOURCE_REMOVE;
}

} // namespace helper

using namespace helper;

int main(int argc, char **argv) {
  umask(0077);
  signal(SIGPIPE, SIG_IGN);
  try {
    if (getuid() == 0)
      throw std::runtime_error("Transfers must run as a user");
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (!runtime)
      throw std::runtime_error("Missing runtime directory");
    struct stat st{};
    if (lstat(runtime, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() ||
        (st.st_mode & 077))
      throw std::runtime_error("Runtime directory is not private");
    auto socket_path = std::string(runtime) + "/files-transfers.sock";
    auto lock_path = socket_path + ".lock";
    int lock = open(lock_path.c_str(),
                    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB))
      return 0;
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (socket_path.size() >= sizeof address.sun_path)
      throw std::runtime_error("Runtime path too long");
    strcpy(address.sun_path, socket_path.c_str());
    int listener =
        socket(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    unlink(socket_path.c_str());
    if (bind(listener, reinterpret_cast<sockaddr *>(&address),
             sizeof address) ||
        listen(listener, 16))
      throw std::runtime_error("Cannot listen for Files");
    const char *state = getenv("XDG_STATE_HOME");
    const char *home = getenv("HOME");
    state_dir =
        std::string(state ? state : (home ? home : "")) +
        (state ? "/rediwm/transfers" : "/.local/state/rediwm/transfers");
    fs::create_directories(state_dir);
    struct stat state_stat{};
    if (lstat(state_dir.c_str(), &state_stat) || !S_ISDIR(state_stat.st_mode) ||
        state_stat.st_uid != getuid() || (state_stat.st_mode & 077))
      throw std::runtime_error("Transfer state directory is not private");
    char self[4096];
    if (rediwm_self_exe(self, sizeof self) < 0)
      throw std::runtime_error("Cannot locate the Files executable");
    executable = (fs::path(self).parent_path() / "rediwm-files").string();
    // Scope policy is supplied by the Files launcher, which uses the same
    // native/nested rules as its other user-app launches.
    use_scopes = argc > 1 && !strcmp(argv[1], "--scope");
    place_scope(getpid(), "transfers");
    loop = g_main_loop_new(nullptr, false);
    wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    g_unix_fd_add(wake_fd, G_IO_IN, alerts, nullptr);
    g_unix_fd_add(listener, G_IO_IN, accept_peer, nullptr);
    g_unix_signal_add(SIGTERM, stop, nullptr);
    g_unix_signal_add(SIGINT, stop, nullptr);
    restore();
    if (active())
      ticker = g_timeout_add_seconds(1, tick, nullptr);
    // Allow the spawning window time to connect; no recurring idle timer.
    g_timeout_add_seconds(
        5,
        [](gpointer) -> gboolean {
          starting = false;
          schedule();
          return G_SOURCE_REMOVE;
        },
        nullptr);
    g_main_loop_run(loop);
    sleep_engine();
    close(wake_fd);
    close(listener);
    unlink(socket_path.c_str());
    close(lock);
    g_main_loop_unref(loop);
  } catch (std::exception const &e) {
    std::cerr << "Transfers: " << e.what() << '\n';
    return 1;
  }
}
