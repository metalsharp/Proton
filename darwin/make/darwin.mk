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
        audit module help targets addons mullion winemetalgl wfdxcompat linuxhost dxvk vkd3d tools app
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
## Add-ons: the graphics layers and tools MetalSharp Wine ships beside Wine.
##   mullion       Direct3D 10/11/12 on Metal (the default Direct3D), with its NGX core and NVAPI
##   winemetalgl   OpenGL 4.6 on Metal (the default OpenGL)
##   wfdxcompat    the Rockstar launcher companion for Mullion
##   linuxhost     the Linux module host (darwin/linuxhost), which runs the Linux code Easy Anti-Cheat's EOS
##                 bootstrapper loads into itself; ntdll finds it in lib/linuxhost
##   dxvk          DXVK-MacOS: Direct3D 9/10/11 on MoltenVK, opt-in
##   vkd3d         VKD3D-Proton-MacOS: Direct3D 12 on MoltenVK, opt-in, with its own DXGI, D3D10/11, NGX core and
##                 NVAPI, and MetalSharp's MoltenVK 1.4.3, which replaces the 1.4.2 from the dependencies
##   tools         innoextract and cabextract
## Each builds inside its source tree, so the build uses a git worktree of the submodule under src/,
## which keeps the submodule itself clean. `make ADDONS=` builds without them.
##

ADDONS ?= mullion winemetalgl wfdxcompat linuxhost dxvk vkd3d tools

# addon-source <submodule> <name under src/>
define addon-source
$(STAMPS)/source-$(1): $(STAMPS)/root
	@test -e $(SRC)/$(1)/.git || { echo >&2 "!! the $(1) submodule is not checked out: git submodule update --init $(1)"; exit 1; }
	@echo ":: source: $(1)"
	if [ -e $(OBJ)/src/$(2)/.git ]; then \
	  git -C $(OBJ)/src/$(2) checkout -q --detach `git -C $(SRC)/$(1) rev-parse HEAD`; \
	else \
	  git -C $(SRC)/$(1) worktree prune && git -C $(SRC)/$(1) worktree add -q --detach $(OBJ)/src/$(2) HEAD; \
	fi
	if [ -f $(OBJ)/src/$(2)/.gitmodules ]; then git -C $(OBJ)/src/$(2) submodule update -q --init --recursive --depth 1; fi
	touch $$@
endef
$(eval $(call addon-source,mullion,mullion))
$(eval $(call addon-source,winemetalgl,winemetalgl))
$(eval $(call addon-source,wfdxcompat,wfdxcompat))
$(eval $(call addon-source,dxvk,dxvk-macos))
$(eval $(call addon-source,vkd3d-proton,vkd3d-proton))

# Static LLVM 15 libraries for Mullion's shader converter. build-llvm15.sh expects the LLVM source
# already unpacked under deps/src/llvm15; an existing MetalSharp Wine tree has the built libraries.
$(STAMPS)/llvm15: $(STAMPS)/toolchain
	@if [ ! -d $(OBJ)/deps/llvm15/lib ]; then \
	  if [ -d $(SEED)/deps/llvm15/lib ]; then \
	    echo ":: llvm15: cloning from $(SEED)"; cp -c -R $(SEED)/deps/llvm15 $(OBJ)/deps/llvm15; \
	  elif [ -d $(OBJ)/deps/src/llvm15/llvm-project-15.0.7.src ]; then \
	    cd $(OBJ) && env ROOT=$(OBJ) zsh $(OBJ)/scripts/build-llvm15.sh; \
	  else \
	    echo >&2 "!! Mullion needs LLVM 15.0.7: unpack llvm-project-15.0.7.src under $(OBJ)/deps/src/llvm15, or set SEED."; exit 1; \
	  fi; \
	fi
	touch $@

$(STAMPS)/addon-mullion: $(STAMPS)/wine $(STAMPS)/llvm15 $(STAMPS)/source-mullion
	@echo ":: mullion (logs/addon-mullion.log)"
	$(RUN)/build-mullion.sh > $(OBJ)/logs/addon-mullion.log 2>&1 || { tail -25 $(OBJ)/logs/addon-mullion.log; exit 1; }
	touch $@

