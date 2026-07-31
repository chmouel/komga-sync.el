# komga-sync.el

`komga-sync` keeps EPUB reading positions in Emacs `nov-mode` synchronized
with a Komga server. It uses Komga's Readium progression API, so positions
written by Emacs are available to Komga's web reader and other clients, and
positions written elsewhere can be pulled back into Emacs.

Local EPUBs are matched to Komga books through saved links, file content, or
an exact file-size match against the Komga library. The API key is obtained
through `password-store` by default and is never written to disk or passed on
the command line.

## Requirements

- Emacs 29.1 or newer
- [`nov.el`](https://depp.brause.cc/nov.el/)
- [`password-store`](https://github.com/DamienCassou/password-store)
- `curl`

## Installation

With `use-package` and `package-vc`:

```elisp
(use-package komga-sync
  :vc (:url "https://github.com/chmouel/komga-sync.el" :rev :newest)
  :custom
  (komga-sync-server-url "https://books.example.com")
  :hook
  (nov-mode . komga-sync-mode))
```

For a manual installation, clone the repository into a directory on
`load-path`, then load and enable it:

```elisp
(add-to-list 'load-path "/path/to/komga-sync.el")
(require 'komga-sync)
(setq komga-sync-server-url "https://books.example.com")
(add-hook 'nov-mode-hook #'komga-sync-mode)
```

By default, the API key is read from the `komga/api_key` entry in `pass`.

## Configuration

Use `M-x customize-group RET komga-sync` or set these variables in your Emacs
configuration:

| Variable | Purpose | Default |
| --- | --- | --- |
| `komga-sync-server-url` | Komga server base URL | `nil` |
| `komga-sync-api-key-entry` | `pass` entry containing the API key | `komga/api_key` |
| `komga-sync-api-key-function` | Function that returns the API key | `komga-sync-api-key-from-pass` |
| `komga-sync-state-directory` | Persistent book links and sync state | `komga-sync/` under `user-emacs-directory` |
| `komga-sync-cache-directory` | Regenerable library index and device data | `$XDG_CACHE_HOME/komga-sync/` or `~/.cache/komga-sync/` |
| `komga-sync-device-name` | Device name reported to Komga | `<hostname> (Emacs)` |
| `komga-sync-idle-delay` | Idle seconds before an automatic push; `nil` disables it | `5` |
| `komga-sync-push-on-chapter-change` | Push when changing chapters | `t` |
| `komga-sync-push-on-exit` | Push when closing a buffer or Emacs | `t` |
| `komga-sync-pull-on-open` | Handle differing remote progress with `prompt`, `auto`, `message`, or `nil` | `prompt` |
| `komga-sync-auto-link` | Match unlinked EPUBs automatically | `t` |
| `komga-sync-timeout` | Normal request timeout in seconds | `20` |
| `komga-sync-exit-timeout` | Exit-time push timeout in seconds | `5` |
| `komga-sync-debug` | Write request and decision details to the log buffer | `nil` |
| `komga-sync-log-buffer` | Debug log buffer name | `*komga-sync-log*` |

## Commands

| Command | Action |
| --- | --- |
| `komga-sync-push` | Push the current reading position to Komga. |
| `komga-sync-pull` | Move to the reading position stored on Komga. |
| `komga-sync-link-book` | Choose the Komga book matching the current EPUB. |
| `komga-sync-unlink-book` | Forget the current EPUB's Komga link. |
| `komga-sync-refresh-library-index` | Refresh the cached list used for matching. |
| `komga-sync-status` | Report the current link, positions, and conflicts. |

## Limitations

- Positions created in Emacs restore exactly in Emacs. Positions from other
  readers are approximate because Komga measures raw XHTML bytes while
  `nov-mode` renders text.
- The local EPUB should be the same build as Komga's copy. Different builds
  may have different document paths; pulls become approximate and Komga may
  reject pushes.
- Only books already present in the Komga library can be synchronized.
- Komga rejects stale writes with HTTP 409. Automatic pushes remain disabled
  after a conflict until an explicit pull or confirmed push resolves it.
- Server timestamps are not compared with local time because Komga 1.25.0
  returned a timezone-skewed `modified` value during testing. Remote changes
  are detected by comparing locators instead.
- Requests use `curl`; the built-in Emacs URL client hung against the server
  used during development.
- Persistent book links and the per-machine cache are intentionally stored in
  separate directories.
- KOReader hashes are not used for matching because Komga only provides them
  when the library enables `hashKoreader`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
