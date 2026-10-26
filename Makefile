.PHONY: all build test install uninstall preview
all: build
build:
	./scripts/build-dev.sh
test:
	./scripts/test.sh
install:
	./scripts/install-dev.sh
uninstall:
	./scripts/uninstall-dev.sh
preview:
	build/QingType.app/Contents/MacOS/QingType --preview
