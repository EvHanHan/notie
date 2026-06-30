#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>

static NSString * const MarkdownFileBookmarkKey = @"MarkdownFileBookmark";
static NSString * const MarkdownFilePathKey = @"MarkdownFilePath";
static NSString * const SaveDestinationKey = @"SaveDestination";
static NSString * const SaveDestinationMarkdown = @"markdown";
static NSString * const SaveDestinationAppleNotes = @"appleNotes";
static unichar const ImagePreviewPlaceholderCharacter = 0xFFFC;

static NSSet<NSString *> *NotieImageFileExtensions(void) {
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"tif", @"tiff", @"bmp", @"webp"]];
    });
    return extensions;
}

static NSArray<NSPasteboardType> *NotiePasteboardImageTypes(void) {
    static NSArray<NSPasteboardType> *types;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSPasteboardType> *imageTypes = [NSMutableArray arrayWithArray:NSImage.imageTypes];
        [imageTypes addObjectsFromArray:@[NSPasteboardTypePNG, NSPasteboardTypeTIFF, @"public.jpeg", @"public.heic", @"public.webp", @"com.compuserve.gif"]];
        types = [imageTypes copy];
    });
    return types;
}

@interface CaptureTextView : NSTextView
@property (nonatomic, copy) void (^commandReturnHandler)(void);
@property (nonatomic, copy) void (^escapeHandler)(void);
@property (nonatomic, copy) void (^chooseMarkdownFileHandler)(void);
@property (nonatomic, copy) BOOL (^pasteboardImageHandler)(NSPasteboard *pasteboard);
@end

@implementation CaptureTextView
- (void)keyDown:(NSEvent *)event {
    BOOL commandDown = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    BOOL commandOnly = (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagCommand;
    NSString *characters = event.charactersIgnoringModifiers.lowercaseString ?: @"";
    if (event.keyCode == 36 && commandDown) {
        if (self.commandReturnHandler) self.commandReturnHandler();
        return;
    }
    if (commandOnly && [characters isEqualToString:@"x"]) {
        [self cut:nil];
        return;
    }
    if (commandOnly && [characters isEqualToString:@"c"]) {
        [self copy:nil];
        return;
    }
    if (commandOnly && [characters isEqualToString:@"a"]) {
        [self selectAll:nil];
        return;
    }
    if (event.keyCode == 9 && commandDown) {
        if (self.pasteboardImageHandler && self.pasteboardImageHandler(NSPasteboard.generalPasteboard)) return;
    }
    if (event.keyCode == 31 && commandDown) {
        if (self.chooseMarkdownFileHandler) self.chooseMarkdownFileHandler();
        return;
    }
    if (event.keyCode == 53) {
        if (self.escapeHandler) self.escapeHandler();
        return;
    }
    [super keyDown:event];
}

- (void)paste:(id)sender {
    if (self.pasteboardImageHandler && self.pasteboardImageHandler(NSPasteboard.generalPasteboard)) return;
    NSString *plainText = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if (plainText.length > 0) {
        [self insertText:plainText replacementRange:self.selectedRange];
        return;
    }
    [super paste:sender];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    return [self pasteboardLooksLikeImage:sender.draggingPasteboard] ? NSDragOperationCopy : [super draggingEntered:sender];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    if (self.pasteboardImageHandler && self.pasteboardImageHandler(sender.draggingPasteboard)) return YES;
    return [super performDragOperation:sender];
}

- (BOOL)pasteboardLooksLikeImage:(NSPasteboard *)pasteboard {
    for (NSPasteboardType type in NotiePasteboardImageTypes()) {
        if ([[pasteboard types] containsObject:type]) return YES;
    }
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    for (NSURL *url in urls) {
        if ([NotieImageFileExtensions() containsObject:url.pathExtension.lowercaseString]) return YES;
    }
    return NO;
}
@end

@interface ClickableTextField : NSTextField
@property (nonatomic, copy) void (^clickHandler)(void);
@end

@implementation ClickableTextField
- (void)mouseDown:(NSEvent *)event {
    if (self.clickHandler) {
        self.clickHandler();
        return;
    }
    [super mouseDown:event];
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTextViewDelegate>
@property NSStatusItem *statusItem;
@property NSWindow *window;
@property CaptureTextView *textView;
@property NSPopUpButton *destinationPopUp;
@property NSMenuItem *markdownTargetMenuItem;
@property NSView *bottomBar;
@property NSMutableArray<NSDictionary *> *pendingImages;
@property NSMapTable<NSTextAttachment *, NSString *> *attachmentImageIDs;
@property EventHotKeyRef hotKeyRef;
@property EventHandlerRef handlerRef;
- (void)showCaptureWindow:(id)sender;
@end

static OSStatus HotKeyHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
    AppDelegate *delegate = (__bridge AppDelegate *)userData;
    dispatch_async(dispatch_get_main_queue(), ^{ [delegate showCaptureWindow:nil]; });
    return noErr;
}

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.pendingImages = [NSMutableArray array];
    self.attachmentImageIDs = [NSMapTable weakToStrongObjectsMapTable];
    [self buildMainMenu];
    [self buildStatusItem];
    [self buildWindow];
    [self registerHotKey];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (_hotKeyRef) UnregisterEventHotKey(_hotKeyRef);
    if (_handlerRef) RemoveEventHandler(_handlerRef);
}

