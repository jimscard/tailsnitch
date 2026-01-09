VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
BUILD_ID ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE ?= $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

# Code signing configuration
SIGN_IDENTITY ?= "Developer ID Application"
ENTITLEMENTS ?= entitlements.plist
BINARY_NAME := tailsnitch
BUNDLE_ID ?= com.adversis.tailsnitch

LDFLAGS := -X github.com/Adversis/tailsnitch/cmd.Version=$(VERSION) \
           -X github.com/Adversis/tailsnitch/cmd.BuildID=$(BUILD_ID) \
           -X github.com/Adversis/tailsnitch/cmd.BuildDate=$(BUILD_DATE)

.PHONY: build install clean rebuild sign build-signed build-universal verify-signature notarize dist dist-dmg

build:
	go build -ldflags "$(LDFLAGS)" -o $(BINARY_NAME) .

build-signed: build sign

build-universal:
	GOOS=darwin GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o $(BINARY_NAME)-amd64 .
	GOOS=darwin GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o $(BINARY_NAME)-arm64 .
	lipo -create -output $(BINARY_NAME) $(BINARY_NAME)-amd64 $(BINARY_NAME)-arm64
	rm -f $(BINARY_NAME)-amd64 $(BINARY_NAME)-arm64
	$(MAKE) sign

sign:
	@echo "Signing $(BINARY_NAME) with $(SIGN_IDENTITY)..."
	codesign --force --sign "$(SIGN_IDENTITY)" \
		--options runtime \
		--timestamp \
		$(if $(wildcard $(ENTITLEMENTS)),--entitlements $(ENTITLEMENTS),) \
		$(BINARY_NAME)
	@echo "Code signing complete."

verify-signature:
	@echo "Verifying code signature..."
	@codesign --verify --verbose=4 $(BINARY_NAME)
	@codesign --display --verbose=4 $(BINARY_NAME) 2>&1 | grep -q "notarized" && \
		echo "✅ Binary is signed and notarized" || \
		echo "⚠️  Binary is signed but not notarized"
	@echo ""
	@echo "Checking Gatekeeper approval..."
	@spctl --assess --verbose=4 --type execute $(BINARY_NAME) 2>&1 && \
		echo "✅ Binary will pass Gatekeeper" || \
		echo "⚠️  Binary not approved by Gatekeeper (run 'make notarize')"

notarize:
	@echo "Creating archive for notarization..."
	@ditto -c -k --keepParent $(BINARY_NAME) $(BINARY_NAME).zip
	@echo "Submitting to Apple for notarization..."
	@xcrun notarytool submit $(BINARY_NAME).zip \
		--keychain-profile "notarytool-profile" \
		--wait
	@rm -f $(BINARY_NAME).zip
	@echo "✅ Notarization complete! Binary is ready for distribution."
	@echo "   Note: Standalone binaries can't be stapled, but the ticket is stored by Apple."

dist-dmg: build-signed
	@echo "Creating DMG for distribution..."
	@mkdir -p dist
	@hdiutil create -volname "$(BINARY_NAME)-$(VERSION)" \
		-srcfolder $(BINARY_NAME) \
		-ov -format UDZO \
		dist/$(BINARY_NAME)-$(VERSION).dmg
	@echo "Signing DMG..."
	@codesign --force --sign "$(SIGN_IDENTITY)" dist/$(BINARY_NAME)-$(VERSION).dmg
	@echo "Notarizing DMG..."
	@xcrun notarytool submit dist/$(BINARY_NAME)-$(VERSION).dmg \
		--keychain-profile "notarytool-profile" \
		--wait
	@echo "Stapling DMG..."
	@xcrun stapler staple dist/$(BINARY_NAME)-$(VERSION).dmg
	@echo "✅ Distribution DMG created: dist/$(BINARY_NAME)-$(VERSION).dmg"

dist: clean build-signed notarize
	@echo "✅ Distribution-ready binary created: $(BINARY_NAME)"
	@$(MAKE) verify-signature

rebuild: clean
	go build -a -ldflags "$(LDFLAGS)" -o $(BINARY_NAME) .

install:
	go install -ldflags "$(LDFLAGS)" .

clean:
	rm -f $(BINARY_NAME) $(BINARY_NAME)-amd64 $(BINARY_NAME)-arm64
	go clean -cache
