.PHONY: final

final:
	@pkill -x Papagaio 2>/dev/null || true
	xcodebuild \
		-project Papagaio.xcodeproj \
		-scheme Papagaio \
		-configuration Debug \
		-destination 'platform=macOS' \
		-derivedDataPath .build/Iteration \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
		build
	@open -n .build/Iteration/Build/Products/Debug/Papagaio.app