- (void)buildMainMenu {
    NSMenu *mainMenu = [NSMenu new];

    NSMenuItem *appMenuItem = [NSMenuItem new];
    [mainMenu addItem:appMenuItem];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Notie"];
    appMenuItem.submenu = appMenu;
    [appMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Quit Notie" action:@selector(quit:) keyEquivalent:@"q"]];

    NSMenuItem *editMenuItem = [NSMenuItem new];
    [mainMenu addItem:editMenuItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    editMenuItem.submenu = editMenu;
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"]];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"]];
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"]];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"]];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"]];
    [editMenu addItem:[[NSMenuItem alloc] initWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"]];

    NSApp.mainMenu = mainMenu;
}

- (void)buildStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *button = self.statusItem.button;
    button.toolTip = @"Notie";
    button.title = @"";
    button.imagePosition = NSImageOnly;

    NSImage *menuBarImage = [NSImage imageNamed:@"MenuBarDuckTemplate"];
    if (!menuBarImage) {
        NSString *menuBarIconPath = [NSBundle.mainBundle pathForResource:@"MenuBarDuckTemplate" ofType:@"png"];
        if (menuBarIconPath.length > 0) {
            menuBarImage = [[NSImage alloc] initWithContentsOfFile:menuBarIconPath];
        }
    }
    if (menuBarImage) {
        menuBarImage.template = YES;
        menuBarImage.size = NSMakeSize(18.0, 18.0);
        button.image = menuBarImage;
    } else {
        button.title = @"✎";
    }

    NSMenu *menu = [NSMenu new];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"New Note" action:@selector(showCaptureWindow:) keyEquivalent:@"k"]];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Save Note" action:@selector(saveNote:) keyEquivalent:@"\r"]];
    self.markdownTargetMenuItem = [[NSMenuItem alloc] initWithTitle:@"Default Target File: None" action:@selector(chooseMarkdownFile:) keyEquivalent:@"o"];
    [menu addItem:self.markdownTargetMenuItem];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"]];
    self.statusItem.menu = menu;
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 500, 168);
    self.window = [[NSWindow alloc] initWithContentRect:frame styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Notie";
    self.window.level = NSFloatingWindowLevel;
    self.window.releasedWhenClosed = NO;
    self.window.backgroundColor = NSColor.windowBackgroundColor;
    [self positionCaptureWindowBottomRight];

    NSView *content = [[NSView alloc] initWithFrame:frame];
    content.wantsLayer = YES;
    content.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
    self.window.contentView = content;

    self.bottomBar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width, 52)];
    self.bottomBar.wantsLayer = YES;
    self.bottomBar.layer.backgroundColor = [NSColor colorWithWhite:0.96 alpha:1.0].CGColor;
    [content addSubview:self.bottomBar];

    NSBox *divider = [[NSBox alloc] initWithFrame:NSMakeRect(0, 52, frame.size.width, 1)];
    divider.boxType = NSBoxSeparator;
    [content addSubview:divider];

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 53, frame.size.width, frame.size.height - 53)];
    scrollView.borderType = NSNoBorder;
    scrollView.drawsBackground = YES;
    scrollView.backgroundColor = NSColor.textBackgroundColor;
    scrollView.hasVerticalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.scrollerStyle = NSScrollerStyleOverlay;
    self.textView = [[CaptureTextView alloc] initWithFrame:scrollView.bounds];
    NSFont *spotlightLikeFont = [NSFont systemFontOfSize:22 weight:NSFontWeightRegular];
    self.textView.font = spotlightLikeFont;
    self.textView.typingAttributes = @{NSFontAttributeName: spotlightLikeFont, NSForegroundColorAttributeName: NSColor.labelColor};
    self.textView.textColor = NSColor.labelColor;
    self.textView.backgroundColor = NSColor.textBackgroundColor;
    self.textView.textContainerInset = NSMakeSize(14, 12);
    self.textView.richText = YES;
    self.textView.importsGraphics = NO;
    self.textView.allowsUndo = YES;
    self.textView.verticallyResizable = YES;
    self.textView.horizontallyResizable = NO;
    self.textView.autoresizingMask = NSViewWidthSizable;
    self.textView.delegate = self;
    self.textView.textContainer.containerSize = NSMakeSize(scrollView.contentSize.width, CGFLOAT_MAX);
    self.textView.textContainer.widthTracksTextView = YES;
    __weak AppDelegate *weakSelf = self;
    self.textView.commandReturnHandler = ^{ [weakSelf saveNote:nil]; };
    self.textView.escapeHandler = ^{ [weakSelf.window close]; };
    self.textView.chooseMarkdownFileHandler = ^{ [weakSelf chooseMarkdownFile:nil]; };
    self.textView.pasteboardImageHandler = ^BOOL(NSPasteboard *pasteboard) { return [weakSelf addPendingImagesFromPasteboard:pasteboard]; };
    [self.textView registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSPasteboardTypePNG, NSPasteboardTypeTIFF]];
    scrollView.documentView = self.textView;
    [content addSubview:scrollView];

    self.destinationPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(12, 10, 146, 32) pullsDown:NO];
    [self.destinationPopUp addItemWithTitle:@"Write to File"];
    [self.destinationPopUp addItemWithTitle:@"Apple Notes"];
    [self.destinationPopUp itemAtIndex:0].representedObject = SaveDestinationMarkdown;
    [self.destinationPopUp itemAtIndex:1].representedObject = SaveDestinationAppleNotes;
    self.destinationPopUp.target = self;
    self.destinationPopUp.action = @selector(destinationChanged:);
    [self.bottomBar addSubview:self.destinationPopUp];

    NSButton *saveButton = [NSButton buttonWithTitle:@"Save  ⌘ ↩" target:self action:@selector(saveNote:)];
    saveButton.keyEquivalent = @"\r";
    saveButton.frame = NSMakeRect(328, 10, 160, 32);
    [self.bottomBar addSubview:saveButton];
    [self updateTargetControls];
}

