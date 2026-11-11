# Build rules for TARGET_OS=darwin (Apple Silicon macOS, native arm64). Included by Makefile.in.
#
# Stage 1 of SPEC.md section 12: every component is built by MetalSharp Wine's own, tested build
# script (darwin/metalsharp-wine/scripts), and this file gives those steps Proton's targets, order
# and output layout. The build directory is laid out as the checkout those scripts expect:
#
#   scripts patches resources tests docs   links into darwin/metalsharp-wine
#   src/wine                               a copy of the wine submodule (Wine builds in its tree)
#   src/FEX ...                            links to the other submodules (built out of tree)
#   toolchain/ downloads/ deps/ build/ install/ logs/   build state
#   dist/                                  the result, in Proton's layout (dist/files is the Wine tree)
#
# Written for the GNU make 3.81 that macOS ships.

MSW := $(SRC)/darwin/metalsharp-wine
STAMPS := $(OBJ)/.stamps
DST_BASE := $(OBJ)/dist
DST_DIR := $(DST_BASE)/files
MINGW_NAME := llvm-mingw-20261020-ucrt-macos-universal

# An existing MetalSharp Wine build tree to take the llvm-mingw toolchain (with its ARM64X runtimes
# already built) and the dependency tarballs from. Both are copied as APFS clones.
SEED ?= /Volumes/AverySSD/MetalSharp-Wine-Arm64-FEX

# A macOS 15 SDK. Packaging checks, against it, that nothing in the result needs a macOS newer than
# 15.0, the oldest release supported. Xcode only carries the current SDK.
MACOS15_SDK ?= $(firstword $(wildcard /Volumes/AverySSD/MetalSharp-redesign/work/sdk-15.5/MacOSX15.5.sdk \
                 $(HOME)/Library/Developer/SDKs/MacOSX15*.sdk /Library/Developer/CommandLineTools/SDKs/MacOSX15*.sdk))

J := $(shell sysctl -n hw.ncpu)
RUN = cd $(OBJ) && env ROOT=$(OBJ) zsh $(OBJ)/scripts

.PHONY: default all dist redist deploy clean-dist check-host root toolchain source deps wine fex payloads tests \
        audit module help targets
default: all
.DEFAULT_GOAL := default
all: dist

$(STAMPS):
	mkdir -p $@

##
## Host and build root
##

check-host:
	@bash $(SRC)/darwin/check-host.sh

$(STAMPS)/root: | $(STAMPS)
	@bash $(SRC)/darwin/check-host.sh
	@test -f $(MSW)/scripts/env.sh || { echo >&2 "!! darwin/metalsharp-wine is not checked out: git submodule update --init darwin/metalsharp-wine"; exit 1; }
	mkdir -p $(OBJ)/src $(OBJ)/logs $(OBJ)/deps/stamps $(OBJ)/build $(OBJ)/install $(OBJ)/downloads
	for d in scripts patches resources docs README.md; do ln -sfn $(MSW)/$$d $(OBJ)/$$d; done
	@# build-tests.sh writes tests/bin, which must not land in the script submodule
	mkdir -p $(OBJ)/tests && ln -sfn $(MSW)/tests/src $(OBJ)/tests/src
	touch $@
root: $(STAMPS)/root

##
## Toolchain: llvm-mingw with ARM64X (aarch64 + arm64ec) runtimes
##

$(STAMPS)/toolchain: $(STAMPS)/root
	@if [ ! -d $(OBJ)/toolchain/$(MINGW_NAME) ]; then \
	  if [ -d $(SEED)/toolchain/$(MINGW_NAME) ] && [ -e $(SEED)/deps/stamps/arm64ec-runtimes ]; then \
	    echo ":: toolchain: cloning $(MINGW_NAME) from $(SEED)"; \
	    mkdir -p $(OBJ)/toolchain && cp -c -R $(SEED)/toolchain/$(MINGW_NAME) $(OBJ)/toolchain/; \
	  else \
	    echo >&2 "!! No llvm-mingw toolchain. Set SEED=<a MetalSharp Wine build tree> or put $(MINGW_NAME),"; \
	    echo >&2 "!! with its ARM64X runtimes built (scripts/build-arm64ec-runtimes.sh), in $(OBJ)/toolchain."; \
	    exit 1; \
	  fi; \
	fi
	touch $(OBJ)/deps/stamps/arm64ec-runtimes
	touch $@
