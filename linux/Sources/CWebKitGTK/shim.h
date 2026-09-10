#pragma once
// WebKitGTK only: GTK itself comes from Adwaita's own `CAdw`, and webkit's headers pull in the same
// gtk headers, which Clang unifies. This is the arrangement `aparoksha/codeeditor` uses for
// GtkSourceView, and it is why a foreign widget can sit beside adwaita-swift's own.
#include <webkit/webkit.h>
// GLib's file-descriptor watch, which `MainQueueBridge` needs and which glib.h does not carry:
// it is the one piece of GLib that is Unix-only, so it lives in a header of its own.
#include <glib-unix.h>