- (void)registerHotKey {
    EventHotKeyID hotKeyID;
    hotKeyID.signature = 'NOTI';
    hotKeyID.id = 1;
    EventTypeSpec eventType = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallEventHandler(GetApplicationEventTarget(), HotKeyHandler, 1, &eventType, (__bridge void *)self, &_handlerRef);
    RegisterEventHotKey(kVK_ANSI_K, cmdKey, hotKeyID, GetApplicationEventTarget(), 0, &_hotKeyRef);
}

- (void)showCaptureWindow:(id)sender {
    [NSApp activateIgnoringOtherApps:YES];
    [self positionCaptureWindowBottomRight];
    [self.window makeKeyAndOrderFront:nil];
    self.textView.string = @"";
    [self.pendingImages removeAllObjects];
    [self.attachmentImageIDs removeAllObjects];
    [self updateTargetControls];
    [self.window makeFirstResponder:self.textView];
}

- (void)positionCaptureWindowBottomRight {
    NSScreen *screen = self.window.screen ?: NSScreen.mainScreen;
    NSRect visibleFrame = screen.visibleFrame;
    NSRect frame = self.window.frame;
    CGFloat margin = 24.0;
    frame.origin.x = NSMaxX(visibleFrame) - frame.size.width - margin;
    frame.origin.y = NSMinY(visibleFrame) + margin;
    [self.window setFrame:frame display:YES];
}

- (void)destinationChanged:(id)sender {
    NSString *destination = self.destinationPopUp.selectedItem.representedObject ?: SaveDestinationMarkdown;
    [NSUserDefaults.standardUserDefaults setObject:destination forKey:SaveDestinationKey];
    [self updateTargetControls];
    [self refocusCaptureWindow];
}

- (BOOL)addPendingImagesFromPasteboard:(NSPasteboard *)pasteboard {
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSUInteger addedCount = 0;
    for (NSURL *url in urls) {
        if (![NotieImageFileExtensions() containsObject:url.pathExtension.lowercaseString]) {
            continue;
        }
        NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
        if (!image) {
            continue;
        }
        NSString *imageID = NSUUID.UUID.UUIDString;
        NSString *name = url.lastPathComponent ?: @"image";
        [self.pendingImages addObject:@{@"url": url, @"name": name, @"id": imageID}];
        [self insertImagePreview:image name:name imageID:imageID];
        addedCount++;
    }

    if (addedCount == 0) {
        NSImage *image = [self imageFromPasteboard:pasteboard];
        if (image) {
            NSString *name = [NSString stringWithFormat:@"screenshot-%@.png", [self timestampString]];
            NSString *imageID = NSUUID.UUID.UUIDString;
            [self.pendingImages addObject:@{@"image": image, @"name": name, @"id": imageID}];
            [self insertImagePreview:image name:name imageID:imageID];
            addedCount++;
        }
    }

    if (addedCount == 0) {
        return NO;
    }
    [self updateTargetControls];
    [self refocusCaptureWindow];
    return YES;
}

- (NSImage *)imageFromPasteboard:(NSPasteboard *)pasteboard {
    NSImage *image = [[NSImage alloc] initWithPasteboard:pasteboard];
    if (image) {
        return image;
    }

    for (NSPasteboardItem *item in pasteboard.pasteboardItems) {
        for (NSPasteboardType type in NotiePasteboardImageTypes()) {
            NSData *data = [item dataForType:type];
            if (data.length == 0) continue;
            image = [[NSImage alloc] initWithData:data];
            if (image) {
                return image;
            }
        }
    }
    return nil;
}

