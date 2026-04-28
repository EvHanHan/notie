#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>

static NSString * const MarkdownFileBookmarkKey = @"MarkdownFileBookmark";
static NSString * const MarkdownFilePathKey = @"MarkdownFilePath";
static unichar const ImagePreviewPlaceholderCharacter = 0xFFFC;

@interface CaptureTextView : NSTextView
@property (nonatomic, copy) void (^commandReturnHandler)(void);
@property (nonatomic, copy) void (^escapeHandler)(void);
@property (nonatomic, copy) BOOL (^pasteboardImageHandler)(NSPasteboard *pasteboard);
@end

@implementation CaptureTextView
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 36 && (event.modifierFlags & NSEventModifierFlagCommand)) {
        if (self.commandReturnHandler) self.commandReturnHandler();
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
    if ([[pasteboard types] containsObject:NSPasteboardTypePNG] || [[pasteboard types] containsObject:NSPasteboardTypeTIFF]) return YES;
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSSet<NSString *> *extensions = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"tif", @"tiff", @"bmp", @"webp"]];
    for (NSURL *url in urls) {
        if ([extensions containsObject:url.pathExtension.lowercaseString]) return YES;
    }
    return NO;
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTextViewDelegate>
@property NSStatusItem *statusItem;
@property NSWindow *window;
@property CaptureTextView *textView;
@property NSTextField *targetLabel;
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
    [self buildStatusItem];
    [self buildWindow];
    [self registerHotKey];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    if (_hotKeyRef) UnregisterEventHotKey(_hotKeyRef);
    if (_handlerRef) RemoveEventHandler(_handlerRef);
}

- (void)buildStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.title = @"✎";
    self.statusItem.button.toolTip = @"Notie";

    NSMenu *menu = [NSMenu new];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"New Note" action:@selector(showCaptureWindow:) keyEquivalent:@"k"]];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Append to Markdown" action:@selector(saveNote:) keyEquivalent:@"\r"]];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Choose Markdown File…" action:@selector(chooseMarkdownFile:) keyEquivalent:@"o"]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[[NSMenuItem alloc] initWithTitle:@"Quit" action:@selector(quit:) keyEquivalent:@"q"]];
    self.statusItem.menu = menu;
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 500, 292);
    self.window = [[NSWindow alloc] initWithContentRect:frame styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Notie";
    self.window.level = NSFloatingWindowLevel;
    self.window.releasedWhenClosed = NO;
    self.window.backgroundColor = NSColor.windowBackgroundColor;
    [self.window center];

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
    self.textView = [[CaptureTextView alloc] initWithFrame:scrollView.bounds];
    self.textView.font = [NSFont systemFontOfSize:15];
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
    self.textView.pasteboardImageHandler = ^BOOL(NSPasteboard *pasteboard) { return [weakSelf addPendingImagesFromPasteboard:pasteboard]; };
    [self.textView registerForDraggedTypes:@[NSPasteboardTypeFileURL, NSPasteboardTypePNG, NSPasteboardTypeTIFF]];
    scrollView.documentView = self.textView;
    [content addSubview:scrollView];

    NSButton *chooseButton = [NSButton buttonWithTitle:@"Choose File…" target:self action:@selector(chooseMarkdownFile:)];
    chooseButton.frame = NSMakeRect(12, 10, 112, 32);
    [self.bottomBar addSubview:chooseButton];

    self.targetLabel = [NSTextField labelWithString:[self targetDescription]];
    self.targetLabel.textColor = NSColor.secondaryLabelColor;
    self.targetLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.targetLabel.frame = NSMakeRect(132, 16, 180, 20);
    [self.bottomBar addSubview:self.targetLabel];

    NSButton *saveButton = [NSButton buttonWithTitle:@"Save  ⌘ ↩" target:self action:@selector(saveNote:)];
    saveButton.keyEquivalent = @"\r";
    saveButton.frame = NSMakeRect(328, 10, 160, 32);
    [self.bottomBar addSubview:saveButton];
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
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
    self.textView.string = @"";
    [self.pendingImages removeAllObjects];
    [self.attachmentImageIDs removeAllObjects];
    self.targetLabel.stringValue = [self targetDescription];
    [self.window makeFirstResponder:self.textView];
}

