;;; komga-sync-tests.el --- Tests for komga-sync -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests for the pure parts of komga-sync: locator translation, href
;; matching, state persistence and request plumbing.  Nothing here touches
;; the network.  Run with:
;;
;;   emacs -Q --batch -L . -l ert -l komga-sync-tests.el \
;;         -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'komga-sync)

(defvar komga-sync-tests--body
  (concat "Alpha beta gamma delta epsilon zeta eta theta iota kappa. "
          "Lambda mu nu xi omicron pi rho sigma tau upsilon phi chi psi. ")
  "Filler used to build fixture documents.")

(defun komga-sync-tests--write-xhtml (file body)
  "Write an XHTML document containing BODY to FILE."
  (with-temp-file file
    (insert "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            "<!DOCTYPE html>\n"
            "<html xmlns=\"http://www.w3.org/1999/xhtml\">\n"
            "<head><title>T</title>"
            "<link rel=\"stylesheet\" href=\"../Styles/stylesheet.css\"/>"
            "</head>\n<body>\n" body "\n</body>\n</html>\n")))

(defmacro komga-sync-tests--with-book (&rest body)
  "Run BODY in a buffer faking a two document nov book."
  (declare (indent 0) (debug t))
  `(let* ((dir (make-temp-file "komga-sync-test-" t))
          (oebps (expand-file-name "OEBPS" dir)))
     (unwind-protect
         (progn
           (make-directory oebps t)
           (komga-sync-tests--write-xhtml
            (expand-file-name "toc.ncx" oebps) "toc")
           (komga-sync-tests--write-xhtml
            (expand-file-name "chap1.xhtml" oebps)
            (apply #'concat (make-list 40 komga-sync-tests--body)))
           (komga-sync-tests--write-xhtml
            (expand-file-name "a b.xhtml" oebps) "spaced")
           (with-temp-buffer
             (setq-local nov-work-dir dir)
             (setq-local nov-documents
                         (vector (cons 'ncx (expand-file-name "toc.ncx" oebps))
                                 (cons 'c1 (expand-file-name "chap1.xhtml" oebps))
                                 (cons 'c2 (expand-file-name "a b.xhtml" oebps))))
             (setq-local nov-documents-index 1)
             ,@body))
       (delete-directory dir t))))


;;;; Transport helpers

(ert-deftest komga-sync-test-curl-quote ()
  (should (equal (komga-sync--curl-quote "plain") "plain"))
  (should (equal (komga-sync--curl-quote "a\"b") "a\\\"b"))
  (should (equal (komga-sync--curl-quote "a\\b") "a\\\\b")))

(ert-deftest komga-sync-test-url-joining ()
  (let ((komga-sync-server-url "https://example.com"))
    (should (equal (komga-sync--url "/api/v1/books") "https://example.com/api/v1/books")))
  (let ((komga-sync-server-url "https://example.com/"))
    (should (equal (komga-sync--url "/api/v1/books") "https://example.com/api/v1/books"))))

(ert-deftest komga-sync-test-accept-header-is-not-plain-json ()
  "Komga answers `application/json' alone with 406."
  (should (string-match-p "vnd\\.readium\\.progression\\+json" komga-sync--accept)))

(ert-deftest komga-sync-test-curl-args-keep-key-off-argv ()
  (let ((args (komga-sync--curl-args "PUT" "https://example.com/x" nil "/tmp/o" 20)))
    (should (member "--config" args))
    (should (member "-" args))
    (should (member "%{http_code}" args))
    (should-not (seq-find (lambda (a) (string-match-p "X-API-Key" a)) args))))

(ert-deftest komga-sync-test-curl-ignores-user-config ()
  "-q must come first, or ~/.curlrc could redirect or log the API key."
  (let ((args (komga-sync--curl-args "GET" "https://example.com/x" nil "/tmp/o" 20)))
    (should (equal (car args) "-q"))))

