PREFIX ?= /usr/local
BINDIR  = $(DESTDIR)$(PREFIX)/bin
SET    ?= bash

all:
	@echo "targets: install uninstall test check   (SET=bash|zsh|ash|powershell)"

install:
	install -d $(BINDIR)
	install -m 0755 $(SET)/hget $(SET)/hexec $(SET)/hwait $(SET)/hmirror $(BINDIR) 2>/dev/null || \
	install -m 0755 $(SET)/hget.ps1 $(SET)/hexec.ps1 $(SET)/hwait.ps1 $(SET)/hmirror.ps1 $(BINDIR)

uninstall:
	rm -f $(BINDIR)/hget $(BINDIR)/hexec $(BINDIR)/hwait $(BINDIR)/hmirror
	rm -f $(BINDIR)/hget.ps1 $(BINDIR)/hexec.ps1 $(BINDIR)/hwait.ps1 $(BINDIR)/hmirror.ps1

portable:
	@./portable/build

test:
	./test.sh

check:
	HGET_NET=1 ./test.sh

.PHONY: all install uninstall portable test check