- (void)insertImagePreview:(NSImage *)image name:(NSString *)name imageID:(NSString *)imageID {
    NSMutableAttributedString *insertion = [[NSMutableAttributedString alloc] initWithString:@"\n" attributes:self.textView.typingAttributes];
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = [self previewImageForImage:image ?: [self placeholderImageWithName:name]];
    [self.attachmentImageIDs setObject:imageID forKey:attachment];
    [insertion appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    [insertion appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:self.textView.typingAttributes]];
    NSRange replacementRange = self.textView.selectedRange;
    NSDictionary *typingAttributes = self.textView.typingAttributes;
    [self.textView.textStorage replaceCharactersInRange:replacementRange withAttributedString:insertion];
    self.textView.selectedRange = NSMakeRange(replacementRange.location + insertion.length, 0);
    self.textView.typingAttributes = typingAttributes;
}

- (NSImage *)placeholderImageWithName:(NSString *)name {
    NSSize size = NSMakeSize(240, 48);
    NSImage *image = [[NSImage alloc] initWithSize:size];
    [image lockFocus];
    [[NSColor colorWithWhite:0.92 alpha:1.0] setFill];
    NSRectFill(NSMakeRect(0, 0, size.width, size.height));
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:13], NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    [[NSString stringWithFormat:@"Image: %@", name] drawInRect:NSMakeRect(12, 15, size.width - 24, 18) withAttributes:attributes];
    [image unlockFocus];
    return image;
}

- (NSImage *)previewImageForImage:(NSImage *)image {
    CGFloat maximumWidth = 360.0;
    CGFloat maximumHeight = 180.0;
    NSSize imageSize = image.size;
    if (imageSize.width <= 0 || imageSize.height <= 0) return image;
    CGFloat scale = MIN(1.0, MIN(maximumWidth / imageSize.width, maximumHeight / imageSize.height));
    NSSize previewSize = NSMakeSize(floor(imageSize.width * scale), floor(imageSize.height * scale));
    NSImage *preview = [[NSImage alloc] initWithSize:previewSize];
    [preview lockFocus];
    [image drawInRect:NSMakeRect(0, 0, previewSize.width, previewSize.height) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
    [preview unlockFocus];
    return preview;
}

- (void)chooseMarkdownFile:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Choose Markdown File";
    panel.prompt = @"Use This File";
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.canCreateDirectories = YES;
    panel.allowedFileTypes = @[@"md", @"markdown", @"txt"];

    NSURL *currentURL = [self currentMarkdownFileURL];
    if (currentURL) {
        panel.directoryURL = currentURL;
        panel.nameFieldStringValue = currentURL.lastPathComponent ?: @"";
    }
    [self positionPanelNearMenuBarWhenShown:panel];

    NSInteger response = [panel runModal];
    if (response != NSModalResponseOK) return;

    NSURL *fileURL = panel.URL;
    NSError *error = nil;
    NSData *bookmark = [fileURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
    if (!bookmark) {
        [self showErrorWithTitle:@"Couldn’t save Markdown file" message:error.localizedDescription ?: @"The selected file could not be remembered."];
        return;
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:bookmark forKey:MarkdownFileBookmarkKey];
    [defaults setObject:fileURL.path forKey:MarkdownFilePathKey];
    [self updateTargetControls];
}

- (void)positionPanelNearMenuBarWhenShown:(NSPanel *)panel {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSScreen *screen = NSScreen.mainScreen;
        NSRect visibleFrame = screen.visibleFrame;
        NSRect panelFrame = panel.frame;
        CGFloat margin = 24.0;
        CGFloat statusItemCenterX = NSMidX(self.statusItem.button.window.frame);
        panelFrame.origin.x = MIN(MAX(NSMinX(visibleFrame) + margin, statusItemCenterX - (panelFrame.size.width / 2.0)), NSMaxX(visibleFrame) - panelFrame.size.width - margin);
        panelFrame.origin.y = NSMaxY(visibleFrame) - panelFrame.size.height - margin;
        [panel setFrame:panelFrame display:YES animate:NO];
    });
}

- (void)saveNote:(id)sender {
    NSString *body = [[self plainBodyText] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSDictionary *> *visibleImages = [self visiblePendingImages];
    if (body.length == 0 && visibleImages.count == 0) {
        NSBeep();
        return;
    }

    NSError *error = nil;
    NSString *destination = [self selectedSaveDestination];
    BOOL saved = [destination isEqualToString:SaveDestinationAppleNotes] ? [self createAppleNoteWithBody:body images:visibleImages error:&error] : [self appendEntryWithBody:body images:visibleImages error:&error];
    if (saved) {
        [self.window close];
        [self.pendingImages removeAllObjects];
        NSUserNotification *notification = [NSUserNotification new];
        notification.title = [destination isEqualToString:SaveDestinationAppleNotes] ? @"Saved to Apple Notes" : @"Saved to Markdown";
        notification.informativeText = [destination isEqualToString:SaveDestinationAppleNotes] ? [self appleNoteTitleForBody:body images:visibleImages] : [self targetDescription];
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
    } else {
        NSString *title = [destination isEqualToString:SaveDestinationAppleNotes] ? @"Couldn’t save to Apple Notes" : @"Couldn’t save to Markdown";
        [self showErrorWithTitle:title message:error.localizedDescription ?: @"Unknown error."];
    }
}

- (NSString *)plainBodyText {
    NSMutableString *body = [self.textView.string mutableCopy] ?: [NSMutableString string];
    NSString *placeholder = [NSString stringWithCharacters:&ImagePreviewPlaceholderCharacter length:1];
    [body replaceOccurrencesOfString:placeholder withString:@"" options:0 range:NSMakeRange(0, body.length)];
    return body;
}

- (NSArray<NSDictionary *> *)visiblePendingImages {
    NSSet<NSString *> *visibleImageIDs = [self visibleImageIDs];
    NSMutableArray<NSDictionary *> *visibleImages = [NSMutableArray array];
    for (NSDictionary *imageInfo in self.pendingImages) {
        NSString *imageID = imageInfo[@"id"];
        if (imageID && [visibleImageIDs containsObject:imageID]) [visibleImages addObject:imageInfo];
    }
    return visibleImages;
}

- (NSSet<NSString *> *)visibleImageIDs {
    NSMutableSet<NSString *> *imageIDs = [NSMutableSet set];
    NSAttributedString *text = self.textView.textStorage;
    [text enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, text.length) options:0 usingBlock:^(id value, NSRange range, BOOL *stop) {
        if (![value isKindOfClass:NSTextAttachment.class]) return;
        NSString *imageID = [self.attachmentImageIDs objectForKey:value];
        if (imageID) [imageIDs addObject:imageID];
    }];
    return imageIDs;
}

