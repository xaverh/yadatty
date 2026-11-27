.POSIX:
# yadatty — one translation unit, POSIX make.
# https://shrub.industries/words/make.html

PREFIX = /usr/local
DESTDIR =
PKG_CONFIG = pkg-config
CC = c++
CFLAGS = -std=c++23 -Wall -Wextra -O2
CPPFLAGS =
LDFLAGS =

GHOSTTY_CFLAGS != $(PKG_CONFIG) --cflags libghostty-vt
GHOSTTY_LIBS != $(PKG_CONFIG) --libs libghostty-vt
GUI_CFLAGS != $(PKG_CONFIG) --cflags gl x11
GUI_LIBS != $(PKG_CONFIG) --libs gl x11

LDLIBS = $(GHOSTTY_LIBS) $(GUI_LIBS) -lutil

all: yadatty

yadatty: yadatty.o
	$(CC) $(LDFLAGS) -o yadatty yadatty.o $(LDLIBS)

yadatty.o: yadatty.cxx yadatty.hxx
	$(CC) $(CFLAGS) $(CPPFLAGS) $(GHOSTTY_CFLAGS) $(GUI_CFLAGS) -c yadatty.cxx

clean:
	rm -f yadatty yadatty.o

install: yadatty
	mkdir -p $(DESTDIR)$(PREFIX)/bin
	cp yadatty $(DESTDIR)$(PREFIX)/bin/yadatty
	chmod 755 $(DESTDIR)$(PREFIX)/bin/yadatty

.PHONY: all clean install
