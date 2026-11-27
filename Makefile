.POSIX:
# yadatty — Chicken Scheme, POSIX make.
# https://shrub.industries/words/make.html
# csc -I is the import path, so pkg-config flags go through -C and -L.

PREFIX = /usr/local
DESTDIR =
PKG_CONFIG = pkg-config
CSC = csc
CSCFLAGS = -O2

GHOSTTY_CFLAGS != $(PKG_CONFIG) --cflags libghostty-vt
GHOSTTY_LIBS != $(PKG_CONFIG) --libs libghostty-vt
GUI_CFLAGS != $(PKG_CONFIG) --cflags glesv2 egl x11
GUI_LIBS != $(PKG_CONFIG) --libs glesv2 egl x11

all: yadatty

yadatty: yadatty.scm yadatty-native.c config.scm
	set -- $(CSCFLAGS) -C -I.; \
	for f in $(GHOSTTY_CFLAGS) $(GUI_CFLAGS); do set -- "$$@" -C "$$f"; done; \
	for f in $(GHOSTTY_LIBS) $(GUI_LIBS) -lutil; do set -- "$$@" -L "$$f"; done; \
	$(CSC) "$$@" -o yadatty yadatty.scm

clean:
	rm -f yadatty yadatty.o yadatty.c yadatty.link *.import.scm

install: yadatty
	mkdir -p $(DESTDIR)$(PREFIX)/bin
	cp yadatty $(DESTDIR)$(PREFIX)/bin/yadatty
	chmod 755 $(DESTDIR)$(PREFIX)/bin/yadatty

.PHONY: all clean install
