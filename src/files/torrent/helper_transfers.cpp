// Transfers: adding, configuring, persisting and restoring them, and the
// commands Files sends. Part of rediwm-transfers (helper.cpp).
#include "helper.hpp"

namespace helper {

void request_save(Transfer &t) {
  if (t.handle.is_valid()) {
    ++saves[t.id];
    t.handle.save_resume_data(lt::torrent_handle::save_info_dict);
  }
}
void finish_configuration(Transfer &t) {
  t.configuring = false;
  t.pending = false;
  t.requested_priorities.clear();
  t.handle.set_upload_limit(t.limit);
  t.handle.unset_flags(lt::torrent_flags::upload_mode);
  if (t.start_after_priority) {
    t.handle.resume();
    // Peers now, not at the next interval (minutes for a finished one).
    t.handle.force_reannounce(0, -1, lt::torrent_handle::ignore_min_interval);
  }
  persist(t);
  request_save(t);
}
static std::string hash_id(lt::info_hash_t const &h) {
  std::ostringstream out;
  if (h.has_v2())
    out << h.v2;
  else
    out << h.v1;
  return out.str();
}
void atomic_write(std::string const &path, std::string const &data) {
  auto tmp = path + ".tmp";
  int fd = open(tmp.c_str(),
                O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0)
    throw std::runtime_error("Cannot save transfer state");
  size_t n = 0;
  while (n < data.size()) {
    auto r = write(fd, data.data() + n, data.size() - n);
    if (r <= 0) {
      close(fd);
      throw std::runtime_error("Cannot save transfer state");
    }
    n += size_t(r);
  }
  bool ok = fsync(fd) == 0;
  close(fd);
  if (!ok || rename(tmp.c_str(), path.c_str()))
    throw std::runtime_error("Cannot save transfer state");
}
void persist(Transfer &t) {
  GKeyFile *key = g_key_file_new();
  g_key_file_set_string(key, "transfer", "source", t.source.c_str());
  g_key_file_set_string(key, "transfer", "destination", t.destination.c_str());
  g_key_file_set_string(key, "transfer", "publication", t.publication.c_str());
  g_key_file_set_boolean(key, "transfer", "pending", t.pending);
  g_key_file_set_boolean(key, "transfer", "published", t.published);
  g_key_file_set_integer(key, "transfer", "ratio", t.ratio);
  g_key_file_set_integer(key, "transfer", "limit", t.limit);
  gsize n;
  char *data = g_key_file_to_data(key, &n, nullptr);
  try {
    atomic_write(state_dir + "/" + t.id + ".ini", std::string(data, n));
  } catch (...) {
    g_free(data);
    g_key_file_unref(key);
    throw;
  }
  g_free(data);
  g_key_file_unref(key);
}
void validate(lt::torrent_info const &info) {
  if (info.num_files() > int(max_files))
    throw std::runtime_error("This torrent exceeds the 512 file limit");
  auto const &files = info.files();
  for (auto i : files.file_range()) {
    fs::path path(files.file_path(i));
    if (path.is_absolute() || path.empty() ||
        (files.file_flags(i) & lt::file_storage::flag_symlink))
      throw std::runtime_error("Unsafe torrent file path");
    for (auto const &part : path)
      if (part == ".." || part == "." || part.empty())
        throw std::runtime_error("Unsafe torrent file path");
  }
}
/// A local torrent file's metadata, checked like a transfer's.
static std::shared_ptr<lt::torrent_info> load(std::string const &source) {
  if (source.empty() || source[0] != '/' || !fs::is_regular_file(source) ||
      fs::file_size(source) > 8 * 1024 * 1024)
    throw std::runtime_error("Choose a local torrent file (maximum 8 MiB)");
  lt::error_code ec;
  auto info = std::make_shared<lt::torrent_info>(source, ec);
  if (ec)
    throw std::runtime_error(ec.message());
  validate(*info);
  return info;
}
static std::string add(std::string const &source,
                       std::string const &destination) {
  if (transfers.size() >= max_torrents)
    throw std::runtime_error("Transfer limit reached (64)");
  if (destination.empty() || destination[0] != '/' ||
      !fs::is_directory(destination))
    throw std::runtime_error("Choose an existing absolute destination folder");
  lt::add_torrent_params p;
  lt::error_code ec;
  if (source.rfind("magnet:?", 0) == 0) {
    p = lt::parse_magnet_uri(source, ec);
    if (ec)
      throw std::runtime_error(ec.message());
  } else {
    p.ti = load(source);
    p.info_hashes = p.ti->info_hashes();
  }
  auto id = hash_id(p.info_hashes);
  if (transfers.count(id))
    throw std::runtime_error("This torrent is already in Transfers");
  auto staging = fs::path(destination) / ".rediwm-partials" / id;
  // A private, exclusive staging directory avoids treating incomplete payloads
  // as ordinary files and prevents an existing file from being overwritten.
  auto parent = staging.parent_path();
  if (fs::exists(parent)) {
    struct stat st{};
    if (lstat(parent.c_str(), &st) || !S_ISDIR(st.st_mode) ||
        st.st_uid != getuid() || (st.st_mode & 077))
      throw std::runtime_error("Unsafe partial-download directory");
  } else if (mkdir(parent.c_str(), 0700))
    throw std::runtime_error("Cannot create partial-download directory");
  if (mkdir(staging.c_str(), 0700))
    throw std::runtime_error(
        "Partial data already exists; choose another destination");
  p.save_path = staging.string();
  p.flags &= ~lt::torrent_flags::auto_managed;
  p.flags |=
      lt::torrent_flags::upload_mode | lt::torrent_flags::duplicate_is_error;
  if (p.ti)
    p.file_priorities.assign(p.ti->num_files(), lt::dont_download);
  if (!p.ti)
    p.flags &= ~lt::torrent_flags::paused;
  auto handle = session->add_torrent(p, ec);
  if (ec) {
    fs::remove(staging);
    throw std::runtime_error(ec.message());
  }
  Transfer t{handle, id, source, destination};
  transfers.emplace(id, std::move(t));
  if (snapshot().size() > max_packet - 4096) {
    session->remove_torrent(handle);
    transfers.erase(id);
    throw std::runtime_error("Transfer metadata exceeds the session limit; "
                             "remove an unused transfer first");
  }
  persist(transfers.at(id));
  request_save(transfers.at(id));
  return id;
}
static std::string string_member(JsonObject *o, char const *name) {
  auto node = json_object_get_member(o, name);
  if (!node || json_node_get_value_type(node) != G_TYPE_STRING)
    throw std::runtime_error("Missing string field");
  return json_node_get_string(node);
}
/// The priorities `files` asks for: those listed download, the rest not.
static std::vector<lt::download_priority_t>
chosen(JsonObject *o, lt::torrent_info const &info) {
  auto node = json_object_get_member(o, "files");
  if (!node || !JSON_NODE_HOLDS_ARRAY(node))
    throw std::runtime_error("Choose at least one file");
  auto arr = json_node_get_array(node);
  std::vector<lt::download_priority_t> priorities(info.num_files(),
                                                  lt::dont_download);
  for (guint i = 0; i < json_array_get_length(arr); ++i) {
    auto index = json_array_get_int_element(arr, i);
    if (index < 0 || index >= info.num_files())
      throw std::runtime_error("Invalid file index");
    priorities[size_t(index)] = lt::default_priority;
  }
  return priorities;
}
static bool any_wanted(std::vector<lt::download_priority_t> const &p) {
  for (auto v : p)
    if (v != lt::dont_download)
      return true;
  return false;
}
/// Applies `priorities` to a transfer. File priorities become effective
/// asynchronously, after disk work: until the matching alert it stays
/// upload-only and paused, so unwanted files never briefly inherit the
/// default priority. `run` resumes it then.
static void configure(Transfer &t,
                      std::vector<lt::download_priority_t> const &priorities,
                      bool run) {
  t.configuring = true;
  t.start_after_priority = run;
  t.requested_priorities = priorities;
  t.handle.set_flags(lt::torrent_flags::upload_mode);
  t.handle.pause();
  if (t.handle.get_file_priorities() == priorities)
    finish_configuration(t);
  else
    t.handle.prioritize_files(priorities);
}
/// Starts a pending transfer with the files in `o` and its seeding limits.
static void start(Transfer &t, JsonObject *o) {
  auto info = t.info();
  if (!t.pending || !info || t.configuring)
    throw std::runtime_error("Waiting for torrent metadata");
  validate(*info);
  auto priorities = chosen(o, *info);
  if (!any_wanted(priorities))
    throw std::runtime_error("Choose at least one file");
  auto ratio = int(json_object_get_int_member_with_default(o, "ratio", 1));
  auto limit =
      int(json_object_get_int_member_with_default(o, "limit", 1048576));
  if (ratio < 0 || ratio > 2 || limit < 16384 || limit > 10485760)
    throw std::runtime_error("Invalid seeding limits");
  t.ratio = ratio;
  t.limit = limit;
  configure(t, priorities, true);
}
/// Changes which files of a started (or starting) transfer download. Files no longer
/// wanted keep what they have; newly wanted ones make a finished, stopped
/// transfer download again. A transfer paused by the user stays paused.
static void select(Transfer &t, JsonObject *o) {
  // Still starting: the new choice replaces the one being applied.
  if (t.pending && !t.configuring)
    return start(t, o);
  auto info = t.info();
  if (!info)
    throw std::runtime_error("Waiting for torrent metadata");
  auto priorities = chosen(o, *info);
  if (!any_wanted(priorities))
    throw std::runtime_error(
        "Keep at least one file, or remove the download");
  auto s = t.status();
  auto old = t.configuring ? t.requested_priorities
                           : t.handle.get_file_priorities();
  bool more = false;
  for (size_t i = 0; i < priorities.size(); ++i)
    more = more || (priorities[i] != lt::dont_download &&
                    (i >= old.size() || old[i] == lt::dont_download));
  bool paused = bool(s.flags & lt::torrent_flags::paused);
  bool run = t.configuring ? t.start_after_priority
                           : !paused || (more && s.is_finished);
  t.resume_after_publish = false;
  // A seed forgets peers that were seeds too, and never asks them again;
  // the announce after configuring finds them afresh.
  if (more && s.is_finished)
    t.handle.clear_peers();
  configure(t, priorities, run);
}
std::string command(JsonObject *o) {
  auto op = string_member(o, "op");
  if (op == "list")
    return {};
  if (op == "inspect") {
    auto source = string_member(o, "source");
    auto info = load(source);
    auto id = hash_id(info->info_hashes());
    return inspection(*info, id, source);
  }
  if (op == "files") {
    auto it = transfers.find(string_member(o, "id"));
    if (it == transfers.end())
      throw std::runtime_error("Transfer no longer exists");
    return detail(it->second);
  }
  wake_engine();
  if (op == "add") {
    auto id = add(string_member(o, "source"), string_member(o, "destination"));
    // Files chosen with the torrent file start at once.
    if (json_object_has_member(o, "files"))
      start(transfers.at(id), o);
    return {};
  }
  if (op == "pause_all" || op == "stop_seeding") {
    for (auto &[id, t] : transfers)
      if (op == "pause_all" || t.status().is_finished) {
        t.resume_after_publish = false;
        t.start_after_priority = false;
        t.handle.pause();
        request_save(t);
      }
    return {};
  }
  auto id = string_member(o, "id");
  auto it = transfers.find(id);
  if (it == transfers.end())
    throw std::runtime_error("Transfer no longer exists");
  auto &t = it->second;
  if (op == "remove") {
    session->remove_torrent(t.handle); // Never delete payloads.
    fs::remove(state_dir + "/" + id + ".ini");
    fs::remove(state_dir + "/" + id + ".resume");
    saves.erase(id);
    transfers.erase(it);
    return {};
  }
  if (op == "pause") {
    t.resume_after_publish = false;
    t.start_after_priority = false;
    t.handle.pause();
  } else if (op == "resume") {
    if (t.pending)
      throw std::runtime_error("Choose files and start the download first");
    t.error.clear();
    t.handle.clear_error();
    t.handle.resume();
  } else if (op == "start") {
    start(t, o);
    return {};
  } else if (op == "select") {
    select(t, o);
    return {};
  } else
    throw std::runtime_error("Unknown command");
  persist(t);
  request_save(t);
  return {};
}

void publish_storage(Transfer &t) {
  // Publish the entire private staging directory in one no-replace
  // rename. libtorrent's fail_if_exist has a check/rename race.
  auto s = t.status();
  auto name = fs::path(s.name).filename().string();
  if (name.empty() || name == "." || name == "..")
    name = t.id;
  name.resize(std::min<size_t>(name.size(), 160));
  while (!name.empty() && !g_utf8_validate(name.c_str(), name.size(), nullptr))
    name.pop_back();
  if (name.empty())
    name = t.id;
  t.publication = (fs::path(t.destination) / (name + ".download")).string();
  try {
    persist(t); // recovery knows both locations before the rename
    if (syscall(SYS_renameat2, AT_FDCWD, s.save_path.c_str(), AT_FDCWD,
                t.publication.c_str(), RENAME_NOREPLACE))
      throw std::runtime_error("Destination already exists or cannot be "
                               "written; partial files are kept");
    t.handle.move_storage(t.publication,
                          lt::move_flags_t::reset_save_path_unchecked);
  } catch (std::exception const &e) {
    t.moving = false;
    t.error = e.what();
    t.handle.pause();
    request_save(t);
  }
}

void restore() {
  for (auto const &entry : fs::directory_iterator(state_dir)) {
    if (entry.path().extension() != ".ini" || transfers.size() >= max_torrents)
      continue;
    try {
      auto id = entry.path().stem().string();
      if (id.size() != 40 && id.size() != 64)
        continue;
      auto key = g_key_file_new();
      if (!g_key_file_load_from_file(key, entry.path().c_str(), G_KEY_FILE_NONE,
                                     nullptr)) {
        g_key_file_unref(key);
        continue;
      }
      auto get = [&](char const *name) {
        char *p = g_key_file_get_string(key, "transfer", name, nullptr);
        std::string s = p ? p : "";
        g_free(p);
        return s;
      };
      Transfer t;
      t.id = id;
      t.source = get("source");
      t.destination = get("destination");
      t.publication = get("publication");
      t.pending = g_key_file_get_boolean(key, "transfer", "pending", nullptr);
      t.published =
          g_key_file_get_boolean(key, "transfer", "published", nullptr);
      t.ratio = g_key_file_get_integer(key, "transfer", "ratio", nullptr);
      t.limit = g_key_file_get_integer(key, "transfer", "limit", nullptr);
      g_key_file_unref(key);
      auto path = state_dir + "/" + id + ".resume";
      if (!fs::exists(path) || fs::file_size(path) > 16 * 1024 * 1024)
        continue;
      std::ifstream file(path, std::ios::binary);
      std::vector<char> data((std::istreambuf_iterator<char>(file)), {});
      lt::error_code ec;
      auto p = lt::read_resume_data(data, ec);
      if (ec)
        continue;
      if (p.ti)
        validate(*p.ti);
      // A crash between atomic publication and the next resume alert must
      // not redownload into the now-missing staging directory.
      if (!t.publication.empty() && !fs::exists(p.save_path) &&
          fs::is_directory(t.publication)) {
        p.save_path = t.publication;
        t.published = true;
      }
      p.flags &= ~lt::torrent_flags::auto_managed;
      if (t.pending) {
        p.flags |= lt::torrent_flags::upload_mode;
        if (p.ti)
          p.flags |= lt::torrent_flags::paused;
      }
      create_engine();
      t.handle = session->add_torrent(p, ec);
      if (!ec)
        transfers.insert_or_assign(id, std::move(t));
    } catch (std::exception const &e) {
      std::cerr << "Restore transfer: " << e.what() << '\n';
    }
  }
}

} // namespace helper