- (BOOL)addPendingImagesFromPasteboard:(NSPasteboard *)pasteboard {
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSSet<NSString *> *extensions = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"gif", @"heic", @"tif", @"tiff", @"bmp", @"webp"]];
    NSUInteger addedCount = 0;
    for (NSURL *url in urls) {
        if (![extensions containsObject:url.pathExtension.lowercaseString]) continue;
        NSImage *image = [[NSImage alloc] initWithContentsOfURL:url];
        NSString *imageID = NSUUID.UUID.UUIDString;
        NSString *name = url.lastPathComponent ?: @"image";
        [self.pendingImages addObject:@{@"url": url, @"name": name, @"id": imageID}];
        [self insertImagePreview:image name:name imageID:imageID];
        addedCount++;
    }

    if (addedCount == 0) {
        NSImage *image = [[NSImage alloc] initWithPasteboard:pasteboard];
        if (image) {
            NSString *name = [NSString stringWithFormat:@"screenshot-%@.png", [self timestampString]];
            NSString *imageID = NSUUID.UUID.UUIDString;
            [self.pendingImages addObject:@{@"image": image, @"name": name, @"id": imageID}];
            [self insertImagePreview:image name:name imageID:imageID];
            addedCount++;
        }
    }

    if (addedCount == 0) return NO;
    self.targetLabel.stringValue = [self targetDescription];
    return YES;
}

- (void)insertImagePreview:(NSImage *)image name:(NSString *)name imageID:(NSString *)imageID {
    NSMutableAttributedString *insertion = [[NSMutableAttributedString alloc] initWithString:@"\n"];
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = [self previewImageForImage:image ?: [self placeholderImageWithName:name]];
    [self.attachmentImageIDs setObject:imageID forKey:attachment];
    [insertion appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    [insertion appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n"]];
    NSRange replacementRange = self.textView.selectedRange;
    [self.textView.textStorage replaceCharactersInRange:replacementRange withAttributedString:insertion];
    self.textView.selectedRange = NSMakeRange(replacementRange.location + insertion.length, 0);
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

    if ([panel runModal] != NSModalResponseOK) return;

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
    self.targetLabel.stringValue = [self targetDescription];
}

- (void)saveNote:(id)sender {
    NSString *body = [[self plainBodyText] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSDictionary *> *visibleImages = [self visiblePendingImages];
    if (body.length == 0 && visibleImages.count == 0) {
        NSBeep();
        return;
    }

    NSError *error = nil;
    if ([self appendEntryWithBody:body images:visibleImages error:&error]) {
        [self.window close];
        [self.pendingImages removeAllObjects];
        NSUserNotification *notification = [NSUserNotification new];
        notification.title = @"Saved to Markdown";
        notification.informativeText = [self targetDescription];
        [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notification];
    } else {
        [self showErrorWithTitle:@"Couldn’t save to Markdown" message:error.localizedDescription ?: @"Unknown error."];
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
    self.targetLabel.stringValue = [self targetDescription];
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

- (NSString *)targetDescription {
    NSString *path = [NSUserDefaults.standardUserDefaults stringForKey:MarkdownFilePathKey];
    if (path.length == 0) return @"No Markdown file selected.";
    NSUInteger imageCount = [self visibleImageCount];
    if (imageCount == 1) return [NSString stringWithFormat:@"Target: %@ • 1 image", path];
    if (imageCount > 1) return [NSString stringWithFormat:@"Target: %@ • %lu images", path, (unsigned long)imageCount];
    return [NSString stringWithFormat:@"Target: %@", path];
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
