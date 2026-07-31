;;; komga-sync.el --- Sync nov-mode reading progress with Komga -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chmouel Boudjnah

;; Author: Chmouel Boudjnah <chmouel@chmouel.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (nov "0.4.0") (password-store "2.1.4"))
;; Keywords: comm, hypermedia
;; URL: https://github.com/chmouel/komga-sync.el

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Keep `nov-mode' reading positions in sync with a Komga server, in both
;; directions, so a book started in Emacs can be picked up in Komga's web
;; reader or on a phone and vice versa.
;;
;; Synchronisation uses Komga's Readium "R2 Progression" API,
;; `GET'/`PUT /api/v1/books/{id}/progression', which is the same endpoint
;; Komga's own EPUB reader uses.  Positions written from Emacs therefore
;; show up everywhere else.
;;
;; Usage:
;;
;;   (require 'komga-sync)
;;   (setq komga-sync-server-url "https://books.example.com")
;;   (add-hook 'nov-mode-hook #'komga-sync-mode)
;;
;; The API key is read through `komga-sync-api-key-function', which by
;; default shells out to pass(1) via `password-store-get'.  It is never
;; written to disk, never logged, and never passed on a command line.
;;
;; Local EPUB files are matched to Komga books by remembering explicit
;; links, then by file content, then by searching Komga and filtering on
;; exact file size.  Books that cannot be matched are simply left alone.
;;
;; Limitations, all of them verified against Komga 1.25.0 rather than
;; assumed:
;;
;; - Positions written from Emacs are restored in Emacs exactly, because
;;   the precise buffer position is stashed in `locator.locations.fragments'
;;   and a text snippet is stored in `locator.text', both of which Komga
;;   preserves verbatim.  Positions written by the web reader or by a phone
;;   land in the right document at roughly the right place: Komga measures
;;   progress as a fraction of raw XHTML bytes, markup included, while nov
;;   renders text, and markup density is not uniform.
;;
;; - The local file and Komga's copy should be the same EPUB.  When they
;;   are different builds of the same book their document names do not
;;   correspond, so pulls fall back to positioning by the whole book
;;   fraction, which is approximate, and Komga refuses pushes outright with
;;   "Resource does not exist in book".  `komga-sync-status' says so when
;;   this is the case, and `komga-sync-link-book' warns at link time.
;;
;; - Only books that exist in the Komga library can sync.  Nothing is said
;;   about the others, on purpose, so that reading is never interrupted.
;;
;; - Komga rejects a write whose timestamp is not strictly newer than the
;;   stored one with 409 Conflict; it is not last-write-wins.  That is used
;;   here as the conflict signal: automatic pushes then stop entirely until
;;   `komga-sync-pull' takes the remote position, or `komga-sync-push'
;;   overwrites it after asking.  Retrying would eventually produce a
;;   timestamp newer than the remote one and erase progress read elsewhere.
;;
;; - The `modified' field returned by GET is skewed by the server's UTC
;;   offset in this Komga version, so server timestamps are never compared
;;   against local time.  Remote changes are detected by comparing locators.
;;
;; - Requests are made with curl rather than `url-retrieve', which hung
;;   against a real server during development.  curl is run with -q so that
;;   a user curl configuration cannot alter or log the request, and the API
;;   key is handed over on stdin so it never appears in the process list.
;;
;; - `komga-sync-state-directory' is meant to be synced between machines and
;;   holds only the file to book links.  This machine's device identity
;;   lives in `komga-sync-cache-directory' instead, so that Komga sees each
;;   machine as a separate device.
;;
;; - Komga's KOReader `/kosync' endpoint would offer a reproducible file
;;   hash, but only for libraries with `hashKoreader' enabled, so it is not
;;   used for matching.

;;; Code:

(require 'nov)
(require 'seq)
(require 'subr-x)
(require 'url-util)

(defgroup komga-sync nil
  "Sync `nov-mode' reading progress with a Komga server."
  :group 'nov
  :prefix "komga-sync-")


;;;; Customization

