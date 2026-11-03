RediWM experimental SteamOS 3.8 portable bundle (x86_64)

Extract the tarball in Desktop Mode and run ./rediwm-steamos/install as your
normal user. It copies the bundle to ~/.local/opt/rediwm-steamos. No sudo,
read-only filesystem changes, system packages, or session registration.

Run ~/.local/opt/rediwm-steamos/run --check to verify library resolution.
Then run ~/.local/opt/rediwm-steamos/run from KDE's Wayland session. RediWM
opens nested. Super+Shift+E quits. Test Files, Images, Editor and PDF using
the launcher. Verify display, keyboard, pointer and app launch behavior before
considering full desktop session integration. KDE testing on a real Deck is
required; a successful library check alone does not qualify Deck support.

Settings/state are under ~/.local/share/rediwm-steamos-test and cache under
~/.cache/rediwm-steamos-test. Remove these and ~/.local/opt/rediwm-steamos to
uninstall. No desktop entries or file associations are installed.

Git integration and the torrent transfers helper are omitted. Login/session
management and privileged account changes are not supported by this bundle.
Host Mesa, audio and other runtime libraries remain required. A missing
library reported by --check is a packaging issue: report it rather than
unlocking SteamOS or upgrading its system packages.

Maintainers: sh scripts/make-steamos-bundle.sh builds the current checkout in
an isolated container using Valve's versioned 3.8 repositories. These are
mutable: BUILD-PACKAGES.txt records exact package versions. Repository
signature checks are disabled only inside this disposable build container
(the bootstrap Arch keyring lacks Valve keys); downloads use Valve HTTPS.
wlroots and fallback sources are pinned and SHA256 checked by the build.