- (NSUInteger)visibleImageCount {
    return [self visiblePendingImages].count;
}

- (void)textDidChange:(NSNotification *)notification {
    [self updateTargetControls];
}

- (void)refocusCaptureWindow {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp activateIgnoringOtherApps:YES];
        [self.window makeKeyAndOrderFront:nil];
        [self.window makeFirstResponder:self.textView];
    });
}

- (void)updateTargetControls {
    NSString *path = [NSUserDefaults.standardUserDefaults stringForKey:MarkdownFilePathKey];
    NSString *destination = [self selectedSaveDestination];
    BOOL savesToAppleNotes = [destination isEqualToString:SaveDestinationAppleNotes];
    [self.destinationPopUp selectItemWithTitle:(savesToAppleNotes ? @"Apple Notes" : @"Write to File")];
    NSString *targetTitle = path.length > 0 ? [NSString stringWithFormat:@"Default Target File: %@", path.lastPathComponent] : @"Default Target File: None";
    self.markdownTargetMenuItem.title = targetTitle;
    self.markdownTargetMenuItem.toolTip = path.length > 0 ? path : @"Click to choose the default Markdown file.";
}

- (NSString *)selectedSaveDestination {
    NSString *destination = [NSUserDefaults.standardUserDefaults stringForKey:SaveDestinationKey];
    if ([destination isEqualToString:SaveDestinationAppleNotes]) return SaveDestinationAppleNotes;
    return SaveDestinationMarkdown;
}

- (BOOL)createAppleNoteWithBody:(NSString *)body images:(NSArray<NSDictionary *> *)images error:(NSError **)outError {
    NSString *title = [self appleNoteTitleForBody:body images:images];
    NSString *html = [self appleNoteHTMLForBody:body];
    BOOL hasBodyText = [[body stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] length] > 0;
    NSString *scriptTitle = hasBodyText ? nil : title;
    NSError *attachmentError = nil;
    NSArray<NSURL *> *attachmentURLs = [self appleNoteAttachmentURLsForImages:images error:&attachmentError];
    if (!attachmentURLs && images.count > 0) {
        if (outError) *outError = attachmentError;
        return NO;
    }

    NSString *scriptSource = [self appleNoteScriptSourceWithTitle:scriptTitle html:html attachmentURLs:attachmentURLs includeDefaultFolder:YES];
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:scriptSource];
    NSDictionary *errorInfo = nil;
    [script executeAndReturnError:&errorInfo];
    if (!errorInfo || [self appleScriptErrorLooksLikeCompletedSave:errorInfo]) {
        [self removeAppleNoteTemporaryAttachments:attachmentURLs];
        return YES;
    }

    NSInteger errorNumber = [errorInfo[NSAppleScriptErrorNumber] integerValue];
    if (errorNumber != -1728 && errorNumber != -10004) {
        [self removeAppleNoteTemporaryAttachments:attachmentURLs];
        if (outError) *outError = [self errorFromAppleScriptErrorInfo:errorInfo fallback:@"Apple Notes could not create the note."];
        return NO;
    }

    NSString *fallbackSource = [self appleNoteScriptSourceWithTitle:scriptTitle html:html attachmentURLs:attachmentURLs includeDefaultFolder:NO];
    NSAppleScript *fallbackScript = [[NSAppleScript alloc] initWithSource:fallbackSource];
    NSDictionary *fallbackErrorInfo = nil;
    [fallbackScript executeAndReturnError:&fallbackErrorInfo];
    [self removeAppleNoteTemporaryAttachments:attachmentURLs];
    if (!fallbackErrorInfo || [self appleScriptErrorLooksLikeCompletedSave:fallbackErrorInfo]) return YES;
    if (outError) *outError = [self errorFromAppleScriptErrorInfo:fallbackErrorInfo fallback:@"Apple Notes could not create the note."];
    return NO;
}