toolchain: $(STAMPS)/toolchain

##
## Sources
##

# The stamp carries the submodule commit, so a new pin refreshes the copy.
WINE_REV := $(shell git -C $(SRC)/wine rev-parse --short=12 HEAD 2>/dev/null)

$(STAMPS)/source-wine-$(WINE_REV): $(STAMPS)/root
	@test -n "$(WINE_REV)" || { echo >&2 "!! the wine submodule is not checked out"; exit 1; }
	@echo ":: source: wine $(WINE_REV)"
	if [ -d $(OBJ)/src/wine ]; then \
	  rsync -a --exclude=.git $(SRC)/wine/ $(OBJ)/src/wine/; \
	else \
	  cp -c -R $(SRC)/wine $(OBJ)/src/wine && rm -f $(OBJ)/src/wine/.git; \
	fi
	touch $@

$(STAMPS)/source: $(STAMPS)/source-wine-$(WINE_REV)
	@test -f $(SRC)/FEX/CMakeLists.txt || { echo >&2 "!! the FEX submodule is not checked out"; exit 1; }
	ln -sfn $(SRC)/FEX $(OBJ)/src/FEX
	touch $@
source: $(STAMPS)/source

##
## Dependencies (libraries Wine links against, built into deps/prefix)
##

$(STAMPS)/deps: $(STAMPS)/toolchain
	@if [ -d $(SEED)/downloads ]; then \
	  for f in $(SEED)/downloads/*.tar.* $(SEED)/downloads/*.tar; do \
	    [ -f "$$f" ] && [ ! -e $(OBJ)/downloads/$$(basename "$$f") ] && cp -c "$$f" $(OBJ)/downloads/; \
	  done; true; \
	fi
	@echo ":: deps (logs/dep-*.log)"
	$(RUN)/build-deps.sh
	@# build-deps.sh installs Khronos' universal MoltenVK as it comes; this Wine is arm64 only and the
	@# audit rejects other slices.
	f=$(OBJ)/deps/prefix/lib/libMoltenVK.dylib; \
	if [ "$$(lipo -archs $$f)" != arm64 ]; then \
	  lipo $$f -thin arm64 -output $$f.arm64 && mv $$f.arm64 $$f && codesign -f -s - $$f; \
	fi
	touch $@
deps: $(STAMPS)/deps

##
## Wine
##

$(STAMPS)/wine: $(STAMPS)/deps $(STAMPS)/source
	@echo ":: wine (logs/wine-*.log)"
	$(RUN)/build-wine.sh
	touch $@
wine: $(STAMPS)/wine

##
## FEX
##

$(STAMPS)/fex: $(STAMPS)/wine
	@echo ":: fex (logs/fex-*.log)"
	@# With CMake 3.28 or later, Ninja and a clang-scan-deps next to the compiler, FEX's bundled fmt builds
	@# itself as a C++ module as well, and CMake scans sources for modules. The scan runs clang-scan-deps
	@# without llvm-mingw's target wrapper, so it finds no headers. FEX uses no modules: turn both off
	@# through the initial cache, since build-fex.sh takes no extra CMake arguments.
	for t in arm64ec wow64; do \
	  grep -qs 'FMT_MODULE:BOOL=OFF' $(OBJ)/build/fex-$$t/CMakeCache.txt || \
	    { rm -rf $(OBJ)/build/fex-$$t && mkdir -p $(OBJ)/build/fex-$$t && \
	      printf 'FMT_MODULE:BOOL=OFF\nCMAKE_CXX_SCAN_FOR_MODULES:BOOL=OFF\n' > $(OBJ)/build/fex-$$t/CMakeCache.txt; }; \
	done
	$(RUN)/build-fex.sh
	touch $@
fex: $(STAMPS)/fex

##
## Prefix payloads: files wine.inf copies into every prefix it creates. Without the shader compilers
## prefix creation never finishes: setupapi keeps asking for the missing source file.
##   share/wine/shadercompilers   Microsoft's DXC and d3dcompiler_47, unmodified
##   share/wine/fonts             Liberation under the Windows file and family names
##   share/wine/mono, gecko       Wine Mono and Wine Gecko
##

$(STAMPS)/payloads: $(STAMPS)/wine
	@for d in shadercompilers fonts addons; do \
	  if [ -d $(SEED)/downloads/$$d ] && [ ! -d $(OBJ)/downloads/$$d ]; then \
	    mkdir -p $(OBJ)/downloads/$$d; \
	    for f in $(SEED)/downloads/$$d/*; do [ -f "$$f" ] && cp -c "$$f" $(OBJ)/downloads/$$d/; done; true; \
	  fi; \
	done
	@echo ":: prefix payloads"
	$(RUN)/stage-shader-compilers.sh
	$(RUN)/fetch-fonts.sh
	$(RUN)/fetch-addons.sh
	touch $@
payloads: $(STAMPS)/payloads

##
## Smoke tests and benchmarks
##

$(STAMPS)/tests: $(STAMPS)/fex
	@echo ":: tests"
	$(RUN)/build-tests.sh
	touch $@
tests: $(STAMPS)/tests

##
## dist: Proton's layout, with the relocatable Wine tree in dist/files
##

DIST_COPY := proton filelock.py user_settings.sample.py LICENSE LICENSE.proton dist.LICENSE

$(STAMPS)/dist: $(STAMPS)/fex $(STAMPS)/payloads $(addprefix $(SRC)/,$(DIST_COPY))
	@echo ":: audit and package"
	$(RUN)/audit-macho.sh $(OBJ)/deps/prefix $(OBJ)/install
	@test -d "$(MACOS15_SDK)" || { echo >&2 "!! packaging needs a macOS 15 SDK: make MACOS15_SDK=<path>/MacOSX15.x.sdk"; exit 1; }
	cd $(OBJ) && env ROOT=$(OBJ) NO_TARBALL=1 MACOS15_SDK=$(MACOS15_SDK) zsh $(OBJ)/scripts/package.sh files
	cd $(OBJ) && env ROOT=$(OBJ) STRICT=1 zsh $(OBJ)/scripts/audit-macho.sh $(DST_DIR)
	cp -f $(addprefix $(SRC)/,$(DIST_COPY)) $(DST_BASE)/
	mkdir -p $(DST_DIR)/share/fex-emu && cp -f $(SRC)/FEX_Config.json $(DST_DIR)/share/fex-emu/Config.json
	echo `date '+%s'` `git -C $(SRC) describe --tags --always` > $(DST_BASE)/version
	touch $@
dist: $(STAMPS)/dist
	@echo ":: dist: $(DST_BASE)"

audit:
	$(RUN)/audit-macho.sh $(OBJ)/deps/prefix $(OBJ)/install

redist: dist
	mkdir -p $(OBJ)/redist && rsync --delete -a $(DST_BASE)/ $(OBJ)/redist/

deploy: redist

clean-dist:
	rm -rf $(DST_BASE) $(STAMPS)/dist

##
## make module=<dll> module: rebuild one Wine module in place
##

module: $(STAMPS)/wine
	@test -n "$(module)" || { echo >&2 "!! usage: make module=<name> module"; exit 1; }
	cd $(OBJ) && env ROOT=$(OBJ) zsh -c 'source scripts/env.sh && make -C src/wine/dlls/$(module) -j$$JOBS'

help: targets
targets:
	@echo "make              build everything into dist/"
	@echo "make deps|wine|fex|tests   build one stage (and what it needs)"
	@echo "make module=xyz module     rebuild one Wine module"
	@echo "make redist       copy dist/ to redist/"
	@echo "make check-host   list missing build tools"
