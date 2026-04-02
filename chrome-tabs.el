;;; chrome-tabs.el --- Switch Chrome tabs and open bookmarks from Emacs -*- lexical-binding: t -*-

;; Author: Michał Buczko
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: browser, chrome, tabs, bookmarks
;; URL: https://github.com/mbuczko/chrome-tabs.el

;;; Commentary:
;;
;; Client for the chrome-tabs Rust server.
;; The server must be running on `chrome-tabs-server-url'.
;;
;; Usage:
;;   M-x chrome-tabs-switch          — select and focus a Chrome tab
;;   M-x chrome-tabs-open-bookmark   — select a bookmark and open it in Chrome
;;
;; Start the server with:
;;   ./chrome-tabs   (listens on 127.0.0.1:9223 by default)

;;; Code:

(require 'json)
(require 'url)
(require 'browse-url)

(defgroup chrome-tabs nil
  "Switch Chrome tabs and open bookmarks from Emacs."
  :group 'tools
  :prefix "chrome-tabs-")

(defcustom chrome-tabs-server-url "http://127.0.0.1:9223"
  "Base URL of the chrome-tabs server."
  :type 'string
  :group 'chrome-tabs)

;;; Auth helpers

(defun chrome-tabs--authinfo-credentials ()
  "Return (PORT . TOKEN) from auth sources for the `chrome_tabs' login.
Looks for an entry with login `chrome_tabs' in any auth source.
Returns a cons cell (PORT . TOKEN), or nil if no matching entry is found."
  (require 'auth-source)
  (let ((results (auth-source-search :user "chrome_tabs" :max 1)))
    (when results
      (let* ((entry (car results))
             (port  (let ((p (plist-get entry :port)))
                      (when p (format "%s" p))))
             (token (let ((s (plist-get entry :secret)))
                      (when s (if (functionp s) (funcall s) s)))))
        (when (and port token)
          (cons port token))))))

(defun chrome-tabs--effective-url ()
  "Return the server base URL, with port overridden from ~/.authinfo when available."
  (let ((creds (chrome-tabs--authinfo-credentials)))
    (if creds
        (let* ((parsed (url-generic-parse-url chrome-tabs-server-url))
               (host   (url-host parsed)))
          (format "http://%s:%s" host (car creds)))
      chrome-tabs-server-url)))

;;; HTTP helpers

(defun chrome-tabs--auth-headers ()
  "Return an alist of extra headers including Authorization if a token is found."
  (let ((creds (chrome-tabs--authinfo-credentials)))
    (when creds
      `(("Authorization" . ,(concat "Bearer " (cdr creds)))))))

(defun chrome-tabs--get (path)
  "Make a synchronous GET request to PATH on the server.
Returns the parsed JSON response as a Lisp object, or signals an error."
  (let* ((url (concat (chrome-tabs--effective-url) path))
         (url-request-method "GET")
         (url-show-status nil)
         (url-request-extra-headers (chrome-tabs--auth-headers))
         (buffer (url-retrieve-synchronously url t)))
    (unless buffer
      (error "chrome-tabs: could not connect to server at %s" url))
    (chrome-tabs--parse-response buffer)))