$(STAMPS)/addon-winemetalgl: $(STAMPS)/wine $(STAMPS)/source-winemetalgl
	@echo ":: winemetalgl (logs/addon-winemetalgl.log)"
	$(RUN)/build-winemetalgl.sh > $(OBJ)/logs/addon-winemetalgl.log 2>&1 || { tail -25 $(OBJ)/logs/addon-winemetalgl.log; exit 1; }
	touch $@

$(STAMPS)/addon-wfdxcompat: $(STAMPS)/addon-mullion $(STAMPS)/source-wfdxcompat
	@echo ":: wfdxcompat (logs/addon-wfdxcompat.log)"
	$(RUN)/build-wfdxcompat.sh > $(OBJ)/logs/addon-wfdxcompat.log 2>&1 || { tail -25 $(OBJ)/logs/addon-wfdxcompat.log; exit 1; }
	touch $@

# The Linux module host is developed here, in darwin/linuxhost (MetalSharp Wine carries it as source/linuxhost):
# the build tree links it as src/linuxhost, and a change to it builds the host again.
LINUXHOST_SOURCES := $(wildcard $(SRC)/darwin/linuxhost/*.c $(SRC)/darwin/linuxhost/*.h $(SRC)/darwin/linuxhost/build.sh)

$(STAMPS)/addon-linuxhost: $(STAMPS)/toolchain $(LINUXHOST_SOURCES)
	@echo ":: linuxhost (logs/addon-linuxhost.log)"
	ln -sfn $(SRC)/darwin/linuxhost $(OBJ)/src/linuxhost
	$(RUN)/build-linuxhost.sh > $(OBJ)/logs/addon-linuxhost.log 2>&1 || { tail -25 $(OBJ)/logs/addon-linuxhost.log; exit 1; }
	touch $@

$(STAMPS)/addon-dxvk: $(STAMPS)/wine $(STAMPS)/source-dxvk
	@echo ":: dxvk (logs/addon-dxvk.log)"
	{ $(RUN)/build-dxvk-macos.sh && $(RUN)/stage-dxvk.sh; } > $(OBJ)/logs/addon-dxvk.log 2>&1 || { tail -25 $(OBJ)/logs/addon-dxvk.log; exit 1; }
	touch $@

# VKD3D-Proton-MacOS builds with its own scripts, from upstream trees its fetch-sources.sh clones and
# patches (VKD3D-Proton, MoltenVK, DXVK 2.7.1, NVAPI headers, DirectXShaderCompiler). MoltenVK is an
# Xcode build. The DXVK lane is staged again afterwards, to take this build's NGX core and NVAPI.
# The DXBC converter is DirectXShaderCompiler's; its build checks its generated sources against a
# clang-format it finds, and a clang-format of another version makes that check fail, so the build
# is told there is none.
VKD3D_WS := $(OBJ)/src/vkd3d-proton
VKD3D_ENV := env LLVM_MINGW=$(OBJ)/toolchain/$(MINGW_NAME)

$(STAMPS)/addon-vkd3d: $(STAMPS)/wine $(STAMPS)/addon-dxvk $(STAMPS)/source-vkd3d-proton
	@echo ":: vkd3d-proton and MoltenVK (logs/addon-vkd3d.log)"
	{ cd $(VKD3D_WS) && \
	  bash scripts/fetch-sources.sh && \
	  $(VKD3D_ENV) bash scripts/build-vkd3d-proton-arm64x.sh && \
	  $(VKD3D_ENV) bash scripts/build-dxvk-arm64x.sh && \
	  $(VKD3D_ENV) sh scripts/build-ngx-arm64x.sh && \
	  bash scripts/build-moltenvk.sh --externals && \
	  mkdir -p artifacts/build/dxbcconverter-universal && \
	  { c=artifacts/build/dxbcconverter-universal/CMakeCache.txt; \
	    if [ -f $$c ]; then sed -i '' 's|^CLANG_FORMAT_EXE:FILEPATH=.*|CLANG_FORMAT_EXE:FILEPATH=|' $$c; \
	    else printf 'CLANG_FORMAT_EXE:FILEPATH=\n' > $$c; fi; } && \
	  bash scripts/build-dxbcconverter.sh && \
	  bash scripts/fetch-metal-shaderconverter.sh && \
	  cd $(OBJ) && \
	  env ROOT=$(OBJ) zsh scripts/stage-moltenvk.sh && \
	  env ROOT=$(OBJ) zsh scripts/stage-vkd3d-proton.sh && \
	  env ROOT=$(OBJ) zsh scripts/stage-dxvk.sh; \
	} > $(OBJ)/logs/addon-vkd3d.log 2>&1 || { tail -30 $(OBJ)/logs/addon-vkd3d.log; exit 1; }
	touch $@

$(STAMPS)/addon-tools: $(STAMPS)/deps
	@for d in innoextract cabextract; do \
	  if [ -d $(SEED)/downloads/$$d ] && [ ! -d $(OBJ)/downloads/$$d ]; then \
	    mkdir -p $(OBJ)/downloads/$$d; \
	    for f in $(SEED)/downloads/$$d/*; do [ -f "$$f" ] && cp -c "$$f" $(OBJ)/downloads/$$d/; done; true; \
	  fi; \
	done
	@echo ":: tools (logs/addon-tools.log)"
	{ $(RUN)/build-innoextract.sh && $(RUN)/build-cabextract.sh; } > $(OBJ)/logs/addon-tools.log 2>&1 || { tail -25 $(OBJ)/logs/addon-tools.log; exit 1; }
	touch $@

ADDON_STAMPS := $(addprefix $(STAMPS)/addon-,$(ADDONS))
addons: $(ADDON_STAMPS)
mullion: $(STAMPS)/addon-mullion
winemetalgl: $(STAMPS)/addon-winemetalgl
wfdxcompat: $(STAMPS)/addon-wfdxcompat
linuxhost: $(STAMPS)/addon-linuxhost
dxvk: $(STAMPS)/addon-dxvk
vkd3d: $(STAMPS)/addon-vkd3d
tools: $(STAMPS)/addon-tools

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

$(STAMPS)/dist: $(STAMPS)/fex $(STAMPS)/payloads $(ADDON_STAMPS) $(addprefix $(SRC)/,$(DIST_COPY)) $(SRC)/appcompat/extract.py
	@echo ":: audit and package"
	rm -rf $(OBJ)/install/share/metalsharp
	$(RUN)/audit-macho.sh $(OBJ)/deps/prefix $(OBJ)/install
	@# The MetalSharp app's payloads (share/metalsharp: Steam files, Goldberg, FNA, Mono, the host runtime,
	@# redistributables), which the app expects in the Wine bundle. MetalSharp Wine stages them from
	@# MetalSharp's bundles (stage-metalsharp-assets.sh, stage-metalsharp-redist.sh) after this audit, and
	@# package.sh holds them to macOS 15 and rewrites their library paths; until the bundles are fetched
	@# here, they come from the seed tree.
	if [ -d $(SEED)/install/share/metalsharp ]; then \
	  rsync -a $(SEED)/install/share/metalsharp/ $(OBJ)/install/share/metalsharp/; \
	else echo >&2 "!! no share/metalsharp in $(SEED)/install: the MetalSharp app will not find its payloads"; fi
	@test -d "$(MACOS15_SDK)" || { echo >&2 "!! packaging needs a macOS 15 SDK: make MACOS15_SDK=<path>/MacOSX15.x.sdk"; exit 1; }
	cd $(OBJ) && env ROOT=$(OBJ) NO_TARBALL=1 MACOS15_SDK=$(MACOS15_SDK) zsh $(OBJ)/scripts/package.sh files
	cd $(OBJ) && env ROOT=$(OBJ) STRICT=1 zsh $(OBJ)/scripts/audit-macho.sh $(DST_DIR)
	cp -f $(addprefix $(SRC)/,$(DIST_COPY)) $(DST_BASE)/
	mkdir -p $(DST_DIR)/share/fex-emu && cp -f $(SRC)/FEX_Config.json $(DST_DIR)/share/fex-emu/Config.json
	@# the launcher's per-game tables, for the games Steam starts itself (Wine reads them at process start)
	mkdir -p $(DST_DIR)/share/proton && python3 $(SRC)/appcompat/extract.py --proton $(SRC)/proton --output $(DST_DIR)/share/proton/appcompat.env
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
## app: the signed application bundle, dist/MetalSharp-Wine.app, with Proton's launcher in it.
##
##   make app                                                         ad-hoc signed, to check the layout
##   make app SIGN_IDENTITY="Developer ID Application: Name (TEAM)" PROFILE=<file>.provisionprofile
##
## MetalSharp Wine's sign-app.sh builds and signs the bundle: Contents/MacOS, lib and share are the
## Wine tree, and the inner loader gets a bundle of its own. With a Developer ID and a provisioning
## profile that carries the cross-architecture entitlement, Windows programs get 4K pages and the low
## 4GB, so i386 programs run. The bundle identifier has to match the profile (BUNDLE_ID).
## Proton's files go in Contents/Resources, where files/ is a link to Contents, so the launcher finds
## files/bin/wine, files/lib and files/share as in dist/. The bundle is signed again after that.
##

APP := $(DST_BASE)/MetalSharp-Wine.app
SIGN_IDENTITY ?= -
SIGNED_NAME = $(shell sed -n 's|^D=$$ROOT/dist/||p' $(MSW)/scripts/sign-app.sh)

app: $(STAMPS)/dist
	@test -n "$(SIGNED_NAME)" || { echo >&2 "!! cannot tell which folder sign-app.sh packages"; exit 1; }
	ln -sfn files $(DST_BASE)/$(SIGNED_NAME)
	@# sign-app.sh stops at its profile lookup when there is no identity (the lookup's test fails under set -e),
	@# so an ad-hoc bundle could not be built: run a copy with that one line made harmless
	mkdir -p $(OBJ)/scripts-app && for f in $(MSW)/scripts/*; do ln -sfn $$f $(OBJ)/scripts-app/; done
	rm -f $(OBJ)/scripts-app/sign-app.sh
	sed 's/| head -1 )}/| head -1 || true )}/' $(MSW)/scripts/sign-app.sh > $(OBJ)/scripts-app/sign-app.sh
	cd $(OBJ) && env ROOT=$(OBJ) SIGN_IDENTITY="$(SIGN_IDENTITY)" $(if $(PROFILE),PROFILE="$(PROFILE)") \
	    $(if $(BUNDLE_ID),BUNDLE_ID="$(BUNDLE_ID)") MACOS15_SDK=$(MACOS15_SDK) zsh $(OBJ)/scripts-app/sign-app.sh
	rm -f $(DST_BASE)/$(SIGNED_NAME)
	cp -f $(addprefix $(DST_BASE)/,$(DIST_COPY) version) $(APP)/Contents/Resources/
	ln -sfn .. $(APP)/Contents/Resources/files
	@# the seal of the bundle covers Resources: sign it again, as sign-app.sh did
	if [ "$(SIGN_IDENTITY)" = "-" ]; then \
	  codesign -f -s - --entitlements $(DST_BASE)/wine.entitlements $(APP); \
	else \
	  codesign -f -s "$(SIGN_IDENTITY)" --timestamp $(if $(filter 0,$(HARDENED)),,-o runtime) \
	      --entitlements $(DST_BASE)/wine.entitlements $(APP); \
	fi
	codesign --verify --strict --deep $(APP)
	@echo ":: app: $(APP) (signed by: $(SIGN_IDENTITY))"

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
	@echo "make app          the application bundle (SIGN_IDENTITY=, PROFILE= for a Developer ID build)"
	@echo "make check-host   list missing build tools"
