/*
 * M12-003 generic metallib runner.
 * Author: Tim Isaev
 *
 * Loads a metallib, binds N buffers from .bin files at indices 0..N-1,
 * dispatches the named kernel over the element count, and writes each
 * buffer back to <input>.out.bin for comparison against the CPU reference.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        if (argc < 5)
        {
            puts("usage: msl_run <metallib> <kernel> <threads> <buf0.bin> [buf1.bin ...]");
            return 2;
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *error = nil;
        id<MTLLibrary> library = [device
            newLibraryWithURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]]
                        error:&error];
        if (!library)
        {
            printf("library: %s\n", error.localizedDescription.UTF8String);
            return 3;
        }
        id<MTLFunction> function =
            [library newFunctionWithName:[NSString stringWithUTF8String:argv[2]]];
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function
                                                                                     error:&error];
        if (!pipeline)
        {
            printf("pipeline: %s\n", error ? error.localizedDescription.UTF8String : "?");
            return 3;
        }

        NSUInteger threads = strtoul(argv[3], NULL, 10);
        NSMutableArray<id<MTLBuffer>> *buffers = [NSMutableArray array];
        for (int i = 4; i < argc; i++)
        {
            NSData *data = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[i]]];
            if (!data)
            {
                printf("missing input %s\n", argv[i]);
                return 4;
            }
            [buffers addObject:[device newBufferWithBytes:data.bytes
                                                   length:data.length
                                                  options:MTLResourceStorageModeShared]];
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pipeline];
        for (NSUInteger i = 0; i < buffers.count; i++)
            [enc setBuffer:buffers[i] offset:0 atIndex:i];
        [enc dispatchThreads:MTLSizeMake(threads, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        for (NSUInteger i = 0; i < buffers.count; i++)
        {
            NSString *out =
                [[NSString stringWithUTF8String:argv[4 + i]] stringByAppendingString:@".out"];
            [[NSData dataWithBytes:buffers[i].contents length:buffers[i].length] writeToFile:out
                                                                                  atomically:YES];
        }
        return 0;
    }
}
