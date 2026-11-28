// What the parts of rediwm-transfers share (helper.cpp has the overview): the
// transfers, the subscribed Files windows and the state on the main loop. It is
// all in namespace helper, so none of it is exported under a bare name.
#pragma once
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <gio/gio.h>
#include <glib-unix.h>
#include <iostream>
#include <json-glib/json-glib.h>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <linux/fs.h>
#include <map>
#include <memory>
#include <set>
#include <signal.h>
#include <sstream>
#include <sys/eventfd.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>
namespace lt = libtorrent;
namespace fs = std::filesystem;

namespace helper {

inline constexpr size_t max_packet = 192 * 1024;
inline constexpr size_t max_files = 512, max_torrents = 64;

enum class DeletionMode {
  none,
  trash,
  permanent,
};

enum class DeletionPhase {
  none,
  waiting_storage,
  waiting_pause,
  waiting_flush,
  waiting_disk,
  ready,
  failed,
};

struct Transfer {
  lt::torrent_handle handle;
  std::string id, source, destination, error, publication;
  bool pending = true, published = false, moving = false,
       resume_after_publish = false;
  bool configuring = false, start_after_priority = false;
  bool storage_move_submitted = false;
  std::vector<lt::download_priority_t> requested_priorities;
  int ratio = 1, limit = 1024 * 1024;
  lt::torrent_status cached;
  std::shared_ptr<lt::torrent_info const> cached_info;
  /// Per-file bytes and priorities, kept while the engine sleeps.
  std::vector<int64_t> cached_progress;
  std::vector<lt::download_priority_t> cached_priorities;
  DeletionMode deletion_mode = DeletionMode::none;
  DeletionPhase deletion_phase = DeletionPhase::none;
  bool deletion_probe = false;

  bool deleting() const {
    return deletion_phase != DeletionPhase::none;
  }

  bool deletion_active() const {
    return deleting() && deletion_phase != DeletionPhase::failed;
  }

  void cache_transfer() {
    cached = handle.status();
    cached_info = handle.torrent_file();
    cached_progress.clear();
    if (cached_info)
      handle.file_progress(cached_progress,
                           lt::torrent_handle::piece_granularity);
    cached_priorities = handle.get_file_priorities();
  }

  lt::torrent_status status() const {
    return handle.is_valid() ? handle.status() : cached;
  }
  std::shared_ptr<lt::torrent_info const> info() const {
    return handle.is_valid() ? handle.torrent_file() : cached_info;
  }
};
struct Peer {
  int fd;
  guint source;
};
inline std::map<std::string, Transfer> transfers;
inline std::map<int, Peer> peers;
inline std::unique_ptr<lt::session> session;
inline GDBusConnection *bus;
inline std::string state_dir;
inline std::map<std::string, unsigned> saves;
inline bool use_scopes = false;

// helper.cpp
void create_engine();
void wake_engine();
void schedule();
void advance_deletion(Transfer &t);

// helper_transfers.cpp
void request_save(Transfer &t);
void finish_configuration(Transfer &t);
void atomic_write(std::string const &path, std::string const &data);
void persist(Transfer &t);
void persist_deletion_manifest(Transfer &t);
void validate(lt::torrent_info const &info);
/// Runs one request. A non-empty result is a reply for the requester alone
/// (and nothing changed, so nothing is published).
std::string command(JsonObject *o);
void publish_storage(Transfer &t);
void restore();

// helper_peers.cpp
std::string snapshot();
/// The `inspect` reply for a torrent file that is not a transfer (yet).
std::string inspection(lt::torrent_info const &info, std::string const &id,
                       std::string const &source);
/// The `detail` reply: every file of a transfer, with what is wanted and done.
std::string detail(Transfer &t);
gboolean accept_peer(gint fd, GIOCondition, gpointer);
void publish();

// helper_session.cpp
void place_scope(pid_t pid, char const *app);
GDBusConnection *session_bus();

} // namespace helper
