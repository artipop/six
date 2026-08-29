#pragma once
// One module for the whole toolkit: webkitgtk-6.0.pc already Requires gtk4, so pkg-config hands us
// GTK's headers and libraries transitively and the two never disagree about a GtkWidget.
#include <gtk/gtk.h>
#include <webkit/webkit.h>
