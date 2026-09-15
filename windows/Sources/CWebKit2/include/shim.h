#include <WebKit/WKBase.h>
#include <WebKit/WKType.h>
#include <WebKit/WKGeometry.h>
#include <WebKit/WKString.h>
#include <WebKit/WKURL.h>
#include <WebKit/WKPreferencesRef.h>
#include <WebKit/WKPreferencesRefPrivate.h>
#include <WebKit/WKContextConfigurationRef.h>
#include <WebKit/WKContext.h>
#include <WebKit/WKPageConfigurationRef.h>
#include <WebKit/WKPage.h>
#include <WebKit/WKView.h>
#include <WebKit/WKWebsiteDataStoreRef.h>
#include <WebKit/WKWebsiteDataStoreConfigurationRef.h>
#include <WebKit/WKPageNavigationClient.h>
#include <WebKit/WKErrorRef.h>
// The argument dictionary `WKPageCallAsyncJavaScript` takes, and the type its answer comes back as.
#include <WebKit/WKDictionary.h>
#include <WebKit/WKMutableDictionary.h>
// A page asking for the camera or the microphone: the UI client that hears it, the request, the
// origin it is filed under, and the array its device ids come back in.
#include <WebKit/WKPageUIClient.h>
#include <WebKit/WKUserMediaPermissionRequest.h>
#include <WebKit/WKSecurityOriginRef.h>
#include <WebKit/WKArray.h>
// `<input type=file>`: what the input asks for, and the listener the chosen files go back through.
#include <WebKit/WKOpenPanelParametersRef.h>
#include <WebKit/WKOpenPanelResultListener.h>
// A page opening a window: the action behind it and the request it carries — and the link under the
// pointer, which is how a middle or `Ctrl`-click is told from a plain one.
#include <WebKit/WKNavigationActionRef.h>
#include <WebKit/WKURLRequest.h>
#include <WebKit/WKHitTestResult.h>
// A response that is a file rather than a page, the decision that makes it one, and the download it
// becomes — which carries a client of its own for where it goes and how far it has got.
#include <WebKit/WKFramePolicyListener.h>
#include <WebKit/WKNavigationResponseRef.h>
#include <WebKit/WKURLResponse.h>
#include <WebKit/WKDownloadRef.h>
// The context menu: WebKit's own items, and the one six adds to them.
#include <WebKit/WKContextMenuItemTypes.h>
#include <WebKit/WKContextMenuItem.h>
