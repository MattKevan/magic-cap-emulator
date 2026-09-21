// Carbon.h — minimal iOS stub for DataRoverCore's osdlib_macosx.cpp TU.
//
// The TU's only Carbon usage is the Pasteboard clipboard path
// (PasteboardCreate/Synchronize/GetItemCount/... + kPasteboardClipboard,
// kUTType* UTI constants, OSStatus/ItemCount/PasteboardRef types).
// iOS has no Carbon framework and UIPasteboard lives in UIKit (a Swift-app
// concern, not the static lib). This stub declares just enough for the TU to
// compile; link-time symbols come from CoreFoundation/ApplicationServices
// where available, and any missing Pasteboard* symbol at final link is
// reported verbatim in the Task 1 error catalog (acceptable per plan).
#pragma once

#include <CoreFoundation/CoreFoundation.h>
#include <MacTypes.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OpaquePasteboardRef *PasteboardRef;
typedef UInt32 PasteboardItemID;

extern const CFStringRef kPasteboardClipboard;
extern const CFStringRef kUTTypeUTF16PlainText;
extern const CFStringRef kUTTypeUTF8PlainText;
extern const CFStringRef kUTTypePlainText;

OSStatus PasteboardCreate(CFStringRef name, PasteboardRef *pasteboard);
OSStatus PasteboardSynchronize(PasteboardRef pasteboard);
OSStatus PasteboardGetItemCount(PasteboardRef pasteboard, ItemCount *count);
OSStatus PasteboardGetItemIdentifier(PasteboardRef pasteboard, UInt32 index, PasteboardItemID *id);
OSStatus PasteboardCopyItemFlavors(PasteboardRef pasteboard, PasteboardItemID id, CFArrayRef *flavors);
OSStatus PasteboardCopyItemFlavorData(PasteboardRef pasteboard, PasteboardItemID id, CFStringRef flavor, CFDataRef *data);
OSStatus PasteboardClear(PasteboardRef pasteboard);
OSStatus PasteboardPutItemFlavor(PasteboardRef pasteboard, PasteboardItemID id, CFStringRef flavor, CFDataRef data, UInt32 flags);

enum { kPasteboardFlavorNoFlags = 0 };

static inline Boolean UTTypeConformsTo(CFStringRef inUTI, CFStringRef inConformsToUTI)
{
	return (inUTI != NULL && inConformsToUTI != NULL && CFEqual(inUTI, inConformsToUTI)) ? true : false;
}

#ifdef __cplusplus
}
#endif
