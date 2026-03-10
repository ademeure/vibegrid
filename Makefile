.PHONY: dev build app run-app install-app setup-codesign appstore-pkg sync-web windows-exe windows-bin

dev:
	CLANG_MODULE_CACHE_PATH=$(PWD)/.build/ModuleCache SWIFT_MODULE_CACHE_PATH=$(PWD)/.build/ModuleCache swift run --disable-sandbox

build:
	CLANG_MODULE_CACHE_PATH=$(PWD)/.build/ModuleCache SWIFT_MODULE_CACHE_PATH=$(PWD)/.build/ModuleCache swift build --disable-sandbox

app:
	./scripts/build_app.sh

run-app: app
	open "$(PWD)/dist/VibeGrid.app"

install-app:
	./scripts/install_app.sh

setup-codesign:
	./scripts/setup_local_codesign_identity.sh

appstore-pkg:
	./scripts/build_app_store_pkg.sh

# Copy the canonical web UI into the Go embed directory for building.
# These files are gitignored — the single source of truth is Sources/VibeGrid/Resources/web/.
# bridge.js and favicon.svg are Windows-only and live permanently in the Go dir.
sync-web:
	cp Sources/VibeGrid/Resources/web/app.js    windows/vibegrid-win11/web/app.js
	cp Sources/VibeGrid/Resources/web/styles.css windows/vibegrid-win11/web/styles.css
	cp Sources/VibeGrid/Resources/web/index.html windows/vibegrid-win11/web/index.html

windows-exe: sync-web
	mkdir -p dist/windows
	GOOS=windows GOARCH=amd64 go build -C windows/vibegrid-win11 -ldflags "-H windowsgui" -o ../../dist/windows/VibeGrid-Windows11.exe .
	rm -f windows/vibegrid-win11/web/app.js windows/vibegrid-win11/web/styles.css windows/vibegrid-win11/web/index.html

windows-bin: windows-exe
	cd dist/windows && zip -9 VibeGrid-Windows11.zip VibeGrid-Windows11.exe
