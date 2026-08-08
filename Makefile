.PHONY: clean final

clean:
	@rm -rf .build 2>/dev/null || true

final: clean
	@pkill -x Rio 2>/dev/null || true
	@if test -f Config/Development.xcconfig; then \
		xcodebuild \
			-xcconfig Config/Development.xcconfig \
			-project Rio.xcodeproj \
			-scheme Rio \
			-configuration Debug \
			-destination 'platform=macOS' \
			-derivedDataPath .build/Iteration \
			SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
			build; \
	else \
	xcodebuild \
		-project Rio.xcodeproj \
		-scheme Rio \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath .build/Iteration \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		build; \
	fi
	@open -n .build/Iteration/Build/Products/Debug/Rio.app