(defcustom komga-sync-server-url nil
  "Base URL of the Komga server, for example \"https://books.example.com\".
A trailing slash is ignored.  Nothing is synced until this is set."
  :type '(choice (const :tag "Not configured" nil) string))

(defcustom komga-sync-api-key-entry "komga/api_key"
  "Name of the pass(1) entry holding the Komga API key."
  :type 'string)

(defcustom komga-sync-api-key-function #'komga-sync-api-key-from-pass
  "Function returning the Komga API key as a string.
Called with no arguments.  The result is cached for the session in
memory only."
  :type 'function)

(defcustom komga-sync-state-directory
  (expand-file-name "~/Sync/emacs/komga-sync/")
  "Directory holding the persistent link and sync state.
This is small and worth syncing between machines."
  :type 'directory)

(defcustom komga-sync-cache-directory
  (expand-file-name "komga-sync/" (or (getenv "XDG_CACHE_HOME") "~/.cache/"))
  "Directory for regenerable caches, such as the library index.
This can be large and is not worth syncing between machines."
  :type 'directory)

(defcustom komga-sync-device-name (format "%s (Emacs)" (system-name))
  "Name reported to Komga for this device."
  :type 'string)

(defcustom komga-sync-idle-delay 5
  "Seconds of idle time before pushing progress to Komga.
Set to nil to disable idle pushes."
  :type '(choice (number :tag "Seconds") (const :tag "Disabled" nil)))

(defcustom komga-sync-push-on-chapter-change t
  "Whether to push progress when moving to another chapter."
  :type 'boolean)

(defcustom komga-sync-push-on-exit t
  "Whether to push progress when killing the buffer or exiting Emacs."
  :type 'boolean)

(defcustom komga-sync-pull-on-open 'prompt
  "What to do when Komga holds a position different from the local one.
`prompt' asks before jumping, `auto' jumps without asking, `message'
only reports it, and nil disables the check."
  :type '(choice (const :tag "Ask before jumping" prompt)
                 (const :tag "Jump automatically" auto)
                 (const :tag "Only report" message)
                 (const :tag "Disabled" nil)))

(defcustom komga-sync-auto-link t
  "Whether to try to match unlinked EPUB files against Komga automatically."
  :type 'boolean)

(defcustom komga-sync-timeout 20
  "Timeout in seconds for requests to Komga."
  :type 'number)

(defcustom komga-sync-exit-timeout 5
  "Timeout in seconds for the blocking push done when Emacs exits."
  :type 'number)

(defcustom komga-sync-debug nil
  "When non-nil, log requests and decisions to `komga-sync-log-buffer'."
  :type 'boolean)

(defcustom komga-sync-log-buffer "*komga-sync-log*"
  "Name of the buffer used for debug logging."
  :type 'string)


;;;; Internal state

(defconst komga-sync--accept
  "application/vnd.readium.progression+json, application/json, */*"
  "Value of the Accept header.
Komga answers `application/json' alone with 406, so the Readium media
type must be offered.")

(defconst komga-sync--state-version 1
  "Schema version of the on-disk state file.")

(defvar komga-sync-mode)

(defvar komga-sync--api-key nil
  "Cached API key for this session.  Never persisted.")

(defvar komga-sync--state nil
  "Cached link alist of (PATH . ENTRY).  See `komga-sync--links'.")

(defvar komga-sync--device-id nil
  "Cached identifier for this machine.  See `komga-sync--device-file'.")

(defvar komga-sync--applying nil
  "Non-nil while a remote locator is being applied to a buffer.
Moving to a remote position must not be mistaken for reading, which
would push the position just left back over the newer remote one.")

(defvar komga-sync--library-index nil
  "Cached list of Komga books used for size based matching.")

(defvar komga-sync--idle-timer nil
  "Idle timer used for automatic pushes.")

(defvar-local komga-sync--book-id nil
  "Komga book id linked to the current buffer, if any.")

(defvar-local komga-sync--remote-locator nil
  "Last locator seen from or sent to Komga for this buffer.")

(defvar-local komga-sync--pushed-position nil
  "Cons of (INDEX . POINT) last successfully pushed from this buffer.")

(defvar-local komga-sync--busy nil
  "Non-nil while a push started from this buffer is still running.")

(defvar-local komga-sync--process nil
  "Process of the push currently in flight for this buffer, if any.")

(defvar-local komga-sync--conflict nil
  "Non-nil when Komga rejected our last push as stale.
Latched: automatic pushes stay disabled until a pull, or an explicit
overwrite, resolves it.  Otherwise the local position would eventually
become newer than the remote one and silently erase it.")

(defvar-local komga-sync--mismatch nil
  "Non-nil when Komga rejected our locator as absent from the book.
This means the linked Komga book is a different EPUB build than the
local file, so no position this buffer can express will ever be
accepted.")

(defvar-local komga-sync--generation 0
  "Counter invalidating in-flight requests for this buffer.
Anything that makes a pending answer irrelevant — a push, a change of
linked book, leaving the mode — bumps it, so a reply that names an older
generation can be recognised as stale and discarded.")

(defun komga-sync--invalidate ()
  "Make any in-flight answer for this buffer stale."
  (setq komga-sync--generation (1+ komga-sync--generation)))


;;;; Logging

(defun komga-sync--log (format-string &rest args)
  "Append FORMAT-STRING formatted with ARGS to the log buffer."
  (when komga-sync-debug
    (with-current-buffer (get-buffer-create komga-sync-log-buffer)
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S] ")
              (apply #'format format-string args)
              "\n"))))

(defmacro komga-sync--safely (context &rest body)
  "Run BODY, reporting any error as a message tagged with CONTEXT.
Reading must never be interrupted by a synchronisation failure."
  (declare (indent 1) (debug (form body)))
  `(condition-case err
       (progn ,@body)
     (error
      (komga-sync--log "error in %s: %S" ,context err)
      (message "komga-sync: %s failed: %s" ,context (error-message-string err))
      nil)))


;;;; Authentication

(defun komga-sync-api-key-from-pass ()
  "Return the Komga API key from pass(1)."
  (require 'password-store)
  (let ((key (password-store-get komga-sync-api-key-entry)))
    (unless (and key (not (string-empty-p key)))
      (error "No API key in pass entry %S" komga-sync-api-key-entry))
    (string-trim key)))

(defun komga-sync--api-key ()
  "Return the cached API key, fetching it on first use."
  (or komga-sync--api-key
      (setq komga-sync--api-key (funcall komga-sync-api-key-function))))

;;;###autoload
(defun komga-sync-forget-api-key ()
  "Drop the cached API key so it is fetched again on next use."
  (interactive)
  (setq komga-sync--api-key nil)
  (message "komga-sync: API key forgotten"))


;;;; HTTP transport
;;
;; curl is driven rather than url.el: `url-retrieve-synchronously' was
;; observed to hang against this server, and curl lets the API key be
;; passed on stdin so it never becomes visible in the process list.

(defun komga-sync--curl-quote (string)
  "Escape STRING for use inside a curl config double-quoted value."
  (replace-regexp-in-string "\"" "\\\\\""
                            (replace-regexp-in-string "\\\\" "\\\\\\\\" string)))

(defun komga-sync--curl-config (&optional content-type)
  "Return the curl config document carrying the credentials.
CONTENT-TYPE, when non-nil, adds a Content-Type header."
  (let ((key (komga-sync--api-key)))
    ;; A newline would let anything smuggled into the key entry inject
    ;; further curl directives, so refuse rather than sanitise.
    (when (string-match-p "[\r\n]" key)
      (error "Komga API key contains a newline; refusing to use it"))
    (concat
     (format "header = \"X-API-Key: %s\"\n" (komga-sync--curl-quote key))
     (format "header = \"Accept: %s\"\n" komga-sync--accept)
     (when content-type
       (format "header = \"Content-Type: %s\"\n" content-type)))))

(defun komga-sync--url (path)
  "Return the absolute URL for PATH on the configured server."
  (unless komga-sync-server-url
    (user-error "Set `komga-sync-server-url' to your Komga server"))
  (concat (string-remove-suffix "/" komga-sync-server-url) path))

(defun komga-sync--curl-args (method url body-file out-file timeout)
  "Return curl arguments for METHOD on URL.
BODY-FILE, when non-nil, is sent as the request body.  The response body
is written to OUT-FILE and the status code to stdout.  TIMEOUT bounds the
whole request."
  (append (list "-q" "--config" "-" "-sS" "--compressed"
                "--max-time" (number-to-string timeout)
                "-o" out-file "-w" "%{http_code}"
                "-X" method)
          (when body-file (list "--data-binary" (concat "@" body-file)))
          (list url)))

(defun komga-sync--parse (status out-file)
  "Return (STATUS . PAYLOAD) after reading the body from OUT-FILE.
An empty body, as returned for 204, yields a nil payload."
  (let ((payload
         (when (and (file-exists-p out-file)
                    (> (file-attribute-size (file-attributes out-file)) 0))
           (let ((text (with-temp-buffer
                         (let ((coding-system-for-read 'utf-8))
                           (insert-file-contents out-file))
                         (buffer-string))))
             (condition-case nil
                 (json-parse-string text
                                    :object-type 'alist
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil)
               (error text))))))
    (cons status payload)))

(defun komga-sync--request (method path &optional payload)
  "Send METHOD to PATH on the Komga server and return (STATUS . BODY).
PAYLOAD, when non-nil, is a Lisp object serialised as the JSON body."
  (let ((body-file (when payload (make-temp-file "komga-sync-body-")))
        (out-file (make-temp-file "komga-sync-out-")))
    (unwind-protect
        (let* ((url (komga-sync--url path))
               (config (komga-sync--curl-config (when payload "application/json")))
               (args (komga-sync--curl-args method url body-file out-file
                                            komga-sync-timeout))
               (stdout (generate-new-buffer " *komga-sync-curl*"))
               status)
          (when payload
            (let ((coding-system-for-write 'utf-8))
              (write-region (json-serialize payload) nil body-file nil 'silent)))
          (unwind-protect
              (with-temp-buffer
                (insert config)
                (apply #'call-process-region (point-min) (point-max)
                       "curl" nil (list stdout nil) nil args)
                (setq status (string-to-number
                              (string-trim
                               (with-current-buffer stdout (buffer-string))))))
            (kill-buffer stdout))
          (komga-sync--log "%s %s -> %s" method path status)
          (komga-sync--parse status out-file))
      (when body-file (ignore-errors (delete-file body-file)))
      (ignore-errors (delete-file out-file)))))

(defun komga-sync--request-async (method path payload callback)
  "Send METHOD to PATH asynchronously and call CALLBACK with (STATUS . BODY).
PAYLOAD, when non-nil, is serialised as the JSON body.  CALLBACK runs in
whatever buffer is current when the process finishes, so it must not
assume anything about the environment."
  (let* ((body-file (when payload (make-temp-file "komga-sync-body-")))
         (out-file (make-temp-file "komga-sync-out-"))
         (config (komga-sync--curl-config (when payload "application/json")))
         (args (komga-sync--curl-args method (komga-sync--url path)
                                      body-file out-file komga-sync-timeout))
         (stdout (generate-new-buffer " *komga-sync-curl*")))
    (when payload
      (let ((coding-system-for-write 'utf-8))
        (write-region (json-serialize payload) nil body-file nil 'silent)))
    (let ((proc (make-process
                 :name "komga-sync-curl"
                 :buffer stdout
                 :command (cons "curl" args)
                 :noquery t
                 :connection-type 'pipe
                 :sentinel
                 (lambda (proc _event)
                   ;; Cleanup must happen for every terminal status,
                   ;; including a process killed to make way for a newer
                   ;; request, or its files and buffer are leaked.
                   (unless (process-live-p proc)
                     (unwind-protect
                         ;; A killed process has no answer worth reporting.
                         (when (eq (process-status proc) 'exit)
                           (let ((status (string-to-number
                                          (string-trim
                                           (with-current-buffer stdout
                                             (buffer-string))))))
                             (komga-sync--log "%s %s -> %s (async)"
                                              method path status)
                             (komga-sync--safely "async request"
                               (funcall callback
                                        (komga-sync--parse status out-file)))))
                       (when (buffer-live-p stdout) (kill-buffer stdout))
                       (when body-file (ignore-errors (delete-file body-file)))
                       (ignore-errors (delete-file out-file))))))))
      (process-send-string proc config)
      (process-send-eof proc)
      proc)))


;;;; API wrappers

(defun komga-sync--get-progression (book-id)
  "Return the R2 progression alist for BOOK-ID, or nil when there is none."
  (pcase-let ((`(,status . ,body)
               (komga-sync--request
                "GET" (format "/api/v1/books/%s/progression" book-id))))
    (pcase status
      (200 body)
      (204 nil)
      (404 (error "No such book on Komga: %s" book-id))
      (_ (error "Komga returned %s for progression" status)))))

(defun komga-sync--get-book (book-id)
  "Return the book alist for BOOK-ID."
  (pcase-let ((`(,status . ,body)
               (komga-sync--request "GET" (format "/api/v1/books/%s" book-id))))
    (if (= status 200) body
      (error "Komga returned %s for book %s" status book-id))))

(defun komga-sync--search-books (query)
  "Return Komga books matching QUERY."
  (pcase-let ((`(,status . ,body)
               (komga-sync--request
                "GET" (format "/api/v1/books?size=50&search=%s"
                              (url-hexify-string query)))))
    (when (= status 200) (alist-get 'content body))))

(defun komga-sync--all-books ()
  "Return every book on the server.  Used for size based matching."
  (pcase-let ((`(,status . ,body)
               (komga-sync--request "GET" "/api/v1/books?unpaged=true")))
    (when (= status 200) (alist-get 'content body))))


;;;; Persistent state

(defun komga-sync--state-file ()
  "Return the path of the state file."
  (expand-file-name "state.eld" komga-sync-state-directory))

(defun komga-sync--device-file ()
  "Return the path of the file holding this machine's device identity.
It lives in the cache directory rather than the state directory: the
latter is meant to be synced between machines, and a device id that
travels would make every machine look like the same Komga device."
  (expand-file-name "device-id" komga-sync-cache-directory))

(defun komga-sync--read-file (file)
  "Read one Lisp form from FILE.
Returns nil when FILE does not exist.  A file that exists but cannot be
read is reported rather than ignored, so that a damaged link is never
silently discarded and rewritten."
  (when (file-readable-p file)
    (condition-case err
        (with-temp-buffer
          (insert-file-contents file)
          (goto-char (point-min))
          (read (current-buffer)))
      (error
       (komga-sync--log "unreadable %s: %S" file err)
       (message "komga-sync: ignoring damaged file %s" file)
       nil))))

(defun komga-sync--write-file (file object)
  "Write OBJECT to FILE atomically, via a temporary file beside it."
  (make-directory (file-name-directory file) t)
  ;; The temporary file must share a filesystem with FILE, otherwise the
  ;; rename is not atomic and may fail outright.
  (let ((temp (make-temp-file (concat file ".tmp"))))
    (unwind-protect
        (progn
          (with-temp-file temp
            (let ((print-level nil) (print-length nil))
              (prin1 object (current-buffer))
              (insert "\n")))
          (rename-file temp file t)
          (setq temp nil))
      (when (and temp (file-exists-p temp)) (ignore-errors (delete-file temp))))))

(defun komga-sync--links-directory ()
  "Return the directory holding one file per linked book.
Links are kept in separate files rather than one shared table: the state
directory is synced between machines, and independent files let the
syncing tool merge concurrent edits instead of one machine's copy
silently replacing the other's."
  (expand-file-name "links/" komga-sync-state-directory))

(defun komga-sync--link-file (path)
  "Return the file storing the link for the EPUB at PATH."
  (expand-file-name (format "%s.eld" (secure-hash 'sha1 path))
                    (komga-sync--links-directory)))

(defun komga-sync--migrate-state-file ()
  "Move links from the single file used by earlier versions into their own."
  (let ((file (komga-sync--state-file)))
    (when (file-readable-p file)
      (dolist (cell (alist-get 'books (komga-sync--read-file file)))
        (let ((target (komga-sync--link-file (car cell))))
          (unless (file-exists-p target)
            (komga-sync--write-file target (cdr cell)))))
      (rename-file file (concat file ".migrated") t)
      (komga-sync--log "migrated %s" file))))

(defun komga-sync--links ()
  "Return the stored links as an alist of (PATH . ENTRY)."
  (or komga-sync--state
      (setq komga-sync--state
            (progn
              (komga-sync--migrate-state-file)
              (let ((dir (komga-sync--links-directory)))
                (when (file-directory-p dir)
                  (delq nil
                        (mapcar (lambda (file)
                                  (when-let* ((entry (komga-sync--read-file file)))
                                    (cons (alist-get 'path entry) entry)))
                                (directory-files dir t "\\.eld\\'")))))))))

(defun komga-sync--new-device-id ()
  "Return a fresh identifier for this device."
  (format "emacs-%s" (substring (secure-hash 'sha1 (format "%s-%s-%s"
                                                           (system-name)
                                                           (emacs-pid)
                                                           (float-time)))
                                0 12)))

(defun komga-sync--device-id ()
  "Return the stable identifier of this device."
  (or komga-sync--device-id
      (setq komga-sync--device-id
            (or (komga-sync--read-file (komga-sync--device-file))
                ;; Adopt the id of older versions, which kept it in the
                ;; shared state file, so this machine keeps its identity.
                (let ((id (or (alist-get 'device-id
                                         (komga-sync--read-file
                                          (concat (komga-sync--state-file)
                                                  ".migrated")))
                              (alist-get 'device-id
                                         (komga-sync--read-file
                                          (komga-sync--state-file)))
                              (komga-sync--new-device-id))))
                  (komga-sync--write-file (komga-sync--device-file) id)
                  id)))))

(defun komga-sync--book-entry (path)
  "Return the stored link entry for PATH, or nil."
  (cdr (assoc path (komga-sync--links))))

(defun komga-sync--book-remember (path content-key book-id)
  "Persist a link from PATH and CONTENT-KEY to BOOK-ID."
  (let ((entry (list (cons 'path path)
                     (cons 'content-key content-key)
                     (cons 'server komga-sync-server-url)
                     (cons 'book-id book-id))))
    ;; A file that moved keeps one link, not two.
    (dolist (cell (komga-sync--links))
      (when (and (not (equal (car cell) path))
                 (equal (alist-get 'content-key (cdr cell)) content-key))
        (komga-sync--book-forget (car cell))))
    (komga-sync--write-file (komga-sync--link-file path) entry)
    (setq komga-sync--state
          (cons (cons path entry)
                (seq-remove (lambda (cell) (equal (car cell) path))
                            (komga-sync--links))))
    book-id))

(defun komga-sync--book-forget (path &optional content-key)
  "Remove any stored link for PATH, and for CONTENT-KEY when given.
Both have to go: a link found by content would otherwise be restored the
next time the file is opened, silently undoing the unlink."
  (let ((doomed (seq-filter
                 (lambda (cell)
                   (or (equal (car cell) path)
                       (and content-key
                            (equal (alist-get 'content-key (cdr cell))
                                   content-key))))
                 (komga-sync--links))))
    (dolist (cell doomed)
      (let ((file (komga-sync--link-file (car cell))))
        (when (file-exists-p file) (delete-file file))))
    (setq komga-sync--state
          (seq-remove (lambda (cell) (memq cell doomed)) (komga-sync--links)))))


;;;; Linking a local file to a Komga book

(defun komga-sync--content-key (path)
  "Return a content fingerprint for PATH, stable across renames.
The whole file is hashed: two EPUBs of the same book routinely share a
prefix, and a link pointing at the wrong book pushes progress into it."
  (let ((size (file-attribute-size (file-attributes path))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path)
      (format "%d:%s" size (secure-hash 'sha256 (current-buffer))))))

(defun komga-sync--legacy-content-key (path)
  "Return the fingerprint earlier versions computed for PATH.
They hashed only the first 64 KiB with SHA-1.  Recomputing it is what
lets an old link be checked exactly rather than on file size alone."
  (let ((size (file-attribute-size (file-attributes path))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally path nil 0 (min size 65536))
      (format "%d:%s" size (secure-hash 'sha1 (current-buffer))))))

(defun komga-sync--content-key-hash (key)
  "Return the hash part of content KEY, or nil."
  (and (stringp key)
       (string-match "\\`[0-9]+:\\([0-9a-f]+\\)\\'" key)
       (match-string 1 key)))

(defun komga-sync--key-matches-file-p (key path)
  "Return non-nil when content KEY describes the file at PATH.
Keys in either the current or the superseded format are checked in full,
so a replacement file of the same size is never mistaken for the
original."
  (pcase (length (komga-sync--content-key-hash key))
    (64 (equal key (komga-sync--content-key path)))
    (40 (equal key (komga-sync--legacy-content-key path)))
    (_ nil)))

(defun komga-sync--entry-usable-p (entry path)
  "Return non-nil when stored ENTRY may be used for the file at PATH.
The link is only trusted when it was made against the server now
configured and the file still has the content it had when linked;
otherwise progress could be pushed into an unrelated book."
  (and (equal (alist-get 'server entry) komga-sync-server-url)
       (komga-sync--key-matches-file-p (alist-get 'content-key entry) path)))

(defun komga-sync--refresh-legacy-key (entry path)
  "Rewrite ENTRY for PATH with a current fingerprint when it has an old one.
Leaving it would keep the weaker check alive indefinitely."
  (when (= (length (komga-sync--content-key-hash
                    (alist-get 'content-key entry)))
           40)
    (komga-sync--book-remember path (komga-sync--content-key path)
                               (alist-get 'book-id entry))
    (komga-sync--log "upgraded fingerprint for %s" path)))

(defun komga-sync--library-index-file ()
  "Return the path of the cached library index."
  (expand-file-name "library-index.eld" komga-sync-cache-directory))

(defun komga-sync--library-index-cached ()
  "Return the library index if already available, without contacting Komga."
  (or komga-sync--library-index
      (let ((file (komga-sync--library-index-file)))
        (when (file-readable-p file)
          (setq komga-sync--library-index
                (ignore-errors
                  (with-temp-buffer
                    (insert-file-contents file)
                    (goto-char (point-min))
                    (read (current-buffer)))))))))

(defun komga-sync--library-index (&optional refresh)
  "Return the cached list of Komga books, fetching it when REFRESH is non-nil."
  (or (and (not refresh) (komga-sync--library-index-cached))
      (let ((books (komga-sync--all-books))
            (file (komga-sync--library-index-file)))
        (make-directory (file-name-directory file) t)
        (with-temp-file file
          (let ((print-level nil) (print-length nil))
            (prin1 books (current-buffer))))
        (setq komga-sync--library-index books))))

(defun komga-sync--describe-book (book)
  "Return a one line description of BOOK for completion."
  (let ((meta (alist-get 'metadata book)))
    (format "%s — %s [%s, %s pages]"
            (or (alist-get 'title meta) (alist-get 'name book))
            (or (mapconcat (lambda (a) (alist-get 'name a))
                           (alist-get 'authors meta) ", ")
                "?")
            (alist-get 'size book)
            (alist-get 'pagesCount (alist-get 'media book)))))

(defun komga-sync--match-by-size (size &optional books)
  "Return the books in BOOKS whose file size is exactly SIZE."
  (seq-filter (lambda (b) (eql (alist-get 'sizeBytes b) size))
              (or books (komga-sync--library-index-cached))))

(defun komga-sync--auto-match (path &optional network)
  "Return the Komga book id matching PATH, or nil.
Only an unambiguous match on exact file size is accepted, which is safe
here because file sizes do not collide across the library.  Unless
NETWORK is non-nil the search is limited to an already cached library
index, so opening a book never blocks on Komga."
  (let* ((size (file-attribute-size (file-attributes path)))
         (matches (komga-sync--match-by-size size)))
    (when (and network (/= (length matches) 1))
      (let ((title (or (alist-get 'title nov-metadata)
                       (file-name-base path))))
        (setq matches (komga-sync--match-by-size
                       size (komga-sync--search-books title)))))
    (when (= (length matches) 1)
      (alist-get 'id (car matches)))))

(defun komga-sync--stored-link (path)
  "Return the stored entry linking PATH to a Komga book, or nil.
Matched first by path and then by content, so a renamed or moved file
keeps its link.  Entries that no longer describe this file, or that were
made against another server, are ignored."
  (let* ((links (komga-sync--links))
         (entry (cdr (assoc path links))))
    (unless (and entry (komga-sync--entry-usable-p entry path))
      (setq entry (cdr (seq-find (lambda (cell)
                                   (komga-sync--entry-usable-p (cdr cell) path))
                                 links))))
    (when entry
      (komga-sync--refresh-legacy-key entry path))
    entry))

(defun komga-sync--resolve-book-id (&optional network)
  "Return the Komga book id for the current buffer, or nil.
With NETWORK non-nil, Komga may be searched to find a match, which
blocks; without it only remembered links and an already cached library
index are consulted."
  (or komga-sync--book-id
      (let* ((path (or nov-file-name buffer-file-name))
             (entry (and path (komga-sync--stored-link path))))
        (setq komga-sync--book-id
              (cond
               (entry (alist-get 'book-id entry))
               ((and path komga-sync-auto-link)
                (when-let* ((id (komga-sync--auto-match path network)))
                  (komga-sync--book-remember path (komga-sync--content-key path) id)
                  (komga-sync--log "auto-linked %s to %s" path id)
                  id)))))))


;;;; Translating positions
;;
;; Komga identifies a position by the archive relative path of the spine
;; document plus a progression, which is a fraction of that document's raw
;; byte length.  nov holds the same documents in `nov-documents', so the
;; path is the reliable join key.  Indices are not: nov prepends the table
;; of contents at index 0 and Komga does not include it.

(defun komga-sync--document-path (index)
  "Return the archive relative path of spine document INDEX."
  (file-relative-name (cdr (aref nov-documents index)) nov-work-dir))

(defun komga-sync--href-index (href)
  "Return the `nov-documents' index matching HREF, or nil."
  (let* ((href (car (split-string href "#")))
         (decoded (url-unhex-string href))
         (found nil))
    (dotimes (i (length nov-documents))
      (let ((path (komga-sync--document-path i)))
        (when (and (not found)
                   (or (string= path href)
                       (string= path decoded)
                       (string= (url-unhex-string path) decoded)))
          (setq found i))))
    found))

(defun komga-sync--body-bounds (file)
  "Return (START END SIZE) byte offsets of the body element of FILE.
Falls back to the whole file when no body element is found.  Komga
measures progression against raw bytes, so the markup preamble has to be
accounted for or every position drifts towards the start of the chapter."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (let* ((size (1- (point-max)))
           (start (progn (goto-char (point-min))
                         (if (re-search-forward "<body[^>]*>" nil t)
                             (1- (point))
                           0)))
           (end (progn (goto-char (point-max))
                       (if (re-search-backward "</body[^>]*>" nil t)
                           (1- (point))
                         size))))
      (list start (max end (1+ start)) size))))

(defun komga-sync--point-to-progression (index point)
  "Return the Komga progression for POINT inside document INDEX."
  (pcase-let* ((`(,start ,end ,size) (komga-sync--body-bounds
                                      (cdr (aref nov-documents index))))
               (span (max 1 (- (point-max) (point-min))))
               (fraction (/ (float (- point (point-min))) span)))
    (if (<= size 0)
        0.0
      (min 0.999999 (max 0.0 (/ (+ start (* fraction (- end start)))
                                (float size)))))))

(defun komga-sync--progression-to-point (index progression)
  "Return the buffer position for PROGRESSION inside document INDEX.
The current buffer must already display that document."
  (pcase-let* ((`(,start ,end ,size) (komga-sync--body-bounds
                                      (cdr (aref nov-documents index))))
               (offset (* progression size))
               (span (max 1 (- end start)))
               (fraction (min 1.0 (max 0.0 (/ (- offset start) (float span))))))
    (min (point-max)
         (max (point-min)
              (+ (point-min) (round (* fraction (- (point-max) (point-min)))))))))

(defun komga-sync--snippet (&optional pos)
  "Return a whitespace normalised snippet of buffer text around POS."
  (let* ((pos (or pos (point)))
         (raw (buffer-substring-no-properties
               pos (min (point-max) (+ pos 120)))))
    (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " raw))))

(defun komga-sync--spine-positions ()
  "Return a vector of Komga position counts per `nov-documents' entry.
Mirrors Komga's own algorithm, ceil of the raw byte size over 1024, so
progress percentages can be shown without another request."
  (let ((counts (make-vector (length nov-documents) 1)))
    (dotimes (i (length nov-documents))
      (let ((size (file-attribute-size
                   (file-attributes (cdr (aref nov-documents i))))))
        (aset counts i (max 1 (ceiling (/ (float (or size 0)) 1024))))))
    counts))

(defun komga-sync--total-progression (index progression)
  "Return an approximate whole book fraction for PROGRESSION in INDEX.
Document 0 is skipped because it holds the table of contents, which is
not part of Komga's reading order."
  (let* ((counts (komga-sync--spine-positions))
         (total 0) (before 0))
    (dotimes (i (length counts))
      (when (> i 0)
        (when (< i index) (setq before (+ before (aref counts i))))
        (setq total (+ total (aref counts i)))))
    (if (<= total 0)
        0.0
      (/ (+ before (* progression (aref counts index))) (float total)))))

(defun komga-sync--total-progression-position (total)
  "Return (INDEX . PROGRESSION) for the whole book fraction TOTAL.
The inverse of `komga-sync--total-progression', used when the remote
locator names a document this file does not have."
  (let* ((counts (komga-sync--spine-positions))
         (sum 0))
    (dotimes (i (length counts))
      (when (> i 0) (setq sum (+ sum (aref counts i)))))
    (if (<= sum 0)
        (cons (min 1 (1- (length counts))) 0.0)
      (let ((target (* (min 1.0 (max 0.0 total)) sum))
            (seen 0)
            (result nil))
        (dotimes (i (length counts))
          (when (and (> i 0) (null result))
            (let ((next (+ seen (aref counts i))))
              (if (<= target next)
                  (setq result
                        (cons i (/ (- target seen) (float (aref counts i)))))
                (setq seen next)))))
        (or result (cons (1- (length counts)) 1.0))))))

(defun komga-sync--document-title (index)
  "Return a human readable name for document INDEX.
When INDEX is the document on display its first rendered line is used,
which is usually the chapter heading and reads far better in a prompt
than the manifest identifier."
  (or (and (eq index nov-documents-index)
           (save-excursion
             (goto-char (point-min))
             (skip-chars-forward " \t\n\r")
             ;; A document rendering to nothing, such as an image only
             ;; page, has no line here at all.
             (let ((line (string-trim (or (thing-at-point 'line t) ""))))
               (unless (string-empty-p line)
                 (truncate-string-to-width line 60 nil nil t)))))
      (ignore-errors
        (let ((id (car (aref nov-documents index))))
          (and id (symbol-name id))))
      (file-name-base (komga-sync--document-path index))))


;;;; Building and applying locators

(defun komga-sync--current-locator ()
  "Return the R2 locator describing the position of the current buffer."
  (let* ((index nov-documents-index)
         (progression (komga-sync--point-to-progression index (point)))
         (snippet (komga-sync--snippet)))
    (append
     `((href . ,(komga-sync--document-path index))
       (type . "application/xhtml+xml")
       (title . ,(komga-sync--document-title index))
       (locations . ((progression . ,progression)
                     (fragments . [,(format "nov-index-%d" index)
                                   ,(format "nov-point-%d" (point))]))))
     (unless (string-empty-p snippet)
       `((text . ((highlight . ,snippet))))))))

(defun komga-sync--locator-fragment-point (locator index)
  "Return the exact point stored in LOCATOR for INDEX, or nil.
Only positions written by this package carry these fragments, which is
what makes an Emacs to Emacs round trip lossless."
  (let* ((locations (alist-get 'locations locator))
         (fragments (append (alist-get 'fragments locations) nil))
         (want (format "nov-index-%d" index))
         (point nil))
    (when (member want fragments)
      (dolist (fragment fragments)
        (when (string-match "\\`nov-point-\\([0-9]+\\)\\'" fragment)
          (setq point (string-to-number (match-string 1 fragment)))))
      point)))

(defun komga-sync--locator-snippet-point (locator)
  "Return the position of LOCATOR's text snippet in the current buffer, or nil."
  (when-let* ((snippet (alist-get 'highlight (alist-get 'text locator)))
              (needle (string-trim snippet)))
    (when (>= (length needle) 12)
      (save-excursion
        (goto-char (point-min))
        ;; The snippet was normalised when stored, so match it tolerantly
        ;; against whatever whitespace the current rendering produced.
        (let ((regexp (mapconcat #'regexp-quote
                                 (split-string needle "[ \t\n\r]+" t)
                                 "[ \t\n\r]+")))
          (when (re-search-forward regexp nil t)
            (match-beginning 0)))))))

(defun komga-sync--apply-locator (locator)
  "Move point in the current buffer to the position described by LOCATOR.
Return `exact' when LOCATOR named a document this file has, `approximate'
when it did not and the whole book fraction was used instead, and nil
when neither was possible."
  (let* ((komga-sync--applying t)
         (index (komga-sync--href-index (alist-get 'href locator)))
         (locations (alist-get 'locations locator))
         (progression (or (alist-get 'progression locations) 0.0))
         (kind 'exact))
    (unless index
      ;; The linked Komga book is a different EPUB build, so its document
      ;; names mean nothing here.  The whole book fraction still does.
      (komga-sync--log "no document matches href %S" (alist-get 'href locator))
      (when-let* ((total (alist-get 'totalProgression locations)))
        (let ((position (komga-sync--total-progression-position total)))
          (setq index (car position)
                progression (cdr position)
                kind 'approximate))))
    (when index
      (unless (eq index nov-documents-index)
        (nov-goto-document index))
      (let ((target (if (eq kind 'exact)
                        (or (komga-sync--locator-fragment-point locator index)
                            (komga-sync--locator-snippet-point locator)
                            (komga-sync--progression-to-point index progression))
                      (komga-sync--progression-to-point index progression))))
        (goto-char (max (point-min) (min (point-max) target))))
      ;; The pull can land here from a process sentinel, when this buffer
      ;; may not be the one on screen.
      (when (eq (current-buffer) (window-buffer (selected-window)))
        (recenter))
      ;; Landing here is not reading, so the position must count as
      ;; already synced or the next push would send it straight back.
      (setq komga-sync--pushed-position (cons nov-documents-index (point)))
      kind)))

(defun komga-sync--describe-locator (locator)
  "Return a short human readable description of LOCATOR."
  (let* ((index (komga-sync--href-index (alist-get 'href locator)))
         (progression (or (alist-get 'progression (alist-get 'locations locator))
                          0.0))
         (title (or (alist-get 'title locator)
                    (and index (komga-sync--document-title index))
                    (alist-get 'href locator)))
         (total (or (alist-get 'totalProgression (alist-get 'locations locator))
                    (and index (komga-sync--total-progression index progression)))))
    (if total
        (format "%s (%d%%)" title (round (* 100 total)))
      (format "%s" title))))


;;;; Pushing

(defun komga-sync--position-changed-p ()
  "Return non-nil when the buffer moved since the last successful push."
  (not (equal komga-sync--pushed-position
              (cons nov-documents-index (point)))))

(defun komga-sync--progression-payload (locator)
  "Return the R2 progression payload carrying LOCATOR."
  `((device . ((id . ,(komga-sync--device-id))
               (name . ,komga-sync-device-name)))
    (locator . ,locator)
    (modified . ,(format-time-string "%Y-%m-%dT%H:%M:%S.%3N%:z"))))

(defun komga-sync--handle-push-result (buffer position locator status)
  "Record in BUFFER the outcome STATUS of pushing LOCATOR for POSITION.
POSITION is the (INDEX . POINT) the request actually carried, which is
not necessarily where the buffer is by the time the answer arrives."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq komga-sync--busy nil
            komga-sync--process nil)
      (pcase status
        (204
         (setq komga-sync--pushed-position position
               komga-sync--remote-locator locator
               komga-sync--conflict nil
               komga-sync--mismatch nil)
         (komga-sync--log "pushed %S" locator))
        (409
         ;; Komga rejects writes older than what it holds, so another
         ;; device is ahead.  Latch it: retrying would eventually win on
         ;; timestamp and destroy progress that was never read here.
         (setq komga-sync--conflict t)
         (message "komga-sync: Komga has newer progress; use `komga-sync-pull'"))
        (400
         (setq komga-sync--mismatch t)
         (message "komga-sync: the linked Komga book is a different EPUB build; \
run `komga-sync-status' for details"))
        (_ (message "komga-sync: push failed (HTTP %s)" status))))))

(defun komga-sync--push (&optional force sync)
  "Push the current position to Komga.
Unless FORCE is non-nil, nothing happens when the position is unchanged,
when a conflict is outstanding, or when the linked book is known not to
accept this file's locators.  With SYNC non-nil the request blocks,
which is needed when Emacs exits."
  (when (and (derived-mode-p 'nov-mode)
             (not komga-sync--applying)
             (or force
                 (and (not komga-sync--conflict)
                      (not komga-sync--mismatch)
                      (komga-sync--position-changed-p))))
    (when-let* ((book-id (komga-sync--resolve-book-id)))
      ;; An exit push has to win over whatever is still in flight, since
      ;; the buffer is about to disappear along with the newer position.
      (when (and sync komga-sync--process (process-live-p komga-sync--process))
        (delete-process komga-sync--process)
        (setq komga-sync--process nil komga-sync--busy nil))
      (unless komga-sync--busy
        (let* ((locator (komga-sync--current-locator))
               (position (cons nov-documents-index (point)))
               (payload (komga-sync--progression-payload locator))
               (path (format "/api/v1/books/%s/progression" book-id))
               (buffer (current-buffer)))
          (setq komga-sync--busy t)
          ;; From here the remote position is ours, so any pull still in
          ;; flight is answering a question about a superseded state.
          (komga-sync--invalidate)
          (if sync
              (let ((komga-sync-timeout komga-sync-exit-timeout))
                (komga-sync--handle-push-result
                 buffer position locator
                 (car (komga-sync--request "PUT" path payload))))
            (setq komga-sync--process
                  (komga-sync--request-async
                   "PUT" path payload
                   (lambda (result)
                     (komga-sync--handle-push-result
                      buffer position locator (car result)))))))))))


;;;; Pulling

(defun komga-sync--same-position-p (locator)
  "Return non-nil when LOCATOR points where the buffer already is."
  (let ((index (komga-sync--href-index (alist-get 'href locator))))
    (and index
         (eq index nov-documents-index)
         (let ((remote (or (alist-get 'progression (alist-get 'locations locator))
                           0.0))
               (local (komga-sync--point-to-progression
                       nov-documents-index (point))))
           (< (abs (- remote local)) 0.02)))))

(defun komga-sync--record-applied (locator)
  "Note that LOCATOR is now the position of this buffer.
Resolves any outstanding conflict: the remote position has been taken,
so pushing from here is no longer destructive."
  (setq komga-sync--remote-locator locator
        komga-sync--pushed-position (cons nov-documents-index (point))
        komga-sync--conflict nil))

(defun komga-sync--approximate-note (kind)
  "Return a note to append to a message when KIND is `approximate'."
  (if (eq kind 'approximate)
      " (approximate: the Komga copy is a different EPUB build)"
    ""))

(defun komga-sync--offer-locator (locator)
  "Consider moving the current buffer to LOCATOR according to settings."
  (unless (or (komga-sync--same-position-p locator)
              (equal locator komga-sync--remote-locator))
    (let ((there (komga-sync--describe-locator locator))
          (here (komga-sync--describe-locator (komga-sync--current-locator))))
      (pcase komga-sync-pull-on-open
        ('auto
         (when-let* ((kind (komga-sync--apply-locator locator)))
           (komga-sync--record-applied locator)
           (message "komga-sync: jumped to %s%s" there
                    (komga-sync--approximate-note kind))))
        ('prompt
         (when (y-or-n-p (format "Komga is at %s, local is at %s.  Jump? "
                                 there here))
           (if-let* ((kind (komga-sync--apply-locator locator)))
               (progn
                 (komga-sync--record-applied locator)
                 (message "komga-sync: moved to %s%s" there
                          (komga-sync--approximate-note kind)))
             (message "komga-sync: could not place %S in this file"
                      (alist-get 'href locator)))))
        ('message
         (message "komga-sync: Komga is at %s, local is at %s" there here))
        (_ nil)))))

(defun komga-sync--pull-async ()
  "Fetch the remote position and offer to move there."
  (when-let* ((book-id (komga-sync--resolve-book-id))
              (buffer (current-buffer))
              (generation komga-sync--generation)
              (origin (cons nov-documents-index (point))))
    (komga-sync--request-async
     "GET" (format "/api/v1/books/%s/progression" book-id) nil
     (lambda (result)
       (pcase-let ((`(,status . ,body) result))
         (when (and (= status 200) body (buffer-live-p buffer))
           (with-current-buffer buffer
             ;; The answer may arrive long after it stopped being
             ;; wanted.  A bumped generation means the state it describes
             ;; has since been superseded here — most importantly by a
             ;; push, which makes the value we just read the stale one
             ;; even though point never moved.
             (cond
              ((not (and komga-sync-mode
                         (equal komga-sync--book-id book-id)
                         (eql generation komga-sync--generation)))
               (komga-sync--log "dropping pull for %s, no longer wanted" book-id))
              ((not (equal origin (cons nov-documents-index (point))))
               (komga-sync--log "pull overtaken by local reading")
               (let ((komga-sync-pull-on-open
                      (if (eq komga-sync-pull-on-open 'auto)
                          'message
                        komga-sync-pull-on-open)))
                 (komga-sync--safely "pull"
                   (komga-sync--offer-locator (alist-get 'locator body)))))
              (t
               (komga-sync--safely "pull"
                 (komga-sync--offer-locator (alist-get 'locator body))))))))))))


;;;; Triggers

(defun komga-sync--idle-push ()
  "Push from the current buffer when it is a book being synced."
  (when (and (derived-mode-p 'nov-mode) komga-sync-mode)
    (komga-sync--safely "idle push" (komga-sync--push))))

(defun komga-sync--ensure-idle-timer ()
  "Start the shared idle timer when idle pushes are enabled."
  (when (and komga-sync-idle-delay (not komga-sync--idle-timer))
    (setq komga-sync--idle-timer
          (run-with-idle-timer komga-sync-idle-delay t #'komga-sync--idle-push))))

(defun komga-sync--before-goto-document (&rest _)
  "Push the position being left before nov renders another document."
  (when (and komga-sync-mode komga-sync-push-on-chapter-change
             (not komga-sync--applying))
    (komga-sync--safely "chapter push" (komga-sync--push))))

(defun komga-sync--kill-buffer ()
  "Push synchronously while the buffer still exists."
  (when (and komga-sync-mode komga-sync-push-on-exit)
    (komga-sync--safely "exit push" (komga-sync--push nil t))))

(defun komga-sync--kill-emacs ()
  "Push every synced book before Emacs exits.
The whole round is bounded by `komga-sync-exit-timeout' rather than
spending it per buffer, so a slow or unreachable server cannot hold up
shutdown in proportion to the number of open books."
  (when komga-sync-push-on-exit
    (let ((deadline (+ (float-time) komga-sync-exit-timeout)))
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and (derived-mode-p 'nov-mode) komga-sync-mode)
            (let ((left (- deadline (float-time))))
              (when (> left 0.5)
                (let ((komga-sync-exit-timeout left))
                  (komga-sync--safely "exit push"
                    (komga-sync--push nil t)))))))))))


;;;; Commands

;;;###autoload
(defun komga-sync-push ()
  "Push the current reading position to Komga.
When Komga holds newer progress this asks before overwriting it."
  (interactive)
  (unless (derived-mode-p 'nov-mode) (user-error "Not in an EPUB buffer"))
  (unless (komga-sync--resolve-book-id t)
    (user-error "This book is not linked; use `komga-sync-link-book'"))
  (when (and komga-sync--conflict
             (not (yes-or-no-p
                   "Komga has newer progress that would be lost.  Overwrite? ")))
    (user-error "Push cancelled; use `komga-sync-pull' to take the remote position"))
  (setq komga-sync--conflict nil)
  (komga-sync--push t)
  (message "komga-sync: pushing…"))

;;;###autoload
(defun komga-sync-pull ()
  "Move to the reading position stored on Komga."
  (interactive)
  (unless (derived-mode-p 'nov-mode) (user-error "Not in an EPUB buffer"))
  (let ((book-id (or (komga-sync--resolve-book-id t)
                     (user-error "This book is not linked; use `komga-sync-link-book'"))))
    (if-let* ((progression (komga-sync--get-progression book-id))
              (locator (alist-get 'locator progression)))
        (if-let* ((kind (komga-sync--apply-locator locator)))
            (progn
              (komga-sync--record-applied locator)
              (message "komga-sync: moved to %s%s"
                       (komga-sync--describe-locator locator)
                       (komga-sync--approximate-note kind)))
          (message "komga-sync: Komga is at %S, which this file does not have \
and gives no whole book position for; the linked book is a different EPUB"
                   (alist-get 'href locator)))
      (message "komga-sync: no progress stored on Komga"))))

;;;###autoload
(defun komga-sync-link-book ()
  "Choose the Komga book matching the EPUB in the current buffer."
  (interactive)
  (unless (derived-mode-p 'nov-mode) (user-error "Not in an EPUB buffer"))
  (let* ((path (or nov-file-name buffer-file-name))
         (query (read-string "Search Komga for: "
                             (or (alist-get 'title nov-metadata)
                                 (file-name-base path))))
         (books (komga-sync--search-books query)))
    (unless books (user-error "No book on Komga matches %S" query))
    (let* ((choices (mapcar (lambda (b)
                              (cons (komga-sync--describe-book b) (alist-get 'id b)))
                            books))
           (choice (completing-read "Komga book: " choices nil t))
           (book-id (cdr (assoc choice choices)))
           (book (seq-find (lambda (b) (equal (alist-get 'id b) book-id)) books))
           (size (file-attribute-size (file-attributes path))))
      (komga-sync--book-remember path (komga-sync--content-key path) book-id)
      (komga-sync--invalidate)
      (setq komga-sync--book-id book-id
            komga-sync--conflict nil
            komga-sync--mismatch nil)
      ;; Different byte sizes mean different EPUB builds, and Komga
      ;; rejects any locator naming a document its copy does not have.
      (if (eql size (alist-get 'sizeBytes book))
          (message "komga-sync: linked to %s" choice)
        (message "komga-sync: linked to %s, but that copy is a different \
EPUB build (%s bytes here, %s on Komga); positions will only sync \
approximately and pushes may be refused"
                 choice size (alist-get 'sizeBytes book))))))

;;;###autoload
(defun komga-sync-unlink-book ()
  "Forget the Komga book linked to the current buffer."
  (interactive)
  (let ((path (or nov-file-name buffer-file-name)))
    (komga-sync--book-forget path (komga-sync--content-key path))
    (komga-sync--invalidate)
    (setq komga-sync--book-id nil
          komga-sync--conflict nil
          komga-sync--mismatch nil)
    (message "komga-sync: unlinked %s" (file-name-nondirectory path))))

;;;###autoload
(defun komga-sync-refresh-library-index ()
  "Refetch the cached list of Komga books used for matching."
  (interactive)
  (message "komga-sync: fetching library index…")
  (let ((books (komga-sync--library-index t)))
    (message "komga-sync: indexed %d books" (length books))))

;;;###autoload
(defun komga-sync-status ()
  "Report what the current buffer is linked to and where Komga stands."
  (interactive)
  (unless (derived-mode-p 'nov-mode) (user-error "Not in an EPUB buffer"))
  (let ((book-id (komga-sync--resolve-book-id)))
    (if (not book-id)
        (message "komga-sync: not linked to any Komga book")
      (let* ((progression (ignore-errors (komga-sync--get-progression book-id)))
             (locator (alist-get 'locator progression))
             (href (alist-get 'href locator))
             (foreign (and href (null (komga-sync--href-index href)))))
        (message "komga-sync: %s | local %s | komga %s%s%s"
                 book-id
                 (komga-sync--describe-locator (komga-sync--current-locator))
                 (if locator (komga-sync--describe-locator locator) "nothing")
                 (cond (komga-sync--conflict " | CONFLICT, use komga-sync-pull")
                       (komga-sync--mismatch " | REFUSED, different EPUB build")
                       (t ""))
                 (if foreign
                     (format " | Komga's copy is a different EPUB build (%s is \
not in this file), so positions are approximate and pushes are refused; \
re-link with komga-sync-link-book or put this exact file on Komga" href)
                   ""))))))


;;;; Minor mode

(defun komga-sync--other-mode-buffers-p ()
  "Return non-nil when another live buffer still has the mode enabled."
  (seq-find (lambda (buffer)
              (and (not (eq buffer (current-buffer)))
                   (buffer-local-value 'komga-sync-mode buffer)))
            (buffer-list)))

(defun komga-sync--teardown ()
  "Remove the globally installed hooks once no buffer needs them."
  (unless (komga-sync--other-mode-buffers-p)
    (advice-remove 'nov-goto-document #'komga-sync--before-goto-document)
    (remove-hook 'kill-emacs-hook #'komga-sync--kill-emacs)
    (when komga-sync--idle-timer
      (cancel-timer komga-sync--idle-timer)
      (setq komga-sync--idle-timer nil))))

;;;###autoload
(define-minor-mode komga-sync-mode
  "Keep this EPUB's reading position in sync with Komga."
  :lighter " Komga"
  (if komga-sync-mode
      (progn
        (unless (derived-mode-p 'nov-mode)
          (setq komga-sync-mode nil)
          (user-error "The komga-sync minor mode only works in `nov-mode' buffers"))
        (komga-sync--ensure-idle-timer)
        (add-hook 'kill-buffer-hook #'komga-sync--kill-buffer nil t)
        (add-hook 'kill-emacs-hook #'komga-sync--kill-emacs)
        (advice-add 'nov-goto-document :before #'komga-sync--before-goto-document)
        (setq komga-sync--pushed-position (cons nov-documents-index (point)))
        (when komga-sync-pull-on-open
          (komga-sync--safely "pull on open" (komga-sync--pull-async))))
    (komga-sync--invalidate)
    (remove-hook 'kill-buffer-hook #'komga-sync--kill-buffer t)
    (komga-sync--teardown)))

(provide 'komga-sync)
;;; komga-sync.el ends here
