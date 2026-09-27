# The repo has no build system, and a tree of shell scripts does not need one
# until it has to become a package. This is the lightest thing that works: the
# deb is staged from the same manifest the path-ownership tests read, so what
# the package claims to own and what it actually installs cannot drift.

SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
BUILD := $(ROOT)/build
STAGE := $(BUILD)/omarchy
OUT := $(BUILD)/deb

VERSION := $(shell cat $(ROOT)/version)
# A detached or non-release build is exactly when the version needs to say
# which commit it came from, and `+g<sha>` sorts after the release.
SHA := $(shell git -C $(ROOT) rev-parse --short HEAD 2>/dev/null)
ifneq ($(SHA),)
VERSION := $(VERSION)+g$(SHA)
endif

ARCH := all
DEB := $(OUT)/omarchy_$(VERSION)_$(ARCH).deb

# The directories that make up the installed tree.
TREE_DIRS := bin config default install manual migrations shell themes

.PHONY: all test deb clean omarchy-deb-packages omarchy-deb-manifest

all: test

test:
	@$(ROOT)/test/all

# Both generated files, so a change to the Arch package list or the name map
# cannot leave the deb describing a different machine than the tree.
omarchy-deb-packages:
	@OMARCHY_PATH=$(ROOT) $(ROOT)/bin/omarchy-deb-packages

omarchy-deb-manifest:
	@mkdir -p $(ROOT)/packaging/ubuntu/deb
	@OMARCHY_PATH=$(ROOT) $(ROOT)/bin/omarchy-deb-manifest > $(ROOT)/packaging/ubuntu/deb/omarchy.manifest

deb: omarchy-deb-packages omarchy-deb-manifest
	@rm -rf $(STAGE) $(OUT)
	@mkdir -p $(STAGE)/DEBIAN $(STAGE)/usr/bin $(STAGE)/usr/share/omarchy $(OUT)
	@for directory in $(TREE_DIRS); do \
		cp -a $(ROOT)/$$directory $(STAGE)/usr/share/omarchy/; \
	done
	@cp -a $(ROOT)/version $(STAGE)/usr/share/omarchy/version
	@# docs/file-layout.md already says the branding files install at the tree
	@# root, and default/chromium/extensions/copy-url/icon.png is a relative
	@# symlink to ../../../../icon.png -- so without these the package ships a
	@# dangling link.
	@for branding in icon.png icon.txt logo.svg logo.txt; do \
		[ -e $(ROOT)/$$branding ] && cp -a $(ROOT)/$$branding $(STAGE)/usr/share/omarchy/; \
	done; true
	@# The router and every command beside it, by bare name: 460 commands shell
	@# out to each other by name, so a binary that is not on PATH is a command
	@# that cannot find its neighbours.
	@cp -a $(ROOT)/bin/omarchy $(STAGE)/usr/bin/omarchy
	@find $(ROOT)/bin -maxdepth 1 -type f -name 'omarchy-*' -exec cp -a {} $(STAGE)/usr/bin/ \;
	@install -Dm644 $(ROOT)/etc/profile.d/omarchy.sh $(STAGE)/etc/profile.d/omarchy.sh
	@# 42 files call gum and jammy has no package for it. /usr/local/bin is ahead
	@# of /usr/bin on a stock install and is not dpkg-owned, which is what makes
	@# this a substitute rather than a renamed package.
	@install -Dm755 $(ROOT)/packaging/ubuntu/compat/gum $(STAGE)/usr/local/bin/gum
	@# The font the menu's icon glyphs are drawn with, so a packaged install
	@# shows them and a bare checkout knows why it does not.
	@install -Dm644 $(ROOT)/default/fonts/omarchy/omarchy.ttf \
		$(STAGE)/usr/share/fonts/omarchy/omarchy.ttf
	@install -Dm644 $(ROOT)/applications/icons/omarchy-dashboard.svg \
		$(STAGE)/usr/share/icons/hicolor/scalable/apps/omarchy-dashboard.svg
	@$(ROOT)/bin/omarchy-deb-control $(ROOT) $(VERSION) $(ARCH) > $(STAGE)/DEBIAN/control
	@install -Dm755 $(ROOT)/packaging/ubuntu/deb/postinst $(STAGE)/DEBIAN/postinst
	@dpkg-deb --root-owner-group --build $(STAGE) $(DEB)
	@echo "built $(DEB)"

clean:
	@rm -rf $(BUILD)
	@echo "removed $(BUILD)"