(ert-deftest komga-sync-test-curl-config-rejects-newline-in-key ()
  "A newline in the key would inject further curl directives."
  (let ((komga-sync-api-key-function (lambda () "secret\nverbose"))
        (komga-sync--api-key nil))
    (should-error (komga-sync--curl-config) :type 'error)))

(ert-deftest komga-sync-test-curl-config-carries-credentials ()
  (let* ((komga-sync-api-key-function (lambda () "secret\"key"))
         (komga-sync--api-key nil)
         (config (komga-sync--curl-config "application/json")))
    (should (string-match-p "X-API-Key: secret\\\\\"key" config))
    (should (string-match-p "Accept: " config))
    (should (string-match-p "Content-Type: application/json" config))))


;;;; href matching

(ert-deftest komga-sync-test-href-index ()
  (komga-sync-tests--with-book
    (should (equal (komga-sync--href-index "OEBPS/chap1.xhtml") 1))
    ;; Komga sends a fragment for some locators.
    (should (equal (komga-sync--href-index "OEBPS/chap1.xhtml#p12") 1))
    ;; The table of contents nov prepends is index 0 and must still match.
    (should (equal (komga-sync--href-index "OEBPS/toc.ncx") 0))
    (should (null (komga-sync--href-index "OEBPS/nope.xhtml")))))

(ert-deftest komga-sync-test-href-index-percent-encoded ()
  (komga-sync-tests--with-book
    (should (equal (komga-sync--href-index "OEBPS/a b.xhtml") 2))
    (should (equal (komga-sync--href-index "OEBPS/a%20b.xhtml") 2))))

(ert-deftest komga-sync-test-document-path-is-archive-relative ()
  "The join key with Komga is the archive relative path."
  (komga-sync-tests--with-book
    (should (equal (komga-sync--document-path 1) "OEBPS/chap1.xhtml"))))


;;;; Progression translation

(ert-deftest komga-sync-test-body-bounds-skips-preamble ()
  (komga-sync-tests--with-book
    (pcase-let ((`(,start ,end ,size)
                 (komga-sync--body-bounds (cdr (aref nov-documents 1)))))
      (should (> start 0))
      (should (< start end))
      (should (<= end size))
      ;; The XML and CSS preamble is real and must not be counted as text.
      (should (> start 100)))))

(ert-deftest komga-sync-test-progression-is-within-body-range ()
  (komga-sync-tests--with-book
    (insert (apply #'concat (make-list 40 komga-sync-tests--body)))
    (pcase-let ((`(,start ,_end ,size)
                 (komga-sync--body-bounds (cdr (aref nov-documents 1)))))
      (goto-char (point-min))
      (let ((p (komga-sync--point-to-progression 1 (point))))
        (should (>= p 0.0))
        ;; Start of the buffer maps to the start of the body, not of the file.
        (should (< (abs (- p (/ (float start) size))) 0.001))))))

(ert-deftest komga-sync-test-progression-round-trip ()
  (komga-sync-tests--with-book
    (insert (apply #'concat (make-list 40 komga-sync-tests--body)))
    (dolist (pos (list (point-min)
                       (/ (point-max) 4)
                       (/ (point-max) 2)
                       (- (point-max) 1)))
      (let* ((progression (komga-sync--point-to-progression 1 pos))
             (back (komga-sync--progression-to-point 1 progression)))
        (should (<= 0.0 progression 1.0))
        ;; Round tripping goes through a byte fraction, so allow a small
        ;; rounding slack rather than demanding exact equality.
        (should (< (abs (- back pos)) 8))))))

(ert-deftest komga-sync-test-progression-is-clamped ()
  (komga-sync-tests--with-book
    (insert "short")
    (should (<= (komga-sync--progression-to-point 1 0.0) (point-max)))
    (should (>= (komga-sync--progression-to-point 1 0.0) (point-min)))
    (should (<= (komga-sync--progression-to-point 1 1.0) (point-max)))
    (should (>= (komga-sync--progression-to-point 1 -5.0) (point-min)))))

(ert-deftest komga-sync-test-total-progression-skips-toc ()
  (komga-sync-tests--with-book
    (let ((first (komga-sync--total-progression 1 0.0))
          (middle (komga-sync--total-progression 1 0.5))
          (last (komga-sync--total-progression 2 0.9)))
      (should (= first 0.0))
      (should (< first middle))
      (should (< middle last))
      (should (<= last 1.0)))))


;;;; Locators

(ert-deftest komga-sync-test-current-locator-shape ()
  (komga-sync-tests--with-book
    (insert (apply #'concat (make-list 40 komga-sync-tests--body)))
    (goto-char (/ (point-max) 2))
    (let* ((locator (komga-sync--current-locator))
           (locations (alist-get 'locations locator)))
      (should (equal (alist-get 'href locator) "OEBPS/chap1.xhtml"))
      (should (alist-get 'progression locations))
      (should (alist-get 'fragments locations))
      (should (alist-get 'highlight (alist-get 'text locator)))
      ;; Must survive json-serialize, which is how it reaches Komga.
      (should (stringp (json-serialize
                        (komga-sync--progression-payload locator)))))))

(ert-deftest komga-sync-test-locator-omits-empty-snippet ()
  (komga-sync-tests--with-book
    (goto-char (point-min))
    (should-not (alist-get 'text (komga-sync--current-locator)))))

(ert-deftest komga-sync-test-fragment-point-round-trip ()
  (komga-sync-tests--with-book
    (insert (apply #'concat (make-list 40 komga-sync-tests--body)))
    (goto-char 123)
    (let ((locator (komga-sync--current-locator)))
      (should (equal (komga-sync--locator-fragment-point locator 1) 123))
      ;; A fragment from a different document must not be trusted.
      (should (null (komga-sync--locator-fragment-point locator 2))))))

(ert-deftest komga-sync-test-fragment-point-accepts-list-from-server ()
  "Komga returns JSON arrays as lists, unlike the vectors we send."
  (komga-sync-tests--with-book
    (let ((locator '((href . "OEBPS/chap1.xhtml")
                     (locations . ((fragments . ("nov-index-1" "nov-point-77")))))))
      (should (equal (komga-sync--locator-fragment-point locator 1) 77)))))

(ert-deftest komga-sync-test-snippet-point-tolerates-rewrapping ()
  "The snippet is stored normalised and must match a differently wrapped buffer."
  (komga-sync-tests--with-book
    (insert "one two three\nfour five six seven eight nine ten eleven twelve")
    (let ((locator '((text . ((highlight . "three four five six seven"))))))
      (should (equal (komga-sync--locator-snippet-point locator)
                     (save-excursion
                       (goto-char (point-min))
                       (search-forward "three")
                       (match-beginning 0)))))))

(ert-deftest komga-sync-test-snippet-point-ignores-short-snippets ()
  (komga-sync-tests--with-book
    (insert "abc")
    (should (null (komga-sync--locator-snippet-point
                   '((text . ((highlight . "abc")))))))))


;;;; State

(ert-deftest komga-sync-test-state-round-trip ()
  (let* ((dir (make-temp-file "komga-sync-state-" t))
         (komga-sync-state-directory dir)
         (komga-sync--state nil))
    (unwind-protect
        (progn
          (komga-sync--book-remember "/books/a.epub" "123:abc" "BOOK1")
          (setq komga-sync--state nil)
          (let ((entry (komga-sync--book-entry "/books/a.epub")))
            (should entry)
            (should (equal (alist-get 'book-id entry) "BOOK1"))
            (should (equal (alist-get 'content-key entry) "123:abc")))
          (komga-sync--book-forget "/books/a.epub")
          (setq komga-sync--state nil)
          (should (null (komga-sync--book-entry "/books/a.epub"))))
      (delete-directory dir t))))

(ert-deftest komga-sync-test-relinking-replaces-old-entry ()
  (let* ((dir (make-temp-file "komga-sync-state-" t))
         (komga-sync-state-directory dir)
         (komga-sync--state nil))
    (unwind-protect
        (progn
          (komga-sync--book-remember "/books/a.epub" "123:abc" "BOOK1")
          (komga-sync--book-remember "/books/a.epub" "123:abc" "BOOK2")
          (should (= (length (komga-sync--links)) 1))
          (should (equal (alist-get 'book-id
                                    (komga-sync--book-entry "/books/a.epub"))
                         "BOOK2")))
      (delete-directory dir t))))

(ert-deftest komga-sync-test-device-id-is-stable ()
  (let* ((dir (make-temp-file "komga-sync-state-" t))
         (cache (make-temp-file "komga-sync-cache-" t))
         (komga-sync-state-directory dir)
         (komga-sync-cache-directory cache)
         (komga-sync--state nil)
         (komga-sync--device-id nil))
    (unwind-protect
        (let ((first (komga-sync--device-id)))
          (setq komga-sync--state nil komga-sync--device-id nil)
          (should (equal first (komga-sync--device-id))))
      (delete-directory dir t)
      (delete-directory cache t))))

(ert-deftest komga-sync-test-device-id-is-not-shared-between-machines ()
  "The device id must not live in the directory synced between machines."
  (let* ((dir (make-temp-file "komga-sync-state-" t))
         (cache (make-temp-file "komga-sync-cache-" t))
         (komga-sync-state-directory dir)
         (komga-sync-cache-directory cache)
         (komga-sync--state nil)
         (komga-sync--device-id nil))
    (unwind-protect
        (progn
          (komga-sync--book-remember "/books/a.epub" "1:a" "BOOK1")
          (komga-sync--device-id)
          (should-not (alist-get 'device-id
                                 (komga-sync--read-file
                                  (komga-sync--state-file))))
          (should (file-exists-p (komga-sync--device-file))))
      (delete-directory dir t)
      (delete-directory cache t))))

(ert-deftest komga-sync-test-forget-drops-the-content-match ()
  "Unlinking must also drop the content keyed entry, or it comes back."
  (let* ((dir (make-temp-file "komga-sync-state-" t))
         (komga-sync-state-directory dir)
         (komga-sync--state nil))
    (unwind-protect
        (progn
          (komga-sync--book-remember "/books/a.epub" "123:abc" "BOOK1")
          (komga-sync--book-forget "/books/a.epub" "123:abc")
          (setq komga-sync--state nil)
          (should (null (komga-sync--links))))
      (delete-directory dir t))))

(ert-deftest komga-sync-test-links-are-stored-separately ()
  "Each link gets its own file so machines cannot overwrite each other."
  (let* ((dir (make-temp-file "komga-sync-state-" t))
         (komga-sync-state-directory dir)
         (komga-sync--state nil))
    (unwind-protect
        (progn
          (komga-sync--book-remember "/books/a.epub" "1:a" "BOOK1")
          ;; Another machine adds a link while this session is running.
          (komga-sync--write-file
           (komga-sync--link-file "/books/b.epub")
           '((path . "/books/b.epub") (content-key . "2:b") (book-id . "BOOK2")))
          (komga-sync--book-remember "/books/c.epub" "3:c" "BOOK3")
          (setq komga-sync--state nil)
          (let ((links (komga-sync--links)))
            (should (assoc "/books/a.epub" links))
            (should (assoc "/books/b.epub" links))
            (should (assoc "/books/c.epub" links))))
      (delete-directory dir t))))

(ert-deftest komga-sync-test-migrates-the-old-state-file ()
  (let* ((dir (make-temp-file "komga-sync-state-" t))
         (komga-sync-state-directory dir)
         (komga-sync--state nil))
    (unwind-protect
        (progn
          (komga-sync--write-file
           (komga-sync--state-file)
           '((version . 1)
             (books ("/books/a.epub" (path . "/books/a.epub")
                     (content-key . "1:a") (book-id . "BOOK1")))))
          (should (equal (alist-get 'book-id
                                    (komga-sync--book-entry "/books/a.epub"))
                         "BOOK1"))
          (should-not (file-exists-p (komga-sync--state-file))))
      (delete-directory dir t))))

(ert-deftest komga-sync-test-damaged-link-is-not-silently-dropped ()
  (let* ((dir (make-temp-file "komga-sync-state-" t))
         (komga-sync-state-directory dir)
         (komga-sync--state nil)
         (messages nil))
    (unwind-protect
        (progn
          (komga-sync--book-remember "/books/a.epub" "1:a" "BOOK1")
          (with-temp-file (komga-sync--link-file "/books/a.epub")
            (insert "((path . \"/books/a.epub\""))
          (setq komga-sync--state nil)
          (cl-letf (((symbol-function 'message)
                     (lambda (fmt &rest args) (push (apply #'format fmt args)
                                                    messages))))
            (komga-sync--links))
          (should (seq-find (lambda (m) (string-match-p "damaged" m)) messages))
          ;; The file is left alone rather than overwritten.
          (should (file-exists-p (komga-sync--link-file "/books/a.epub"))))
      (delete-directory dir t))))


;;;; Link validation

(ert-deftest komga-sync-test-link-is-rejected-for-another-server ()
  (let ((file (make-temp-file "komga-sync-server-")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "book"))
          (let* ((key (komga-sync--content-key file))
                 (entry (list (cons 'server "https://b.example.com")
                              (cons 'content-key key))))
            (let ((komga-sync-server-url "https://a.example.com"))
              (should-not (komga-sync--entry-usable-p entry file)))
            (let ((komga-sync-server-url "https://b.example.com"))
              (should (komga-sync--entry-usable-p entry file)))))
      (delete-file file))))

(ert-deftest komga-sync-test-replacement-file-does-not-reuse-the-link ()
  "A different EPUB of the same size must not inherit the old link."
  (let ((file (make-temp-file "komga-sync-replace-"))
        (komga-sync-server-url "https://a.example.com"))
    (unwind-protect
        (progn
          (with-temp-file file (insert (make-string 70000 ?a)))
          (let ((entry (list (cons 'server komga-sync-server-url)
                             (cons 'content-key (komga-sync--content-key file))))
                (legacy (list (cons 'server komga-sync-server-url)
                              (cons 'content-key
                                    (komga-sync--legacy-content-key file)))))
            (should (komga-sync--entry-usable-p entry file))
            (should (komga-sync--entry-usable-p legacy file))
            ;; Same size, different content, within the first 64 KiB.
            (with-temp-file file
              (insert "b") (insert (make-string 69999 ?a)))
            (should-not (komga-sync--entry-usable-p entry file))
            (should-not (komga-sync--entry-usable-p legacy file))
            ;; Beyond it only the current fingerprint can tell, which is
            ;; why an old one is upgraded the first time it is used.
            (with-temp-file file
              (insert (make-string 69999 ?a)) (insert "b"))
            (should-not (komga-sync--entry-usable-p entry file))))
      (delete-file file))))

(ert-deftest komga-sync-test-legacy-key-is-upgraded-on-use ()
  "An old fingerprint must be rewritten, not kept alive indefinitely."
  (let* ((dir (make-temp-file "komga-sync-state-" t))
         (file (make-temp-file "komga-sync-book-"))
         (komga-sync-state-directory dir)
         (komga-sync-server-url "https://a.example.com")
         (komga-sync--state nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert (make-string 70000 ?a)))
          (komga-sync--book-remember file (komga-sync--legacy-content-key file)
                                     "BOOK1")
          (should (equal (alist-get 'book-id (komga-sync--stored-link file))
                         "BOOK1"))
          (setq komga-sync--state nil)
          (should (= (length (komga-sync--content-key-hash
                              (alist-get 'content-key
                                         (komga-sync--book-entry file))))
                     64)))
      (delete-directory dir t)
      (delete-file file))))

;;;; Matching

(ert-deftest komga-sync-test-match-by-size ()
  (let ((books '(((id . "A") (sizeBytes . 100))
                 ((id . "B") (sizeBytes . 200))
                 ((id . "C") (sizeBytes . 200)))))
    (should (equal (mapcar (lambda (b) (alist-get 'id b))
                           (komga-sync--match-by-size 100 books))
                   '("A")))
    ;; An ambiguous match must not be resolved silently.
    (should (= (length (komga-sync--match-by-size 200 books)) 2))
    (should (null (komga-sync--match-by-size 999 books)))))

(ert-deftest komga-sync-test-describe-book ()
  (let ((book '((id . "A") (name . "file") (size . "2 MiB")
                (media . ((pagesCount . 300)))
                (metadata . ((title . "Some Book")
                             (authors . (((name . "An Author")))))))))
    (should (string-match-p "Some Book" (komga-sync--describe-book book)))
    (should (string-match-p "An Author" (komga-sync--describe-book book)))))

;;;; Regressions

(ert-deftest komga-sync-test-media-profile-filter ()
  (let ((books '(((id . "A") (media . ((mediaProfile . "EPUB"))))
                 ((id . "B") (media . ((mediaProfile . "DIVINA"))))
                 ((id . "C") (media . ((mediaProfile . "PDF")))))))
    (let ((komga-sync-media-profile "EPUB"))
      (should (equal (mapcar (lambda (b) (alist-get 'id b))
                             (komga-sync--filter-books books))
                     '("A"))))
    (let ((komga-sync-media-profile nil))
      (should (= (length (komga-sync--filter-books books)) 3)))))

(ert-deftest komga-sync-test-unreported-profile-is-kept ()
  "Older Komga versions omit the profile; hiding everything is worse."
  (let ((komga-sync-media-profile "EPUB")
        (books '(((id . "A") (media . ((pagesCount . 10)))))))
    (should (= (length (komga-sync--filter-books books)) 1))))

(ert-deftest komga-sync-test-library-query ()
  (let ((komga-sync--libraries '(((id . "1") (name . "Books"))
                                 ((id . "2") (name . "Comics")))))
    (let ((komga-sync-libraries nil))
      (should (equal (komga-sync--library-query) "")))
    ;; Names are resolved, ids are kept, unknown entries pass through.
    (let ((komga-sync-libraries '("books")))
      (should (equal (komga-sync--library-query) "&library_id=1")))
    (let ((komga-sync-libraries '("2")))
      (should (equal (komga-sync--library-query) "&library_id=2")))
    (let ((komga-sync-libraries '("Books" "2")))
      (should (equal (komga-sync--library-query)
                     "&library_id=1&library_id=2")))
    (let ((komga-sync-libraries '("a b")))
      (should (equal (komga-sync--library-query) "&library_id=a%20b")))))

(ert-deftest komga-sync-test-download-file-name-from-url ()
  (should (equal (komga-sync--download-file-name
                  '((id . "A") (url . "/books/dir/Some Book.epub")
                    (name . "Some Book")))
                 "Some Book.epub")))

(ert-deftest komga-sync-test-download-file-name-falls-back ()
  (should (equal (komga-sync--download-file-name
                  '((id . "A") (name . "Some Book.epub")))
                 "Some Book.epub"))
  (should (equal (komga-sync--download-file-name '((id . "A"))) "A.epub"))
  ;; A name made only of directory syntax carries no usable basename.
  (should (equal (komga-sync--download-file-name '((id . "A") (url . "/")))
                 "A.epub")))

(ert-deftest komga-sync-test-download-file-name-cannot-escape ()
  "The server chooses this string, so it must not steer the write."
  (dolist (url '("../../etc/passwd" "/etc/passwd" ".." "."
                 "a/../../b.epub" "evil\0.epub"))
    (let ((name (komga-sync--download-file-name `((id . "A") (url . ,url)))))
      (should-not (string-match-p "/" name))
      (should-not (member name '("." "..")))
      (should-not (string-match-p "\0" name)))))

(ert-deftest komga-sync-test-download-target-uses-the-directory ()
  (let* ((komga-sync-download-directory "/tmp/komga-sync-test-downloads")
         (target (komga-sync--download-target
                  '((id . "A") (url . "/books/Some Book.epub")))))
    (should (equal target "/tmp/komga-sync-test-downloads/Some Book.epub"))))

(ert-deftest komga-sync-test-download-args-keep-key-off-argv ()
  (let ((komga-sync-server-url "https://example.com"))
    (let ((args (komga-sync--download-args "A" "/tmp/o")))
      (should (equal (car args) "-q"))
      (should (member "--config" args))
      (should (member "%{http_code}" args))
      (should (member "https://example.com/api/v1/books/A/file" args))
      (should-not (seq-find (lambda (a) (string-match-p "X-API-Key" a)) args)))))

(ert-deftest komga-sync-test-apply-locator-in-undisplayed-buffer ()
  "Applying a locator must work when the buffer is not on screen.
The asynchronous pull runs from a process sentinel, where the target
buffer is frequently not the one displayed in the selected window."
  (komga-sync-tests--with-book
    (cl-letf (((symbol-function 'nov-goto-document)
               (lambda (index) (setq nov-documents-index index))))
      (should-not (eq (current-buffer) (window-buffer (selected-window))))
      (insert (apply #'concat (make-list 40 komga-sync-tests--body)))
      (should (komga-sync--apply-locator
               '((href . "OEBPS/chap1.xhtml")
                 (locations . ((progression . 0.5)))))))))

(ert-deftest komga-sync-test-document-title-uses-heading ()
  "The displayed document is named after its first rendered line."
  (komga-sync-tests--with-book
    (insert "\n\nCHAPITRE 3\n\nIl faisait vingt-sept degrés.\n")
    (should (equal (komga-sync--document-title 1) "CHAPITRE 3"))
    ;; Documents that are not rendered fall back to the manifest id.
    (should (equal (komga-sync--document-title 2) "c2"))
    ;; A document rendering to nothing must not break locator building.
    (erase-buffer)
    (should (equal (komga-sync--document-title 1) "c1"))))

;;;; Push safety

(defmacro komga-sync-tests--with-push (requests &rest body)
  "Run BODY in a fake linked book buffer, recording pushes into REQUESTS."
  (declare (indent 1) (debug t))
  `(komga-sync-tests--with-book
     (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
               ((symbol-function 'nov-goto-document)
                (lambda (index) (setq nov-documents-index index)))
               ((symbol-function 'komga-sync--device-id) (lambda () "test"))
               ((symbol-function 'komga-sync--request-async)
                (lambda (method path payload _callback)
                  (push (list method path payload) ,requests)
                  nil))
               ((symbol-function 'komga-sync--request)
                (lambda (method path &optional payload)
                  (push (list method path payload) ,requests)
                  (cons 204 nil))))
       (setq komga-sync--book-id "BOOK1")
       (insert (apply #'concat (make-list 40 komga-sync-tests--body)))
       ,@body)))

(ert-deftest komga-sync-test-conflict-latches ()
  "After a 409 no automatic push may run, or the remote position dies."
  (let (requests)
    (komga-sync-tests--with-push requests
      (komga-sync--handle-push-result (current-buffer) '(1 . 2) nil 409)
      (should komga-sync--conflict)
      (goto-char (point-max))
      (komga-sync--push)
      (should (null requests))
      ;; Taking the remote position resolves it, and pushing resumes.
      (komga-sync--record-applied '((href . "OEBPS/chap1.xhtml")))
      (should-not komga-sync--conflict)
      (goto-char (point-min))
      (komga-sync--push)
      (should requests))))

(ert-deftest komga-sync-test-mismatch-stops-pushing ()
  "A locator Komga refuses as absent must not be retried forever."
  (let (requests)
    (komga-sync-tests--with-push requests
      (komga-sync--handle-push-result (current-buffer) '(1 . 2) nil 400)
      (should komga-sync--mismatch)
      (goto-char (point-max))
      (komga-sync--push)
      (should (null requests)))))

(ert-deftest komga-sync-test-push-records-the-position-sent ()
  "The position marked as synced must be the one the request carried."
  (let (requests)
    (komga-sync-tests--with-push requests
      (goto-char (+ (point-min) 100))
      (let ((sent (cons nov-documents-index (point))))
        (komga-sync--push t)
        ;; The reader moves on while the request is still in flight.
        (goto-char (point-max))
        (komga-sync--handle-push-result (current-buffer) sent nil 204)
        (should (equal komga-sync--pushed-position sent))
        ;; The newer position is therefore still pending, not lost.
        (should (komga-sync--position-changed-p))))))

(ert-deftest komga-sync-test-applying-a-locator-does-not-push ()
  "Moving to the remote position must not push the position left behind."
  (let (requests)
    (komga-sync-tests--with-push requests
      (goto-char (point-max))
      (komga-sync--apply-locator
       '((href . "OEBPS/chap1.xhtml") (locations . ((progression . 0.1)))))
      (should (null requests))
      ;; And the arrival counts as synced, so nothing pushes it back.
      (should-not (komga-sync--position-changed-p)))))

(ert-deftest komga-sync-test-chapter-advice-is-quiet-while-applying ()
  (let (requests)
    (komga-sync-tests--with-push requests
      (let ((komga-sync-mode t)
            (komga-sync--applying t))
        (komga-sync--before-goto-document)
        (should (null requests))))))


;;;; Cross edition fallback

(ert-deftest komga-sync-test-total-progression-inverts ()
  (komga-sync-tests--with-book
    (dolist (total '(0.0 0.25 0.5 0.75 1.0))
      (pcase-let ((`(,index . ,progression)
                   (komga-sync--total-progression-position total)))
        (should (> index 0))
        (should (<= 0.0 progression 1.0))
        (should (< (abs (- (komga-sync--total-progression index progression)
                           total))
                   0.001))))))

(ert-deftest komga-sync-test-foreign-href-falls-back-to-total ()
  "A locator from a different EPUB build still positions approximately."
  (komga-sync-tests--with-book
    (cl-letf (((symbol-function 'nov-goto-document)
               (lambda (index) (setq nov-documents-index index))))
      (insert (apply #'concat (make-list 40 komga-sync-tests--body)))
      (should (eq (komga-sync--apply-locator
                   '((href . "OEBPS/Text/nowhere.xhtml")
                     (locations . ((progression . 0.5)
                                   (totalProgression . 0.5)))))
                  'approximate))
      ;; Without a whole book fraction there is nothing to work from.
      (should-not (komga-sync--apply-locator
                   '((href . "OEBPS/Text/nowhere.xhtml")
                     (locations . ((progression . 0.5)))))))))


;;;; Teardown

(ert-deftest komga-sync-test-teardown-removes-global-hooks ()
  "Disabling the last buffer must not leave advice or timers behind."
  (komga-sync-tests--with-book
    (let ((komga-sync--idle-timer nil))
      (cl-letf (((symbol-function 'komga-sync--other-mode-buffers-p)
                 (lambda () nil)))
        (advice-add 'nov-goto-document :before #'komga-sync--before-goto-document)
        (add-hook 'kill-emacs-hook #'komga-sync--kill-emacs)
        (setq komga-sync--idle-timer (run-with-idle-timer 5 t #'ignore))
        (komga-sync--teardown)
        (should-not (advice-member-p #'komga-sync--before-goto-document
                                     'nov-goto-document))
        (should-not (memq #'komga-sync--kill-emacs kill-emacs-hook))
        (should (null komga-sync--idle-timer))))))

;;;; Pull safety

(defmacro komga-sync-tests--with-pull (captured &rest body)
  "Run BODY in a fake linked book buffer, capturing the pull callback.
CAPTURED is set to the function the pull handed to the transport."
  (declare (indent 1) (debug t))
  `(komga-sync-tests--with-book
     (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
               ((symbol-function 'nov-goto-document)
                (lambda (index) (setq nov-documents-index index)))
               ((symbol-function 'komga-sync--request-async)
                (lambda (_method _path _payload fn)
                  (setq ,captured fn)
                  nil)))
       (setq komga-sync--book-id "BOOK1")
       (insert (apply #'concat (make-list 40 komga-sync-tests--body)))
       ,@body)))

(defun komga-sync-tests--answer (progression)
  "Return a fake transport answer holding a locator at PROGRESSION."
  (cons 200 `((locator . ((href . "OEBPS/chap1.xhtml")
                          (locations . ((progression . ,progression))))))))

(ert-deftest komga-sync-test-pull-does-not-rewind-past-local-reading ()
  "A slow pull must not undo a position the reader has already moved to."
  (let (callback moved)
    (komga-sync-tests--with-pull callback
      (let ((komga-sync-mode t)
            (komga-sync-pull-on-open 'auto))
        (goto-char (point-min))
        (komga-sync--pull-async)
        (should callback)
        ;; Reading continues while the request is still in flight.
        (goto-char (point-max))
        (let ((here (point)))
          (cl-letf (((symbol-function 'message)
                     (lambda (&rest _) (setq moved t))))
            (funcall callback (komga-sync-tests--answer 0.1)))
          (should (= (point) here)))))))

(ert-deftest komga-sync-test-pull-applies-when-nothing-moved ()
  (let (callback)
    (komga-sync-tests--with-pull callback
      (let ((komga-sync-mode t)
            (komga-sync-pull-on-open 'auto))
        (goto-char (point-min))
        (komga-sync--pull-async)
        (funcall callback (komga-sync-tests--answer 0.9))
        (should (> (point) (point-min)))))))

(ert-deftest komga-sync-test-pull-is-dropped-when-mode-is-off ()
  "A callback arriving after the mode was disabled must do nothing."
  (let (callback)
    (komga-sync-tests--with-pull callback
      (let ((komga-sync-mode t)
            (komga-sync-pull-on-open 'auto))
        (goto-char (point-min))
        (komga-sync--pull-async))
      (let ((komga-sync-mode nil)
            (start (point)))
        (funcall callback (komga-sync-tests--answer 0.9))
        (should (= (point) start))))))

(ert-deftest komga-sync-test-pull-is-dropped-when-relinked ()
  (let (callback)
    (komga-sync-tests--with-pull callback
      (let ((komga-sync-mode t)
            (komga-sync-pull-on-open 'auto))
        (goto-char (point-min))
        (komga-sync--pull-async)
        (setq komga-sync--book-id "BOOK2")
        (let ((start (point)))
          (funcall callback (komga-sync-tests--answer 0.9))
          (should (= (point) start)))))))

;;;; Transport lifecycle

(defun komga-sync-tests--temp-files ()
  "Return the transport temporary files currently on disk."
  (directory-files temporary-file-directory nil
                   "\\`komga-sync-\\(out\\|body\\)-"))

(ert-deftest komga-sync-test-cancelled-request-cleans-up ()
  "Killing a request must not leak its buffer or temporary files.
An exit push cancels whatever is in flight, so this happens routinely."
  (skip-unless (executable-find "curl"))
  (let* ((komga-sync-server-url "http://127.0.0.1:9")
         (komga-sync-timeout 30)
         (komga-sync-api-key-function (lambda () "test"))
         (komga-sync--api-key nil)
         (before (komga-sync-tests--temp-files))
         (buffers (length (buffer-list)))
         (called nil)
         (proc (komga-sync--request-async
                "PUT" "/api/v1/books/X/progression" '((a . 1))
                (lambda (_result) (setq called t)))))
    (should (process-live-p proc))
    (should (> (length (komga-sync-tests--temp-files)) (length before)))
    (delete-process proc)
    ;; The sentinel runs on the next opportunity, not immediately.
    (with-timeout (5 (ert-fail "sentinel never ran"))
      (while (komga-sync-tests--leftovers-p before) (accept-process-output nil 0.05)))
    (should-not called)
    (should (equal (komga-sync-tests--temp-files) before))
    (should (<= (length (buffer-list)) buffers))))

(defun komga-sync-tests--leftovers-p (before)
  "Return non-nil while transport temporary files beyond BEFORE remain."
  (not (equal (komga-sync-tests--temp-files) before)))

(ert-deftest komga-sync-test-pull-is-dropped-after-an-intervening-push ()
  "GET, then a push, then the GET answer: the answer describes the past.
Point has not moved, so only the generation counter can tell that the
value just read has already been replaced on the server by our own."
  (let (callback)
    (komga-sync-tests--with-pull callback
      (let ((komga-sync-mode t)
            (komga-sync-pull-on-open 'auto))
        (goto-char (point-min))
        (komga-sync--pull-async)
        (should callback)
        ;; An explicit push completes while the GET is still in flight.
        (cl-letf (((symbol-function 'komga-sync--request)
                   (lambda (&rest _) (cons 204 nil))))
          (komga-sync--push t t))
        (should (equal komga-sync--pushed-position
                       (cons nov-documents-index (point))))
        (let ((here (point)))
          (funcall callback (komga-sync-tests--answer 0.9))
          (should (= (point) here)))))))

(ert-deftest komga-sync-test-generation-survives-unrelated-buffers ()
  "The counter is per buffer, so one book cannot invalidate another."
  (komga-sync-tests--with-book
    (let ((first komga-sync--generation))
      (with-temp-buffer (komga-sync--invalidate))
      (should (eql komga-sync--generation first)))))

(provide 'komga-sync-tests)
;;; komga-sync-tests.el ends here