- (BOOL)appleScriptErrorLooksLikeCompletedSave:(NSDictionary *)errorInfo {
    NSInteger errorNumber = [errorInfo[NSAppleScriptErrorNumber] integerValue];
    if (errorNumber == -1712) return YES;
    NSString *message = [errorInfo[NSAppleScriptErrorMessage] lowercaseString] ?: @"";
    return [message containsString:@"user canceled"] || [message containsString:@"handler failed"];
}

- (NSError *)errorFromAppleScriptErrorInfo:(NSDictionary *)errorInfo fallback:(NSString *)fallback {
    NSString *message = errorInfo[NSAppleScriptErrorMessage] ?: fallback;
    NSInteger code = [errorInfo[NSAppleScriptErrorNumber] integerValue];
    return [NSError errorWithDomain:@"Notie" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (NSString *)appleNoteTitleForBody:(NSString *)body images:(NSArray<NSDictionary *> *)images {
    NSArray<NSString *> *lines = [body componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    for (NSString *line in lines) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmedLine.length > 0) return [self truncatedString:trimmedLine maximumLength:80];
    }
    if (images.count == 1) return @"Notie image";
    if (images.count > 1) return [NSString stringWithFormat:@"Notie images (%lu)", (unsigned long)images.count];
    return @"Notie note";
}

- (NSString *)appleNoteHTMLForBody:(NSString *)body {
    NSMutableString *html = [NSMutableString stringWithString:@"<html><body>"];
    NSString *trimmedBody = [body stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmedBody.length > 0) {
        NSArray<NSString *> *paragraphs = [trimmedBody componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
        for (NSString *paragraph in paragraphs) {
            NSString *trimmedParagraph = [paragraph stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (trimmedParagraph.length == 0) continue;
            [html appendFormat:@"<p>%@</p>", [self htmlEscapedString:trimmedParagraph]];
        }
    }
    [html appendString:@"</body></html>"];
    return html;
}

- (NSString *)appleNoteScriptSourceWithTitle:(NSString *)title html:(NSString *)html attachmentURLs:(NSArray<NSURL *> *)attachmentURLs includeDefaultFolder:(BOOL)includeDefaultFolder {
    NSMutableString *script = [NSMutableString stringWithString:@"tell application \"Notes\"\nwith timeout of 120 seconds\n"];
    NSString *target = includeDefaultFolder ? @" at folder \"Notes\" of default account" : @"";
    if (title.length > 0) {
        [script appendFormat:@"set createdNote to make new note%@ with properties {name:%@, body:%@}\n", target, [self appleScriptLiteralForString:title], [self appleScriptLiteralForString:html]];
    } else {
        [script appendFormat:@"set createdNote to make new note%@ with properties {body:%@}\n", target, [self appleScriptLiteralForString:html]];
    }
    if (attachmentURLs.count > 0) {
        [script appendString:@"tell createdNote\n"];
        for (NSURL *attachmentURL in attachmentURLs) {
            [script appendFormat:@"make new attachment at end of attachments with data (POSIX file %@)\n", [self appleScriptLiteralForString:attachmentURL.path ?: @""]];
        }
        [script appendString:@"end tell\n"];
    }
    [script appendString:@"end timeout\nend tell"];
    return script;
}

- (NSArray<NSURL *> *)appleNoteAttachmentURLsForImages:(NSArray<NSDictionary *> *)images error:(NSError **)outError {
    if (images.count == 0) return @[];

    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *directoryName = [NSString stringWithFormat:@"notie-notes-%@", NSUUID.UUID.UUIDString];
    NSURL *directoryURL = [self appleNoteAttachmentStagingRootURL];
    directoryURL = [directoryURL URLByAppendingPathComponent:directoryName isDirectory:YES];
    if (![fileManager createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:outError]) {
        return nil;
    }

    NSMutableArray<NSURL *> *attachmentURLs = [NSMutableArray arrayWithCapacity:images.count];
    for (NSDictionary *imageInfo in images) {
        NSURL *savedURL = [self savePendingImage:imageInfo toDirectory:directoryURL fileManager:fileManager error:outError];
        if (!savedURL) {
            [self removeAppleNoteTemporaryAttachments:attachmentURLs];
            [fileManager removeItemAtURL:directoryURL error:nil];
            return nil;
        }
        [attachmentURLs addObject:savedURL];
    }
    return attachmentURLs;
}

- (NSURL *)appleNoteAttachmentStagingRootURL {
    NSArray<NSURL *> *urls = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask];
    NSURL *cachesURL = urls.firstObject ?: [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    return [[cachesURL URLByAppendingPathComponent:@"Notie" isDirectory:YES] URLByAppendingPathComponent:@"AppleNotesAttachments" isDirectory:YES];
}

- (void)removeAppleNoteTemporaryAttachments:(NSArray<NSURL *> *)attachmentURLs {
    if (attachmentURLs.count == 0) return;
    NSURL *directoryURL = attachmentURLs.firstObject.URLByDeletingLastPathComponent;
    [NSFileManager.defaultManager removeItemAtURL:directoryURL error:nil];
}

- (NSString *)appleNotesDescription {
    NSUInteger imageCount = [self visibleImageCount];
    if (imageCount == 1) return @"New Apple note • 1 image name";
    if (imageCount > 1) return [NSString stringWithFormat:@"New Apple note • %lu image names", (unsigned long)imageCount];
    return @"New Apple note";
}

- (NSString *)truncatedString:(NSString *)string maximumLength:(NSUInteger)maximumLength {
    if (string.length <= maximumLength) return string;
    return [[string substringToIndex:maximumLength - 1] stringByAppendingString:@"…"];
}

- (NSString *)htmlEscapedString:(NSString *)string {
    NSMutableString *escaped = [string mutableCopy] ?: [NSMutableString string];
    [escaped replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, escaped.length)];
    [escaped replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, escaped.length)];
    return escaped;
}

- (NSString *)appleScriptLiteralForString:(NSString *)string {
    NSMutableString *literal = [NSMutableString stringWithString:@"\""];
    NSArray<NSString *> *parts = [string componentsSeparatedByString:@"\""];
    for (NSUInteger index = 0; index < parts.count; index++) {
        NSString *part = parts[index];
        NSMutableString *escapedPart = [part mutableCopy] ?: [NSMutableString string];
        [escapedPart replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, escapedPart.length)];
        [literal appendString:escapedPart];
        if (index + 1 < parts.count) [literal appendString:@"\\\""];
    }
    [literal appendString:@"\""];
    return literal;
}

