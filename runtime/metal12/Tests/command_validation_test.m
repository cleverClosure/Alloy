/*
 * Metal12 public-command validation tests.
 * Author: Timur Isaev
 */

#import "../include/AlloyMetal12.h"
#import <Foundation/Foundation.h>

#include <math.h>
#include <stdio.h>

static int ExpectRejected(int accepted, const char *name)
{
    if (accepted)
    {
        fprintf(stderr, "FAIL %-28s accepted\n", name);
        return 0;
    }
    printf("PASS %-28s rejected\n", name);
    return 1;
}

static int ExpectIncompleteCaptureRemoved(const char *metallibPath, BOOL beginFrame,
                                          const char *name)
{
    NSString *stem =
        [NSString stringWithFormat:@"alloy-metal12-incomplete-%@.am12", NSUUID.UUID.UUIDString];
    NSString *finalPath = [NSTemporaryDirectory() stringByAppendingPathComponent:stem];
    NSData *sentinel = [@"existing destination" dataUsingEncoding:NSUTF8StringEncoding];
    if (![sentinel writeToFile:finalPath atomically:NO])
    {
        fprintf(stderr, "FAIL %-28s fixture\n", name);
        return 0;
    }

    AM12DeviceDescriptor descriptor = {
        .width = 64,
        .height = 64,
        .frame_count = 1,
        .metallib_path = metallibPath,
        .capture_path = finalPath.fileSystemRepresentation,
    };
    AM12Device *device = AM12CreateDevice(&descriptor);
    BOOL setupSucceeded = device && (!beginFrame || AM12BeginFrame(device, 0));
    AM12DestroyDevice(device);

    NSData *remainingDestination = [NSData dataWithContentsOfFile:finalPath];
    NSString *temporaryPrefix = [stem stringByAppendingString:@".tmp."];
    NSArray<NSString *> *entries =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil];
    BOOL temporaryFound = NO;
    for (NSString *entry in entries)
    {
        if ([entry hasPrefix:temporaryPrefix])
        {
            temporaryFound = YES;
            break;
        }
    }
    BOOL passed =
        setupSucceeded && [remainingDestination isEqualToData:sentinel] && !temporaryFound;
    (void)[[NSFileManager defaultManager] removeItemAtPath:finalPath error:nil];
    if (!passed)
    {
        fprintf(stderr, "FAIL %-28s leaked or replaced destination\n", name);
        return 0;
    }
    printf("PASS %-28s cleaned\n", name);
    return 1;
}

int main(int argc, const char **argv)
{
    @autoreleasepool
    {
        if (argc != 2)
        {
            fprintf(stderr, "usage: %s SCENE.METALLIB\n", argv[0]);
            return 2;
        }

        AM12DeviceDescriptor descriptor = {
            .width = 64,
            .height = 64,
            .frame_count = 1,
            .metallib_path = argv[1],
        };
        AM12Device *device = AM12CreateDevice(&descriptor);
        if (!device)
            return 1;

        AM12Resource target = AM12CreateRenderTarget(device);
        AM12Resource buffer = AM12CreateSharedBuffer(device, 16);
        uint32_t generation = AM12CreateConstantBufferView(device, 0, buffer);
        uint32_t value = 1;
        int passed = 0;
        passed +=
            ExpectRejected(AM12WriteResource(device, buffer, 0, &value, 0), "zero-byte write");

        if (!target || !buffer || !generation || !AM12BeginFrame(device, 0))
        {
            AM12DestroyDevice(device);
            return 1;
        }
        passed +=
            ExpectRejected(AM12TransitionResource(device, target, AM12_RESOURCE_STATE_UNDEFINED,
                                                  AM12_RESOURCE_STATE_CONSTANT_BUFFER),
                           "texture-to-buffer state");
        passed += ExpectRejected(AM12SetGraphicsRootDescriptorTable(device, 0, generation + 1u),
                                 "stale descriptor");
        if (!AM12TransitionResource(device, target, AM12_RESOURCE_STATE_UNDEFINED,
                                    AM12_RESOURCE_STATE_RENDER_TARGET))
        {
            AM12DestroyDevice(device);
            return 1;
        }

        const float nonfiniteColor[4] = {NAN, 0.0f, 0.0f, 1.0f};
        passed += ExpectRejected(AM12ClearRenderTarget(device, target, nonfiniteColor),
                                 "non-finite clear");
        passed += ExpectRejected(AM12Present(device, target), "undefined presentation");
        passed += ExpectRejected(AM12EndFrame(device), "incomplete frame");

        AM12DestroyDevice(device);
        printf("public command validation: %d/6 rejected\n", passed);
        int cleanupPassed = 0;
        cleanupPassed += ExpectIncompleteCaptureRemoved(argv[1], NO, "missing-output capture");
        cleanupPassed += ExpectIncompleteCaptureRemoved(argv[1], YES, "active-frame capture");
        printf("capture cleanup validation: %d/2 cleaned\n", cleanupPassed);
        return passed == 6 && cleanupPassed == 2 ? 0 : 1;
    }
}
