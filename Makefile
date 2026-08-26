PREFIX ?= /usr/local
BINDIR  = $(DESTDIR)$(PREFIX)/bin

all:
	@echo "targets: install uninstall test check"

install:
	install -d $(BINDIR)
	install -m 0755 hget hexec hwait hmirror $(BINDIR)

uninstall:
	rm -f $(BINDIR)/hget $(BINDIR)/hexec $(BINDIR)/hwait $(BINDIR)/hmirror

test:
	./test.sh

# Include the tests that reach the public internet.
check:
	HGET_NET=1 ./test.sh

.PHONY: all install uninstall test check
