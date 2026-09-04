# gpodcheck

Cross-checks iPod databases written by iPod Pro Max against libgpod.

Build libgpod (macOS, Homebrew):

```
brew install glib gdk-pixbuf libplist sqlite autoconf automake libtool intltool gettext pkgconf
git clone https://github.com/gtkpod/libgpod.git && cd libgpod
sed -i '' 's/GTK_DOC_CHECK(1.0)/AM_CONDITIONAL([ENABLE_GTK_DOC],[false])/; /^bindings\//d; /^docs\//d; s/libplist >= 1.0/libplist-2.0 >= 2.0/' configure.ac
sed -i '' 's/^SUBDIRS=.*/SUBDIRS=src po m4/' Makefile.am && touch gtk-doc.make
PATH="/opt/homebrew/opt/gettext/bin:$PATH" PKG_CONFIG_PATH="/opt/homebrew/opt/sqlite/lib/pkgconfig:/opt/homebrew/lib/pkgconfig" \
  sh -c 'autoreconf -fiv && ./configure --without-libimobiledevice --disable-udev --without-hal --disable-pygobject --disable-libxml && make -C src'
```

Then compile and run:

```
cc -o gpodcheck gpodcheck.c -I../../../libgpod/src -I../../../libgpod $(pkg-config --cflags --libs glib-2.0 gobject-2.0 gdk-pixbuf-2.0) -L../../../libgpod/src/.libs -lgpod
DYLD_LIBRARY_PATH=../../../libgpod/src/.libs ./gpodcheck /Volumes/iPod
```

`gpodcheck --write <folder>` writes a small libgpod-authored database into a simulated iPod folder for testing the Swift reader.
