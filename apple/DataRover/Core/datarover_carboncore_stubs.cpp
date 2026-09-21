// CarbonCore stubs — link-time satisfiers for osdlib_macosx.cpp's clipboard
// path on iOS (no Carbon framework; UIPasteboard is a Swift-app concern).
//
// osd_get/set_clipboard_text are called from generic UI/keyboard code linked
// into the lib, so the TU must link. The functions behind these symbols live
// only in macOS Carbon (Pasteboard*) and LaunchServices (UTType* constants).
// This TU defines the constants (CFStringRefs) and no-op functions with the
// exact Carbon signatures: clipboard reads return empty (no data), writes
// report an error. If a future task wires UIPasteboard, replace these bodies
// — the declarations in ios_compat/Carbon/Carbon.h stay the same.
#include <CoreFoundation/CoreFoundation.h>
#include <MacTypes.h>

#include "Carbon/Carbon.h"

namespace {

CFStringRef make_const(CFStringRef s) { return s; }

}

const CFStringRef kPasteboardClipboard = CFSTR("com.apple.pasteboard.clipboard");
const CFStringRef kUTTypeUTF16PlainText = CFSTR("public.utf16-plain-text");
const CFStringRef kUTTypeUTF8PlainText = CFSTR("public.utf8-plain-text");
const CFStringRef kUTTypePlainText = CFSTR("public.plain-text");

OSStatus PasteboardCreate(CFStringRef name, PasteboardRef *pasteboard)
{
	(void)name;
	(void)pasteboard;
	return -1;
}

OSStatus PasteboardSynchronize(PasteboardRef pasteboard)
{
	(void)pasteboard;
	return 0;
}

OSStatus PasteboardGetItemCount(PasteboardRef pasteboard, ItemCount *count)
{
	(void)pasteboard;
	if (count)
		*count = 0;
	return 0;
}

OSStatus PasteboardGetItemIdentifier(PasteboardRef pasteboard, UInt32 index, PasteboardItemID *id)
{
	(void)pasteboard;
	(void)index;
	(void)id;
	return -1;
}

OSStatus PasteboardCopyItemFlavors(PasteboardRef pasteboard, PasteboardItemID id, CFArrayRef *flavors)
{
	(void)pasteboard;
	(void)id;
	(void)flavors;
	return -1;
}

OSStatus PasteboardCopyItemFlavorData(PasteboardRef pasteboard, PasteboardItemID id, CFStringRef flavor, CFDataRef *data)
{
	(void)pasteboard;
	(void)id;
	(void)flavor;
	(void)data;
	return -1;
}

OSStatus PasteboardClear(PasteboardRef pasteboard)
{
	(void)pasteboard;
	return -1;
}

OSStatus PasteboardPutItemFlavor(PasteboardRef pasteboard, PasteboardItemID id, CFStringRef flavor, CFDataRef data, UInt32 flags)
{
	(void)pasteboard;
	(void)id;
	(void)flavor;
	(void)data;
	(void)flags;
	return -1;
}