(defun chrome-tabs--post (path body)
  "Make a synchronous POST request to PATH with JSON BODY on the server.
BODY is a Lisp object that will be JSON-encoded.
Returns the parsed JSON response, or signals an error."
  (let* ((url (concat (chrome-tabs--effective-url) path))
         (url-request-method "POST")
         (url-show-status nil)
         (url-request-extra-headers (append '(("Content-Type" . "application/json"))
                                            (chrome-tabs--auth-headers)))
         (url-request-data (encode-coding-string (json-encode body) 'utf-8))
         (buffer (url-retrieve-synchronously url t)))
    (unless buffer
      (error "chrome-tabs: could not connect to server at %s" url))
    (chrome-tabs--parse-response buffer)))

(defun chrome-tabs--parse-response (buffer)
  "Parse HTTP response in BUFFER, return decoded JSON or signal an error."
  (unwind-protect
      (with-current-buffer buffer
        (set-buffer-multibyte t)
        (goto-char (point-min))
        ;; Skip HTTP headers (separated from body by blank line)
        (unless (re-search-forward "\r?\n\r?\n" nil t)
          (error "chrome-tabs: malformed HTTP response"))
        (let* ((body (decode-coding-string
                      (buffer-substring-no-properties (point) (point-max))
                      'utf-8))
               (json-object-type 'plist)
               (json-array-type  'list)
               (json-key-type    'keyword))
          (condition-case err
              (json-read-from-string body)
            (error
             (error "chrome-tabs: failed to parse response: %s\nbody: %s"
                    (error-message-string err) body)))))
    (kill-buffer buffer)))

;;; Core API

(defun chrome-tabs-list ()
  "Return a list of open tabs from the server.
Each tab is a plist with :title, :url, :window_index, :tab_index."
  (chrome-tabs--get "/tabs"))

(defun chrome-tabs-focus (window-id tab-index)
  "Focus the Chrome tab at WINDOW-INDEX and TAB-INDEX."
  (chrome-tabs--post "/focus" `((window_id    . ,window-id)
                                (tab_index    . ,tab-index))))

(defun chrome-tabs-list-bookmarks ()
  "Return a list of bookmarks from the server.
Each bookmark is a plist with :title, :url, :folder."
  (chrome-tabs--get "/bookmarks"))

;;; Completion helpers

(defun chrome-tabs--build-table (items label-fn)
  "Build a (candidates . table) cons from ITEMS.
LABEL-FN is called with each item and must return a display string.
The table maps each display string back to its item plist."
  (let ((table (make-hash-table :test #'equal :size (length items)))
        candidates)
    (dolist (item items)
      (let ((label (funcall label-fn item)))
        (puthash label item table)
        (push label candidates)))
    (cons (nreverse candidates) table)))

(defun chrome-tabs--make-collection (candidates table group-fn)
  "Return a completion collection with grouping metadata.
CANDIDATES is a list of strings, TABLE maps them to item plists,
GROUP-FN maps an item plist to a group name string."
  (lambda (str pred action)
    (if (eq action 'metadata)
        `(metadata
          (group-function
           . ,(lambda (cand transform)
                (if transform
                    cand
                  (funcall group-fn (gethash cand table))))))
      (complete-with-action action candidates str pred))))

;;; Tabs

(defun chrome-tabs--tab-label (tab)
  "Format TAB as a completion candidate string."
  (let ((title (or (plist-get tab :title) "(no title)"))
        (url   (or (plist-get tab :url)   "")))
    (let ((title (if (> (length title) 60)
                     (concat (substring title 0 57) "...")
                   title)))
      (format "%-60s  %s" title url))))

(defun chrome-tabs--tab-group (tab)
  "Return the group name for TAB based on its URL."
  (let ((url (or (plist-get tab :url) "")))
    (cond
     ((string-match-p "github\\.com/[^/]+/[^/]+/pull/" url) "Pull requests")
     ((string-match-p "app\\.datadoghq" url) "DataDog")
     ((string-match-p "console\\.aws\\.amazon\\.com/" url) "AWS")
     ((string-match-p "youtube\\.com/" url) "YouTube")
     (t "Other tabs"))))

;;;###autoload
(defun chrome-tabs-switch ()
  "Select an open Chrome tab with completion and focus it."
  (interactive)
  (let* ((tabs (condition-case err
                   (chrome-tabs-list)
                 (error (user-error "chrome-tabs: %s" (error-message-string err)))))
         (_ (unless tabs (user-error "chrome-tabs: no tabs returned by server")))
         (built      (chrome-tabs--build-table tabs #'chrome-tabs--tab-label))
         (candidates (car built))
         (table      (cdr built))
         (collection (chrome-tabs--make-collection
                      candidates table #'chrome-tabs--tab-group))
         (chosen     (completing-read "Chrome tab: " collection nil t))
         (tab        (gethash chosen table)))
    (unless tab
      (user-error "chrome-tabs: could not retrieve tab data from selection"))
    (chrome-tabs-focus (plist-get tab :window_id)
                       (plist-get tab :tab_index))
    (message "Switched to: %s" (or (plist-get tab :title) "?"))))

;;; Bookmarks

(defun chrome-tabs--bookmark-label (bookmark)
  "Format BOOKMARK as a completion candidate string."
  (let ((title  (or (plist-get bookmark :title)  "(no title)"))
        (folder (or (plist-get bookmark :folder) ""))
        (url    (or (plist-get bookmark :url)    "")))
    (format "%-60s  %-40s  %s" title folder url)))

(defun chrome-tabs--bookmark-group (bookmark)
  "Return the group name for BOOKMARK, which is its top-level folder."
  (let ((folder (or (plist-get bookmark :folder) "")))
    ;; Use only the first segment of the breadcrumb as the group
    (car (split-string folder " > "))))

;;;###autoload
(defun chrome-tabs-open-bookmark ()
  "Select a Chrome bookmark with completion and open it in the default browser."
  (interactive)
  (let* ((bookmarks (condition-case err
                        (chrome-tabs-list-bookmarks)
                      (error (user-error "chrome-tabs: %s" (error-message-string err)))))
         (_ (unless bookmarks (user-error "chrome-tabs: no bookmarks returned by server")))
         (built      (chrome-tabs--build-table bookmarks #'chrome-tabs--bookmark-label))
         (candidates (car built))
         (table      (cdr built))
         (collection (chrome-tabs--make-collection
                      candidates table #'chrome-tabs--bookmark-group))
         (chosen     (completing-read "Chrome bookmark: " collection nil t))
         (bookmark   (gethash chosen table)))
    (unless bookmark
      (user-error "chrome-tabs: could not retrieve bookmark data from selection"))
    (let ((url (plist-get bookmark :url)))
      (browse-url-default-macosx-browser url)
      (message "Opening: %s" (or (plist-get bookmark :title) url)))))

(provide 'chrome-tabs)
;;; chrome-tabs.el ends here
