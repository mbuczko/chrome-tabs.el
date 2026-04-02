# chrome-tabs.el

An Emacs package to switch Chrome tabs and open bookmarks from the minibuffer.

It communicates with a companion Rust HTTP server ([chrome-tabs](https://github.com/chrome-tabs/chrome-tabs)) that exposes your Chrome session via a local JSON API.

## Features

- `M-x chrome-tabs-switch` — fuzzy-select any open Chrome tab and bring it into focus
- `M-x chrome-tabs-open-bookmark` — fuzzy-select a Chrome bookmark and open it in Chrome

Both commands use Emacs' built-in `completing-read`, so they work with Ivy, Vertico, Consult, Helm, or the default minibuffer.

## Requirements

- Emacs 27.1+
- The [chrome-tabs](https://github.com/mbuczko/chrome-tabs) Rust server running locally

## Installation

### Manual

Clone the repo and add it to your load path:

```emacs-lisp
(add-to-list 'load-path "/path/to/chrome-tabs.el")
(require 'chrome-tabs)
```

### use-package

```emacs-lisp
(use-package chrome-tabs
  :load-path "/path/to/chrome-tabs.el")
```

## Setup

Start the companion server before using the package. The server must be running for any commands to work:

```sh
./chrome-tabs
# Listens on 127.0.0.1:9223 by default
```

## Usage

| Command                       | Description                                      |
|-------------------------------|--------------------------------------------------|
| `M-x chrome-tabs-switch`      | Select an open tab by title/URL and focus it     |
| `M-x chrome-tabs-open-bookmark` | Select a bookmark by title/folder/URL and open it |

## Configuration

```emacs-lisp
;; Default: "http://127.0.0.1:9223"
(setq chrome-tabs-server-url "http://127.0.0.1:9223")
```

Or via `M-x customize-group RET chrome-tabs`.

### Authentication

If the server requires a Bearer token, add an entry to `~/.authinfo`:

```
machine 127.0.0.1 login chrome_tabs port 9223 password YOUR_TOKEN_HERE
```

The package looks up the entry by `login chrome_tabs`, uses `password` as the Authorization Bearer token, and overrides the port in `chrome-tabs-server-url` with the `port` value from the entry.

## API

The package exposes a small Emacs Lisp API for scripting:

```emacs-lisp
;; List open tabs (returns a list of plists)
(chrome-tabs-list)
;; => ((:title "GitHub" :url "https://github.com" :window_index 0 :tab_index 0) ...)

;; Focus a specific tab
(chrome-tabs-focus 0 2)

;; List bookmarks
(chrome-tabs-list-bookmarks)
;; => ((:title "Emacs Wiki" :url "https://emacswiki.org" :folder "Dev") ...)
```

## License

GPL-3.0-or-later
