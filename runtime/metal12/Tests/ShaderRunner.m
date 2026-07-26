/*
 * Metal12 shader-corpus GPU runner.
 * Author: Timur Isaev
 *
 * Loads one lowered compute kernel, binds buffer fixtures, optionally binds a
 * deterministic RGBA32Float texture and sampler, dispatches one 64-thread test
 * group, and writes the buffer results back beside their inputs. The pipeline's
 * threadExecutionWidth is recorded so the independent CPU reference can model
 * Metal SIMD-group boundaries exactly.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#import "AlloyMetal12.h"

static void usage(void)
{
    puts("usage: ShaderRunner <metallib> <kernel> <threads> "
         "[--texture point|linear <width> <height> <mip-levels> <rgba32f.bin>] "
         "[--thread-width-out <path>] <buf0.bin> [buf1.bin ...]");
}

static BOOL writeThreadWidth(NSString *path, NSUInteger width)
{
    if (!path)
        return YES;

    NSString *text = [NSString stringWithFormat:@"%lu\n", (unsigned long)width];
    NSError *error = nil;
    BOOL wrote = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!wrote)
        fprintf(stderr, "thread width: %s\n", error.localizedDescription.UTF8String);
    return wrote;
}

static BOOL textureByteCount(NSUInteger width, NSUInteger height, NSUInteger mipLevels,
                             NSUInteger *byteCount)
{
    if (width == 0 || height == 0 || mipLevels == 0 || !byteCount)
        return NO;

    NSUInteger total = 0;
    for (NSUInteger level = 0; level < mipLevels; level++)
    {
        if (width > SIZE_MAX / height)
            return NO;
        NSUInteger texels = width * height;
        if (texels > SIZE_MAX / (4 * sizeof(float)))
            return NO;
        NSUInteger levelBytes = texels * 4 * sizeof(float);
        if (total > SIZE_MAX - levelBytes)
            return NO;
        total += levelBytes;
        width = MAX((NSUInteger)1, width / 2);
        height = MAX((NSUInteger)1, height / 2);
    }
    *byteCount = total;
    return YES;
}

static id<MTLTexture> makeTexture(id<MTLDevice> device, NSString *path, NSUInteger width,
                                  NSUInteger height, NSUInteger mipLevels)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSUInteger expected = 0;
    if (!textureByteCount(width, height, mipLevels, &expected) || !data || data.length != expected)
    {
        fprintf(stderr, "texture input: expected %lu bytes at %s, got %lu\n",
                (unsigned long)expected, path.UTF8String, (unsigned long)(data ? data.length : 0));
        return nil;
    }

    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                           width:width
                                                          height:height
                                                       mipmapped:mipLevels > 1];
    descriptor.mipmapLevelCount = mipLevels;
    descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    if (!texture)
    {
        fputs("texture input: Metal allocation failed\n", stderr);
        return nil;
    }

    const uint8_t *bytes = data.bytes;
    NSUInteger offset = 0;
    for (NSUInteger level = 0; level < mipLevels; level++)
    {
        MTLRegion region = MTLRegionMake2D(0, 0, width, height);
        [texture replaceRegion:region
                   mipmapLevel:level
                     withBytes:bytes + offset
                   bytesPerRow:width * 4 * sizeof(float)];
        offset += width * height * 4 * sizeof(float);
        width = MAX((NSUInteger)1, width / 2);
        height = MAX((NSUInteger)1, height / 2);
    }
    return texture;
}

static id<MTLSamplerState> makeSampler(id<MTLDevice> device, NSString *mode)
{
    BOOL linear = [mode isEqualToString:@"linear"];
    if (!linear && ![mode isEqualToString:@"point"])
    {
        fprintf(stderr, "sampler: unsupported mode %s\n", mode.UTF8String);
        return nil;
    }

    MTLSamplerDescriptor *descriptor = [[MTLSamplerDescriptor alloc] init];
    descriptor.normalizedCoordinates = YES;
    descriptor.sAddressMode = MTLSamplerAddressModeClampToEdge;
    descriptor.tAddressMode = MTLSamplerAddressModeClampToEdge;
    descriptor.minFilter = linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    descriptor.magFilter = descriptor.minFilter;
    descriptor.mipFilter = MTLSamplerMipFilterNearest;
    return [device newSamplerStateWithDescriptor:descriptor];
}

int main(int argc, char **argv)
{
    @autoreleasepool
    {
        if (argc < 5)
        {
            usage();
            return 2;
        }

        NSString *libraryPath = [NSString stringWithUTF8String:argv[1]];
        NSString *kernelName = [NSString stringWithUTF8String:argv[2]];
        NSUInteger threads = strtoul(argv[3], NULL, 10);
        NSString *textureMode = nil;
        NSString *texturePath = nil;
        NSString *threadWidthPath = nil;
        NSUInteger textureWidth = 0;
        NSUInteger textureHeight = 0;
        NSUInteger textureMipLevels = 0;
        int argument = 4;

        while (argument < argc && strncmp(argv[argument], "--", 2) == 0)
        {
            if (strcmp(argv[argument], "--texture") == 0)
            {
                if (argument + 5 >= argc)
                {
                    usage();
                    return 2;
                }
                textureMode = [NSString stringWithUTF8String:argv[argument + 1]];
                textureWidth = strtoul(argv[argument + 2], NULL, 10);
                textureHeight = strtoul(argv[argument + 3], NULL, 10);
                textureMipLevels = strtoul(argv[argument + 4], NULL, 10);
                texturePath = [NSString stringWithUTF8String:argv[argument + 5]];
                argument += 6;
            }
            else if (strcmp(argv[argument], "--thread-width-out") == 0)
            {
                if (argument + 1 >= argc)
                {
                    usage();
                    return 2;
                }
                threadWidthPath = [NSString stringWithUTF8String:argv[argument + 1]];
                argument += 2;
            }
            else
            {
                fprintf(stderr, "unknown option: %s\n", argv[argument]);
                usage();
                return 2;
            }
        }

        if (threads == 0 || argument >= argc)
        {
            usage();
            return 2;
        }

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device)
        {
            fputs("device: no Metal device\n", stderr);
            return 3;
        }

        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:libraryPath]
                                                     error:&error];
        if (!library)
        {
            fprintf(stderr, "library: %s\n", error.localizedDescription.UTF8String);
            return 3;
        }

        id<MTLFunction> function = [library newFunctionWithName:kernelName];
        if (!function)
        {
            fprintf(stderr, "function: kernel %s not found\n", kernelName.UTF8String);
            return 3;
        }
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function
                                                                                     error:&error];
        if (!pipeline)
        {
            fprintf(stderr, "pipeline: %s\n",
                    error ? error.localizedDescription.UTF8String : "unknown error");
            return 3;
        }

        NSUInteger threadsPerGroup = MIN((NSUInteger)64, threads);
        if (threads > UINT32_MAX || threadsPerGroup > UINT32_MAX ||
            pipeline.threadExecutionWidth > UINT32_MAX || textureWidth > UINT32_MAX ||
            textureHeight > UINT32_MAX || textureMipLevels > UINT32_MAX)
        {
            fputs("shader proof: configuration exceeds public API limits\n", stderr);
            return 4;
        }
        AM12ShaderProofConfiguration proofConfiguration = {
            .thread_count = (uint32_t)threads,
            .threads_per_threadgroup = (uint32_t)threadsPerGroup,
            .thread_execution_width = (uint32_t)pipeline.threadExecutionWidth,
            .texture_width = (uint32_t)textureWidth,
            .texture_height = (uint32_t)textureHeight,
            .texture_mip_levels = (uint32_t)textureMipLevels,
        };
        if (!AM12ValidateShaderProofConfiguration(&proofConfiguration))
        {
            fprintf(stderr, "shader proof: invalid dispatch %lu/%lu/%lu or texture %lux%lu/%lu\n",
                    (unsigned long)threads, (unsigned long)threadsPerGroup,
                    (unsigned long)pipeline.threadExecutionWidth, (unsigned long)textureWidth,
                    (unsigned long)textureHeight, (unsigned long)textureMipLevels);
            return 4;
        }
        if (!writeThreadWidth(threadWidthPath, pipeline.threadExecutionWidth))
            return 4;

        NSMutableArray<id<MTLBuffer>> *buffers = [NSMutableArray array];
        NSMutableArray<NSString *> *bufferPaths = [NSMutableArray array];
        for (int index = argument; index < argc; index++)
        {
            NSString *path = [NSString stringWithUTF8String:argv[index]];
            NSData *data = [NSData dataWithContentsOfFile:path];
            if (!data)
            {
                fprintf(stderr, "missing input %s\n", argv[index]);
                return 4;
            }
            id<MTLBuffer> buffer = [device newBufferWithBytes:data.bytes
                                                       length:data.length
                                                      options:MTLResourceStorageModeShared];
            if (!buffer)
            {
                fprintf(stderr, "buffer: allocation failed for %s\n", argv[index]);
                return 4;
            }
            [buffers addObject:buffer];
            [bufferPaths addObject:path];
        }

        id<MTLTexture> texture = nil;
        id<MTLSamplerState> sampler = nil;
        if (textureMode)
        {
            texture =
                makeTexture(device, texturePath, textureWidth, textureHeight, textureMipLevels);
            sampler = makeSampler(device, textureMode);
            if (!texture || !sampler)
                return 4;
        }

        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        for (NSUInteger index = 0; index < buffers.count; index++)
            [encoder setBuffer:buffers[index] offset:0 atIndex:index];
        if (texture)
        {
            [encoder setTexture:texture atIndex:0];
            [encoder setSamplerState:sampler atIndex:0];
        }
        [encoder dispatchThreads:MTLSizeMake(threads, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(threadsPerGroup, 1, 1)];
        [encoder endEncoding];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        if (commandBuffer.status == MTLCommandBufferStatusError)
        {
            fprintf(stderr, "command buffer: %s\n",
                    commandBuffer.error.localizedDescription.UTF8String);
            return 5;
        }

        for (NSUInteger index = 0; index < buffers.count; index++)
        {
            NSString *output = [bufferPaths[index] stringByAppendingString:@".out"];
            NSData *data = [NSData dataWithBytes:buffers[index].contents
                                          length:buffers[index].length];
            if (![data writeToFile:output atomically:YES])
            {
                fprintf(stderr, "output: could not write %s\n", output.UTF8String);
                return 5;
            }
        }

        printf("runner: kernel=%s threads=%lu threadExecutionWidth=%lu", kernelName.UTF8String,
               (unsigned long)threads, (unsigned long)pipeline.threadExecutionWidth);
        if (textureMode)
            printf(" sampler=%s mipLevels=%lu", textureMode.UTF8String,
                   (unsigned long)textureMipLevels);
        putchar('\n');
        return 0;
    }
}
