SHELL := /usr/bin/env bash
BIN := backup-k8s-gpg
SCRIPT := backup-k8s-gpg.sh
PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin

VERSION := 1.2.0

.PHONY: help install uninstall lint fmt

help:
	@echo "Targets:"
	@echo "  install    Installiert $(SCRIPT) als $(BIN) nach $(BINDIR)"
	@echo "  uninstall  Entfernt $(BIN) aus $(BINDIR)"
	@echo "  lint       ShellCheck Linting"
	@echo "  fmt        (reserviert) Formatierung"

install:
	install -d "$(BINDIR)"
	install -m 0755 "$(SCRIPT)" "$(BINDIR)/$(BIN)"
	@echo "Installiert: $(BINDIR)/$(BIN)"

uninstall:
	@rm -f "$(BINDIR)/$(BIN)"
	@echo "Entfernt: $(BINDIR)/$(BIN)"

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "ShellCheck fehlt"; exit 1; }
	shellcheck -x "$(SCRIPT)"

fmt:
	@echo "Keine Formatierungsschritte definiert."