- (BOOL)appendEntryWithBody:(NSString *)body images:(NSArray<NSDictionary *> *)images error:(NSError **)outError {
    NSURL *fileURL = [self markdownFileURLWithError:outError];
    if (!fileURL) return NO;

    BOOL hasSecurityScope = [fileURL startAccessingSecurityScopedResource];
    BOOL isDirectory = NO;
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager fileExistsAtPath:fileURL.path isDirectory:&isDirectory]) {
        [fileManager createFileAtPath:fileURL.path contents:nil attributes:nil];
    }
    if (isDirectory) {
        if (hasSecurityScope) [fileURL stopAccessingSecurityScopedResource];
        if (outError) *outError = [NSError errorWithDomain:@"Notie" code:3 userInfo:@{NSLocalizedDescriptionKey: @"The selected Markdown target is a folder, not a file."}];
        return NO;
    }

    NSMutableArray<NSString *> *imagePaths = [NSMutableArray array];
    if (images.count > 0) {
        NSURL *assetsDirectory = [self assetsDirectoryForMarkdownURL:fileURL];
        if (![fileManager fileExistsAtPath:assetsDirectory.path]) {
            if (![fileManager createDirectoryAtURL:assetsDirectory withIntermediateDirectories:YES attributes:nil error:outError]) {
                if (hasSecurityScope) [fileURL stopAccessingSecurityScopedResource];
                return NO;
            }
        }
        for (NSDictionary *imageInfo in images) {
            NSURL *savedURL = [self savePendingImage:imageInfo toDirectory:assetsDirectory fileManager:fileManager error:outError];
            if (!savedURL) {
                if (hasSecurityScope) [fileURL stopAccessingSecurityScopedResource];
                return NO;
            }
            [imagePaths addObject:[self markdownPathForImageURL:savedURL relativeToMarkdownURL:fileURL]];
        }
    }

    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingToURL:fileURL error:outError];
    if (!fileHandle) {
        if (hasSecurityScope) [fileURL stopAccessingSecurityScopedResource];
        return NO;
    }

    @try {
        [fileHandle seekToEndOfFile];
        unsigned long long length = fileHandle.offsetInFile;
        NSString *entry = [self markdownBulletForBody:body imagePaths:imagePaths needsLeadingNewline:(length > 0)];
        NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
        [fileHandle writeData:data];
        [fileHandle closeFile];
    } @catch (NSException *exception) {
        [fileHandle closeFile];
        if (hasSecurityScope) [fileURL stopAccessingSecurityScopedResource];
        if (outError) *outError = [NSError errorWithDomain:@"Notie" code:4 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"The Markdown file could not be written."}];
        return NO;
    }

    if (hasSecurityScope) [fileURL stopAccessingSecurityScopedResource];
    return YES;
}

- (NSURL *)assetsDirectoryForMarkdownURL:(NSURL *)markdownURL {
    NSString *baseName = markdownURL.URLByDeletingPathExtension.lastPathComponent ?: @"notie";
    return [markdownURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-assets", baseName] isDirectory:YES];
}

- (NSURL *)savePendingImage:(NSDictionary *)imageInfo toDirectory:(NSURL *)directoryURL fileManager:(NSFileManager *)fileManager error:(NSError **)outError {
    NSString *preferredName = imageInfo[@"name"] ?: @"image.png";
    NSURL *destinationURL = [self uniqueURLInDirectory:directoryURL preferredFilename:preferredName fileManager:fileManager];

    NSURL *sourceURL = imageInfo[@"url"];
    if (sourceURL) {
        if ([fileManager copyItemAtURL:sourceURL toURL:destinationURL error:outError]) return destinationURL;
        return nil;
    }

    NSImage *image = imageInfo[@"image"];
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) {
        if (outError) *outError = [NSError errorWithDomain:@"Notie" code:5 userInfo:@{NSLocalizedDescriptionKey: @"The pasted image could not be converted to PNG."}];
        return nil;
    }
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
    NSData *pngData = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (![pngData writeToURL:destinationURL options:NSDataWritingAtomic error:outError]) return nil;
    return destinationURL;
}

