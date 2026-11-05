// The Files windows that subscribe: JSON snapshots out, commands in.
// Part of rediwm-transfers (helper.cpp).
#include "helper.hpp"
#include "../../platform/peer.h"

namespace helper {

static std::string display_name(std::string name) {
  if (name.size() > 512)
    name.resize(512);
  while (!name.empty() && !g_utf8_validate(name.c_str(), name.size(), nullptr))
    name.pop_back();
  return name;
}
static void member(JsonBuilder *b, char const *key, std::string const &v) {
  json_builder_set_member_name(b, key);
  json_builder_add_string_value(b, v.c_str());
}
static void number(JsonBuilder *b, char const *key, int64_t v) {
  json_builder_set_member_name(b, key);
  json_builder_add_int_value(b, v);
}
static void boolean(JsonBuilder *b, char const *key, bool v) {
  json_builder_set_member_name(b, key);
  json_builder_add_boolean_value(b, v);
}
static std::string encode(JsonBuilder *b) {
  auto root = json_builder_get_root(b);
  auto gen = json_generator_new();
  json_generator_set_root(gen, root);
  gsize n;
  char *raw = json_generator_to_data(gen, &n);
  std::string result(raw, n);
  g_free(raw);
  g_object_unref(gen);
  json_node_free(root);
  g_object_unref(b);
  return result;
}
std::string snapshot() {
  auto b = json_builder_new();
  json_builder_begin_object(b);
  json_builder_set_member_name(b, "transfers");
  json_builder_begin_array(b);
  for (auto &[id, t] : transfers) {
    auto s = t.status();
    auto info = t.info();
    json_builder_begin_object(b);
    member(b, "id", id);
    member(b, "name",
           s.name.empty() ? "Fetching file list…" : display_name(s.name));
    member(b, "source", t.source);
    member(b, "download_directory", t.destination);
    member(b, "destination", t.published ? t.publication : t.destination);
    member(b, "storage", s.save_path);
    member(b, "error",
           t.error.empty() ? (s.errc ? s.errc.message() : "") : t.error);
    boolean(b, "pending", t.pending);
    boolean(b, "metadata", bool(info));
    boolean(b, "paused", bool(s.flags & lt::torrent_flags::paused));
    boolean(b, "finished", s.is_finished);
    boolean(b, "published", t.published);
    number(b, "progress", s.progress_ppm);
    number(b, "download_rate", s.download_payload_rate);
    number(b, "upload_rate", s.upload_payload_rate);
    number(b, "peers", s.num_peers);
    number(b, "known_peers", s.list_peers);
    number(b, "seeds", s.num_seeds);
    number(b, "total", s.total_wanted);
    number(b, "done", s.total_wanted_done);
    number(b, "ratio", t.ratio);
    number(b, "limit", t.limit);
    json_builder_set_member_name(b, "files");
    json_builder_begin_array(b);
    if (t.pending && t.error.empty() && info &&
        info->num_files() <= int(max_files))
      for (auto index : info->files().file_range()) {
        if (info->files().pad_file_at(index))
          continue;
        json_builder_begin_object(b);
        number(b, "index", int(index));
        member(b, "path", info->files().file_path(index));
        number(b, "size", info->files().file_size(index));
        json_builder_end_object(b);
      }
    json_builder_end_array(b);
    json_builder_end_object(b);
  }
  json_builder_end_array(b);
  json_builder_end_object(b);
  return encode(b);
}
static void send_error(int fd, std::string const &error) {
  auto b = json_builder_new();
  json_builder_begin_object(b);
  member(b, "error", error);
  json_builder_end_object(b);
  auto data = encode(b);
  (void)send(fd, data.data(), data.size(), MSG_NOSIGNAL | MSG_DONTWAIT);
}
static void drop_peer(int fd) {
  auto it = peers.find(fd);
  if (it == peers.end())
    return;
  g_source_remove(it->second.source);
  close(fd);
  peers.erase(it);
}
static gboolean peer_ready(gint fd, GIOCondition condition, gpointer) {
  char data[max_packet];
  auto n = recv(fd, data, sizeof data, MSG_DONTWAIT | MSG_TRUNC);
  // On SOCK_SEQPACKET, closing with unread replies can report ECONNRESET
  // before the already queued requests. Consume the error, then drain them.
  if (n < 0 && (errno == ECONNRESET || errno == EINTR))
    return G_SOURCE_CONTINUE;
  if (n < 0 && errno == EAGAIN && !(condition & (G_IO_HUP | G_IO_ERR)))
    return G_SOURCE_CONTINUE;
  if (n <= 0 || size_t(n) >= sizeof data) {
    drop_peer(fd);
    schedule();
    return G_SOURCE_REMOVE;
  }
  auto parser = json_parser_new();
  GError *error = nullptr;
  try {
    if (!json_parser_load_from_data(parser, data, n, &error))
      throw std::runtime_error("Invalid transfer request");
    auto root = json_parser_get_root(parser);
    if (!JSON_NODE_HOLDS_OBJECT(root))
      throw std::runtime_error("Invalid request");
    command(json_node_get_object(root));
  } catch (std::exception const &e) {
    send_error(fd, e.what());
  }
  g_clear_error(&error);
  g_object_unref(parser);
  publish();
  schedule();
  return G_SOURCE_CONTINUE;
}
gboolean accept_peer(gint fd, GIOCondition, gpointer) {
  int client = accept4(fd, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
  if (client < 0)
    return G_SOURCE_CONTINUE;
  uid_t uid = 0;
  if (peers.size() >= 32 || rediwm_peer_credentials(client, &uid, nullptr) ||
      uid != getuid()) {
    close(client);
    return G_SOURCE_CONTINUE;
  }
  int buffer = 512 * 1024;
  setsockopt(client, SOL_SOCKET, SO_SNDBUF, &buffer, sizeof buffer);
  peers.emplace(
      client,
      Peer{client,
           g_unix_fd_add(client, GIOCondition(G_IO_IN | G_IO_HUP | G_IO_ERR),
                         peer_ready, nullptr)});
  publish();
  schedule();
  return G_SOURCE_CONTINUE;
}

void publish() {
  auto data = snapshot();
  std::vector<int> lost;
  for (auto const &[fd, p] : peers) {
    if (data.size() > max_packet) {
      lost.push_back(fd);
      continue;
    }
    const auto sent =
        send(fd, data.data(), data.size(), MSG_NOSIGNAL | MSG_DONTWAIT);
    // A closed reader may still have queued commands (e.g. pause followed by
    // window close). Drain those through peer_ready before closing its fd.
    if (sent != ssize_t(data.size()) && errno != EPIPE && errno != ECONNRESET)
      lost.push_back(fd);
  }
  for (auto fd : lost)
    drop_peer(fd); // A stalled reader never blocks the engine.
  int active = 0, downloading = 0;
  int64_t down = 0, up = 0;
  for (auto &[id, t] : transfers) {
    auto s = t.status();
    if (!(s.flags & lt::torrent_flags::paused)) {
      ++active;
      if (!s.is_finished)
        ++downloading;
      down += s.download_payload_rate;
      up += s.upload_payload_rate;
    }
  }
  if (active && !bus)
    init_tray();
  auto status = active ? "Active" : "Passive";
  tray_title = std::to_string(active) + " active · ↓ " +
               std::to_string(down / 1024) + " KiB/s · ↑ " +
               std::to_string(up / 1024) + " KiB/s";
  const bool upload = active && !downloading;
  const bool icon_changed = tray_upload != upload;
  tray_upload = upload;
  if (bus) {
    if (icon_changed)
      g_dbus_connection_emit_signal(bus, nullptr, "/StatusNotifierItem",
                                    item_iface, "NewIcon", nullptr, nullptr);
    if (tray_status != status)
      g_dbus_connection_emit_signal(bus, nullptr, "/StatusNotifierItem",
                                    item_iface, "NewStatus",
                                    g_variant_new("(s)", status), nullptr);
    g_dbus_connection_emit_signal(bus, nullptr, "/StatusNotifierItem",
                                  item_iface, "NewToolTip", nullptr, nullptr);
  }
  tray_status = status;
}

} // namespace helper
