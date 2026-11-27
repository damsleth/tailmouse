DERIVED := build
IPA := $(DERIVED)/Tailmouse.ipa

.PHONY: gen test mac run-mac install-mac ios-sim sim ipa release clean

gen:
	xcodegen generate --quiet

test:
	swift test --package-path Packages/TailmouseKit

mac: gen
	xcodebuild -project Tailmouse.xcodeproj -scheme TailmouseMac -configuration Debug \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS' build -quiet

# Matches the Mac app by path: the simulator app is also a process named Tailmouse.
# Waits for the old instance to exit, or `open` just activates the dying one.
STOP_MAC = pkill -f 'Tailmouse.app/Contents/MacOS/Tailmouse' || true; \
	while pgrep -qf 'Tailmouse.app/Contents/MacOS/Tailmouse'; do sleep 0.1; done

run-mac: mac
	@$(STOP_MAC)
	open $(DERIVED)/Build/Products/Debug/Tailmouse.app

# Launch at Login registers the app where it runs, so run it from /Applications.
# A Release build: Debug carries get-task-allow, which lets any process of the
# same user attach to an app that holds Accessibility.
install-mac: gen
	xcodebuild -project Tailmouse.xcodeproj -scheme TailmouseMac -configuration Release \
	  -derivedDataPath $(DERIVED) -destination 'platform=macOS' build -quiet
	@$(STOP_MAC)
	rm -rf /Applications/Tailmouse.app
	cp -R $(DERIVED)/Build/Products/Release/Tailmouse.app /Applications/
	open /Applications/Tailmouse.app

ios-sim: gen
	xcodebuild -project Tailmouse.xcodeproj -scheme Tailmouse -configuration Debug \
	  -derivedDataPath $(DERIVED) -destination 'generic/platform=iOS Simulator' build -quiet

# Simulator app paired with the running Mac app; optional screenshot path.
sim: ios-sim
	scripts/sim.sh $(SHOT)

# Unsigned IPA for SideStore, which re-signs it with your own Apple ID.
ipa: gen
	xcodebuild -project Tailmouse.xcodeproj -scheme Tailmouse -configuration Release \
	  -derivedDataPath $(DERIVED) -destination 'generic/platform=iOS' \
	  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= build -quiet
	rm -rf $(DERIVED)/ipa && mkdir -p $(DERIVED)/ipa/Payload
	cp -R $(DERIVED)/Build/Products/Release-iphoneos/Tailmouse.app $(DERIVED)/ipa/Payload/
	cd $(DERIVED)/ipa && zip -qry ../Tailmouse.ipa Payload
	@echo "$(IPA)"

# Developer ID signed, notarized zip of the Mac app. Setup: top of the script.
release:
	scripts/release.sh

clean:
	rm -rf $(DERIVED) Tailmouse.xcodeproj