- (NSURL *)uniqueURLInDirectory:(NSURL *)directoryURL preferredFilename:(NSString *)preferredName fileManager:(NSFileManager *)fileManager {
    NSString *baseName = preferredName.stringByDeletingPathExtension.length > 0 ? preferredName.stringByDeletingPathExtension : @"image";
    NSString *extension = preferredName.pathExtension.length > 0 ? preferredName.pathExtension : @"png";
    NSURL *candidate = [directoryURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", baseName, extension]];
    NSUInteger suffix = 2;
    while ([fileManager fileExistsAtPath:candidate.path]) {
        candidate = [directoryURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%lu.%@", baseName, (unsigned long)suffix, extension]];
        suffix++;
    }
    return candidate;
}

- (NSString *)markdownPathForImageURL:(NSURL *)imageURL relativeToMarkdownURL:(NSURL *)markdownURL {
    NSString *directoryName = imageURL.URLByDeletingLastPathComponent.lastPathComponent ?: @"";
    NSString *fileName = imageURL.lastPathComponent ?: @"image.png";
    return [NSString stringWithFormat:@"%@/%@", [self percentEncodedPathComponent:directoryName], [self percentEncodedPathComponent:fileName]];
}

- (NSString *)percentEncodedPathComponent:(NSString *)component {
    NSString *encoded = [component stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    return encoded ?: component;
}

- (NSString *)timestampString {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyyMMdd-HHmmss";
    return [formatter stringFromDate:NSDate.date];
}

- (NSString *)markdownBulletForBody:(NSString *)body imagePaths:(NSArray<NSString *> *)imagePaths needsLeadingNewline:(BOOL)needsLeadingNewline {
    NSArray<NSString *> *lines = [body componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    NSMutableArray<NSString *> *cleanLines = [NSMutableArray array];
    for (NSString *line in lines) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmedLine.length > 0) [cleanLines addObject:trimmedLine];
    }
    NSString *joinedBody = [cleanLines componentsJoinedByString:@" "];
    NSString *prefix = needsLeadingNewline ? @"\n" : @"";
    NSMutableString *entry = [NSMutableString stringWithString:prefix];
    if (joinedBody.length > 0) {
        [entry appendFormat:@"- %@\n", joinedBody];
        for (NSString *path in imagePaths) [entry appendFormat:@"  ![](%@)\n", path];
    } else if (imagePaths.count > 0) {
        [entry appendFormat:@"- ![](%@)\n", imagePaths.firstObject];
        for (NSUInteger index = 1; index < imagePaths.count; index++) [entry appendFormat:@"  ![](%@)\n", imagePaths[index]];
    } else {
        [entry appendString:@"- \n"];
    }
    return entry;
}

- (NSURL *)markdownFileURLWithError:(NSError **)outError {
    NSData *bookmark = [NSUserDefaults.standardUserDefaults objectForKey:MarkdownFileBookmarkKey];
    if (bookmark) {
        BOOL stale = NO;
        NSError *error = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithSecurityScope relativeToURL:nil bookmarkDataIsStale:&stale error:&error];
        if (url && !stale) return url;
    }

    NSString *path = [NSUserDefaults.standardUserDefaults stringForKey:MarkdownFilePathKey];
    if (path.length > 0) return [NSURL fileURLWithPath:path];

    if (outError) *outError = [NSError errorWithDomain:@"Notie" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Choose a Markdown file first."}];
    return nil;
}

- (NSURL *)currentMarkdownFileURL {
    NSString *path = [NSUserDefaults.standardUserDefaults stringForKey:MarkdownFilePathKey];
    if (path.length == 0) return nil;
    return [NSURL fileURLWithPath:path];
}

- (NSString *)targetDescription {
    NSString *path = [NSUserDefaults.standardUserDefaults stringForKey:MarkdownFilePathKey];
    if (path.length == 0) return @"No Markdown file selected.";
    NSString *filename = path.lastPathComponent.length > 0 ? path.lastPathComponent : path;
    NSUInteger imageCount = [self visibleImageCount];
    if (imageCount == 1) return [NSString stringWithFormat:@"%@ • 1 image", filename];
    if (imageCount > 1) return [NSString stringWithFormat:@"%@ • %lu images", filename, (unsigned long)imageCount];
    return filename;
}

- (void)showErrorWithTitle:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = message;
    alert.alertStyle = NSAlertStyleWarning;
    [alert runModal];
}

- (void)closeWindow:(id)sender { [self.window close]; }
- (void)quit:(id)sender { [NSApp terminate:nil]; }
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
