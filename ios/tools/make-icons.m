// Draws the PhoneBox launcher icon (the same artwork as android/.../ic_launcher_fg.xml) as PNGs. macOS only; the PNGs are
// committed, so this is only needed when the artwork changes:  clang -fobjc-arc -framework Cocoa tools/make-icons.m -o /tmp/mkicons && /tmp/mkicons ios/app/Resources
#import <Cocoa/Cocoa.h>

static void Fill(CGContextRef c, CGFloat r, CGFloat g, CGFloat b) { CGContextSetRGBFillColor(c, r / 255, g / 255, b / 255, 1); }

static void Draw(CGContextRef c, CGFloat size) {
    Fill(c, 0x0F, 0x13, 0x18);
    CGContextFillRect(c, CGRectMake(0, 0, size, size));
    CGFloat k = size * 0.66 / 48.0; // the 48-unit wide artwork fills about two thirds of the icon
    CGContextTranslateCTM(c, size / 2, size / 2);
    CGContextScaleCTM(c, k, -k);     // y down, like the vector drawable
    CGContextTranslateCTM(c, -54, -54);

    CGContextSetRGBStrokeColor(c, 0xE8 / 255.0, 0xEC / 255.0, 0xF1 / 255.0, 1);
    CGContextSetLineWidth(c, 3);
    CGPathRef screen = CGPathCreateWithRoundedRect(CGRectMake(30, 36, 48, 32), 5, 5, NULL);
    CGContextAddPath(c, screen); CGContextStrokePath(c); CFRelease(screen);

    Fill(c, 0x2D, 0xD4, 0xBF); CGContextFillRect(c, CGRectMake(38, 55, 5, 6));
    Fill(c, 0x76, 0xB9, 0x00); CGContextFillRect(c, CGRectMake(46, 48, 5, 13));
    Fill(c, 0xA7, 0x8B, 0xFA); CGContextFillRect(c, CGRectMake(54, 52, 5, 9));
    Fill(c, 0xF5, 0x9E, 0x0B); CGContextFillEllipseInRect(c, CGRectMake(64, 43, 8, 8));
    Fill(c, 0xE8, 0xEC, 0xF1);
    CGContextFillRect(c, CGRectMake(51, 68, 6, 5));
    CGContextFillRect(c, CGRectMake(43, 73, 22, 3));
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *dir = argc > 1 ? @(argv[1]) : @".";
        NSDictionary *sizes = @{@"AppIcon60x60@2x": @120, @"AppIcon60x60@3x": @180, @"AppIcon76x76@2x": @152,
                                @"AppIcon83.5x83.5@2x": @167, @"AppIcon-1024": @1024};
        for (NSString *name in sizes) {
            int px = [sizes[name] intValue];
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef c = CGBitmapContextCreate(NULL, px, px, 8, 0, cs, kCGImageAlphaNoneSkipLast); // opaque: iOS rounds the corners
            Draw(c, px);
            CGImageRef img = CGBitmapContextCreateImage(c);
            NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[dir stringByAppendingFormat:@"/%@.png", name] atomically:YES];
            CGImageRelease(img); CGContextRelease(c); CGColorSpaceRelease(cs);
        }
    }
    return 0;
}
