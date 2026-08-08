.PHONY: final

final:
	@pkill -x Papagaio 2>/dev/null || true
	@if test -f Config/Development.xcconfig; then \
		xcodebuild \
			-xcconfig Config/Development.xcconfig \
			-project Papagaio.xcodeproj \
			-scheme Papagaio \
			-configuration Debug \
			-destination 'platform=macOS' \
			-derivedDataPath .build/Iteration \
			SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
			build; \
	else \
	xcodebuild \
		-project Papagaio.xcodeproj \
		-scheme Papagaio \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath .build/Iteration \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		build; \
	fi
	@open -n .build/Iteration/Build/Products/Debug/Papagaio.app
