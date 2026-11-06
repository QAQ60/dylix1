#import <Foundation/Foundation.h>
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSString *path = @"/private/var/mobile/Containers/Shared/AppGroup/.jbroot-913B7E7901635E91/var/mobile/Documents/wiki.qaq.apelin/Projects/dylix-workbuddy/Attachments/e0355b69-6ae9-4337-9d22-f964b7070487";
        if (argc > 1) path = [NSString stringWithUTF8String:argv[1]];
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
        if (!src) { fprintf(stderr, "no image\n"); return 1; }
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        CFRelease(src);
        if (!img) { fprintf(stderr, "no cgimage\n"); return 1; }

        VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
        req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
        req.usesLanguageCorrection = YES;

        VNImageRequestHandler *h = [[VNImageRequestHandler alloc] initWithCGImage:img options:@{}];
        NSError *err = nil;
        [h performRequests:@[req] error:&err];
        if (err) { fprintf(stderr, "ocr error: %s\n", err.localizedDescription.UTF8String); return 1; }

        NSArray *results = [req.results sortedArrayUsingComparator:^NSComparisonResult(VNRecognizedTextObservation *a, VNRecognizedTextObservation *b) {
            if (a.boundingBox.origin.y > b.boundingBox.origin.y) return NSOrderedAscending;
            if (a.boundingBox.origin.y < b.boundingBox.origin.y) return NSOrderedDescending;
            return a.boundingBox.origin.x < b.boundingBox.origin.x ? NSOrderedAscending : NSOrderedDescending;
        }];
        for (VNRecognizedTextObservation *obs in results) {
            NSString *t = [[obs topCandidates:1] firstObject].string;
            if (t.length) printf("%s\n", t.UTF8String);
        }
        CGImageRelease(img);
    }
    return 0;
}
