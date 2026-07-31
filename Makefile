EMACS ?= emacs
BATCH = $(EMACS) -Q --batch --eval '(package-initialize)' -L .

.PHONY: test compile lint clean

test:
	$(BATCH) -l ert -l komga-sync-tests.el -f ert-run-tests-batch-and-exit

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile komga-sync.el

lint:
	$(BATCH) --eval '(progn (package-initialize) (unless (package-installed-p '\''package-lint) (package-refresh-contents) (package-install '\''package-lint)))' -l package-lint -f package-lint-batch-and-exit komga-sync.el
	$(BATCH) --eval '(checkdoc-file "komga-sync.el")'

clean:
	rm -f *.elc
