/*
 * Metal12 trace preflight mutation tests.
 * Author: Timur Isaev
 */

#import "../include/AlloyMetal12.h"

#import <Foundation/Foundation.h>

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef enum AM12TestTraceOpcode
{
    AM12_TEST_TRACE_DEVICE = 1,
    AM12_TEST_TRACE_METALLIB = 2,
    AM12_TEST_TRACE_CREATE_TEXTURE = 3,
    AM12_TEST_TRACE_CREATE_BUFFER = 4,
    AM12_TEST_TRACE_WRITE_RESOURCE = 5,
    AM12_TEST_TRACE_CREATE_CBV = 7,
    AM12_TEST_TRACE_SET_ROOT_TABLE = 8,
    AM12_TEST_TRACE_BEGIN_FRAME = 9,
    AM12_TEST_TRACE_TRANSITION = 10,
    AM12_TEST_TRACE_DRAW = 12,
    AM12_TEST_TRACE_COPY = 13,
    AM12_TEST_TRACE_OUTPUT = 16,
} AM12TestTraceOpcode;

#pragma pack(push, 1)
typedef struct AM12TestTraceHeader
{
    char magic[8];
    uint16_t major;
    uint16_t minor;
    uint32_t header_size;
    uint32_t byte_order;
} AM12TestTraceHeader;

typedef struct AM12TestTraceRecordHeader
{
    uint16_t opcode;
    uint16_t flags;
    uint32_t payload_size;
} AM12TestTraceRecordHeader;

typedef struct AM12TestTraceDevice
{
    uint32_t width;
    uint32_t height;
    uint32_t frame_count;
} AM12TestTraceDevice;

typedef struct AM12TestTraceCreateResource
{
    uint32_t resource;
    uint64_t size;
} AM12TestTraceCreateResource;

typedef struct AM12TestTraceWriteResource
{
    uint32_t resource;
    uint64_t offset;
    uint64_t size;
} AM12TestTraceWriteResource;

typedef struct AM12TestTraceRootTable
{
    uint32_t slot;
    uint32_t generation;
} AM12TestTraceRootTable;

typedef struct AM12TestTraceFrame
{
    uint32_t frame_index;
} AM12TestTraceFrame;

typedef struct AM12TestTraceTransition
{
    uint32_t resource;
    uint32_t before;
    uint32_t after;
} AM12TestTraceTransition;

typedef struct AM12TestTraceDraw
{
    uint32_t resource;
    uint32_t vertex_count;
    uint32_t instance_count;
} AM12TestTraceDraw;
#pragma pack(pop)

typedef struct AM12TestRecordLocation
{
    AM12TestTraceRecordHeader header;
    size_t record_offset;
    size_t payload_offset;
    size_t total_size;
} AM12TestRecordLocation;

typedef struct AM12TestTraceIndex
{
    AM12TestRecordLocation *records;
    size_t count;
    size_t capacity;
} AM12TestTraceIndex;

typedef BOOL (*AM12TestMutation)(NSMutableData *data, const AM12TestTraceIndex *index);

typedef struct AM12TestMutationCase
{
    const char *name;
    AM12TestMutation mutate;
} AM12TestMutationCase;

_Static_assert(sizeof(AM12TestTraceHeader) == 20, "trace header layout changed");
_Static_assert(sizeof(AM12TestTraceRecordHeader) == 8, "record header layout changed");
_Static_assert(sizeof(AM12TestTraceDevice) == 12, "device payload layout changed");
_Static_assert(sizeof(AM12TestTraceCreateResource) == 12, "resource payload layout changed");
_Static_assert(sizeof(AM12TestTraceWriteResource) == 20, "write payload layout changed");
_Static_assert(sizeof(AM12TestTraceRootTable) == 8, "root-table payload layout changed");
_Static_assert(sizeof(AM12TestTraceFrame) == 4, "frame payload layout changed");
_Static_assert(sizeof(AM12TestTraceTransition) == 12, "transition payload layout changed");
_Static_assert(sizeof(AM12TestTraceDraw) == 12, "draw payload layout changed");

static BOOL AM12TestCheckedAdd(size_t left, size_t right, size_t *result)
{
    if (left > SIZE_MAX - right)
        return NO;
    *result = left + right;
    return YES;
}

static BOOL AM12TestAppendLocation(AM12TestTraceIndex *index,
                                   const AM12TestRecordLocation *location)
{
    if (index->count == index->capacity)
    {
        size_t capacity = index->capacity ? index->capacity * 2u : 64u;
        if (capacity < index->capacity || capacity > AM12_MAX_TRACE_RECORDS)
            capacity = AM12_MAX_TRACE_RECORDS;
        if (capacity <= index->capacity || capacity > SIZE_MAX / sizeof(*index->records))
            return NO;
        void *records = realloc(index->records, capacity * sizeof(*index->records));
        if (!records)
            return NO;
        index->records = records;
        index->capacity = capacity;
    }
    index->records[index->count++] = *location;
    return YES;
}

static BOOL AM12TestIndexTrace(NSData *data, AM12TestTraceIndex *index)
{
    memset(index, 0, sizeof(*index));
    if (data.length < sizeof(AM12TestTraceHeader))
        return NO;

    const uint8_t *bytes = data.bytes;
    size_t offset = sizeof(AM12TestTraceHeader);
    while (offset < data.length)
    {
        size_t payloadOffset = 0;
        size_t endOffset = 0;
        AM12TestTraceRecordHeader header;
        if (!AM12TestCheckedAdd(offset, sizeof(header), &payloadOffset) ||
            payloadOffset > data.length)
            return NO;
        memcpy(&header, bytes + offset, sizeof(header));
        if (!AM12TestCheckedAdd(payloadOffset, header.payload_size, &endOffset) ||
            endOffset > data.length)
            return NO;
        AM12TestRecordLocation location = {
            .header = header,
            .record_offset = offset,
            .payload_offset = payloadOffset,
            .total_size = endOffset - offset,
        };
        if (!AM12TestAppendLocation(index, &location))
            return NO;
        offset = endOffset;
    }
    return offset == data.length && index->count > 0;
}

static const AM12TestRecordLocation *AM12TestFindRecord(const AM12TestTraceIndex *index,
                                                        uint16_t opcode, size_t occurrence)
{
    for (size_t recordIndex = 0; recordIndex < index->count; recordIndex++)
    {
        const AM12TestRecordLocation *location = &index->records[recordIndex];
        if (location->header.opcode == opcode)
        {
            if (!occurrence)
                return location;
            occurrence--;
        }
    }
    return NULL;
}

static BOOL AM12TestReadPayload(NSData *data, const AM12TestRecordLocation *location, void *payload,
                                size_t size)
{
    if (!location || size > location->header.payload_size ||
        location->payload_offset > data.length || size > data.length - location->payload_offset)
        return NO;
    memcpy(payload, (const uint8_t *)data.bytes + location->payload_offset, size);
    return YES;
}

static BOOL AM12TestWriteBytes(NSMutableData *data, size_t offset, const void *bytes, size_t size)
{
    if (offset > data.length || size > data.length - offset)
        return NO;
    memcpy((uint8_t *)data.mutableBytes + offset, bytes, size);
    return YES;
}

static BOOL AM12TestMutateBadMagic(NSMutableData *data, const AM12TestTraceIndex *index)
{
    (void)index;
    AM12TestTraceHeader header;
    if (data.length < sizeof(header))
        return NO;
    memcpy(&header, data.bytes, sizeof(header));
    header.magic[0] ^= 0x7f;
    return AM12TestWriteBytes(data, 0, &header, sizeof(header));
}

static BOOL AM12TestMutateBadVersion(NSMutableData *data, const AM12TestTraceIndex *index)
{
    (void)index;
    AM12TestTraceHeader header;
    if (data.length < sizeof(header))
        return NO;
    memcpy(&header, data.bytes, sizeof(header));
    header.major = (uint16_t)(AM12_TRACE_FORMAT_MAJOR + 1u);
    return AM12TestWriteBytes(data, 0, &header, sizeof(header));
}

static BOOL AM12TestMutateTruncatedTail(NSMutableData *data, const AM12TestTraceIndex *index)
{
    (void)index;
    if (data.length <= sizeof(AM12TestTraceHeader))
        return NO;
    data.length = data.length - 1u;
    return YES;
}

static BOOL AM12TestMutateUnknownOpcode(NSMutableData *data, const AM12TestTraceIndex *index)
{
    const AM12TestRecordLocation *location = AM12TestFindRecord(index, AM12_TEST_TRACE_DEVICE, 0);
    AM12TestTraceRecordHeader header;
    if (!location)
        return NO;
    header = location->header;
    header.opcode = UINT16_MAX;
    return AM12TestWriteBytes(data, location->record_offset, &header, sizeof(header));
}

static BOOL AM12TestMutateBadFlags(NSMutableData *data, const AM12TestTraceIndex *index)
{
    const AM12TestRecordLocation *location = AM12TestFindRecord(index, AM12_TEST_TRACE_DEVICE, 0);
    AM12TestTraceRecordHeader header;
    if (!location)
        return NO;
    header = location->header;
    header.flags = 1;
    return AM12TestWriteBytes(data, location->record_offset, &header, sizeof(header));
}

static BOOL AM12TestRemoveRecord(NSMutableData *data, const AM12TestTraceIndex *index,
                                 uint16_t opcode)
{
    const AM12TestRecordLocation *location = AM12TestFindRecord(index, opcode, 0);
    if (!location || location->record_offset > data.length ||
        location->total_size > data.length - location->record_offset)
        return NO;
    [data replaceBytesInRange:NSMakeRange(location->record_offset, location->total_size)
                    withBytes:NULL
                       length:0];
    return YES;
}

static BOOL AM12TestMutateMissingMetallib(NSMutableData *data, const AM12TestTraceIndex *index)
{
    return AM12TestRemoveRecord(data, index, AM12_TEST_TRACE_METALLIB);
}

static BOOL AM12TestMutateMissingOutput(NSMutableData *data, const AM12TestTraceIndex *index)
{
    return AM12TestRemoveRecord(data, index, AM12_TEST_TRACE_OUTPUT);
}

static BOOL AM12TestMutateDuplicateDevice(NSMutableData *data, const AM12TestTraceIndex *index)
{
    const AM12TestRecordLocation *location = AM12TestFindRecord(index, AM12_TEST_TRACE_DEVICE, 0);
    if (!location || location->record_offset > data.length ||
        location->total_size > data.length - location->record_offset)
        return NO;
    NSData *record =
        [data subdataWithRange:NSMakeRange(location->record_offset, location->total_size)];
    size_t insertionOffset = location->record_offset + location->total_size;
    [data replaceBytesInRange:NSMakeRange(insertionOffset, 0)
                    withBytes:record.bytes
                       length:record.length];
    return YES;
}

static BOOL AM12TestMutateDeviceField(NSMutableData *data, const AM12TestTraceIndex *index,
                                      BOOL mutateFrameCount)
{
    const AM12TestRecordLocation *location = AM12TestFindRecord(index, AM12_TEST_TRACE_DEVICE, 0);
    AM12TestTraceDevice record;
    if (!AM12TestReadPayload(data, location, &record, sizeof(record)))
        return NO;
    if (mutateFrameCount)
        record.frame_count = AM12_MAX_FRAMES + 1u;
    else
        record.width = AM12_MAX_DIMENSION + 1u;
    return AM12TestWriteBytes(data, location->payload_offset, &record, sizeof(record));
}

static BOOL AM12TestMutateOversizedDimension(NSMutableData *data, const AM12TestTraceIndex *index)
{
    return AM12TestMutateDeviceField(data, index, NO);
}

static BOOL AM12TestMutateOversizedFrameCount(NSMutableData *data, const AM12TestTraceIndex *index)
{
    return AM12TestMutateDeviceField(data, index, YES);
}

static BOOL AM12TestMutateOversizedBuffer(NSMutableData *data, const AM12TestTraceIndex *index)
{
    const AM12TestRecordLocation *location =
        AM12TestFindRecord(index, AM12_TEST_TRACE_CREATE_BUFFER, 0);
    AM12TestTraceCreateResource record;
    if (!AM12TestReadPayload(data, location, &record, sizeof(record)))
        return NO;
    record.size = (uint64_t)AM12_MAX_BUFFER_BYTES + UINT64_C(1);
    return AM12TestWriteBytes(data, location->payload_offset, &record, sizeof(record));
}

static BOOL AM12TestMutateBadWriteRange(NSMutableData *data, const AM12TestTraceIndex *index)
{
    const AM12TestRecordLocation *location =
        AM12TestFindRecord(index, AM12_TEST_TRACE_WRITE_RESOURCE, 0);
    AM12TestTraceWriteResource record;
    if (!AM12TestReadPayload(data, location, &record, sizeof(record)))
        return NO;
    record.offset = UINT64_MAX;
    return AM12TestWriteBytes(data, location->payload_offset, &record, sizeof(record));
}

static BOOL AM12TestMutateTransitionBefore(NSMutableData *data, const AM12TestTraceIndex *index)
{
    const AM12TestRecordLocation *location =
        AM12TestFindRecord(index, AM12_TEST_TRACE_TRANSITION, 0);
    AM12TestTraceTransition record;
    if (!AM12TestReadPayload(data, location, &record, sizeof(record)))
        return NO;
    record.before = record.before == AM12_RESOURCE_STATE_UNDEFINED
                        ? AM12_RESOURCE_STATE_RENDER_TARGET
                        : AM12_RESOURCE_STATE_UNDEFINED;
    return AM12TestWriteBytes(data, location->payload_offset, &record, sizeof(record));
}

static BOOL AM12TestMutateDescriptorGeneration(NSMutableData *data, const AM12TestTraceIndex *index)
{
    const AM12TestRecordLocation *location =
        AM12TestFindRecord(index, AM12_TEST_TRACE_SET_ROOT_TABLE, 0);
    AM12TestTraceRootTable record;
    if (!AM12TestReadPayload(data, location, &record, sizeof(record)))
        return NO;
    record.generation =
        record.generation == UINT32_MAX ? record.generation - 1u : record.generation + 1u;
    return AM12TestWriteBytes(data, location->payload_offset, &record, sizeof(record));
}

static BOOL AM12TestMutateFrameIndex(NSMutableData *data, const AM12TestTraceIndex *index)
{
    const AM12TestRecordLocation *location =
        AM12TestFindRecord(index, AM12_TEST_TRACE_BEGIN_FRAME, 0);
    AM12TestTraceFrame record;
    if (!AM12TestReadPayload(data, location, &record, sizeof(record)))
        return NO;
    record.frame_index = record.frame_index == 0 ? 1u : 0u;
    return AM12TestWriteBytes(data, location->payload_offset, &record, sizeof(record));
}

static BOOL AM12TestMutateOversizedDraw(NSMutableData *data, const AM12TestTraceIndex *index)
{
    const AM12TestRecordLocation *location = AM12TestFindRecord(index, AM12_TEST_TRACE_DRAW, 0);
    AM12TestTraceDraw record;
    if (!AM12TestReadPayload(data, location, &record, sizeof(record)))
        return NO;
    record.vertex_count = UINT32_MAX;
    record.instance_count = UINT32_MAX;
    return AM12TestWriteBytes(data, location->payload_offset, &record, sizeof(record));
}

static BOOL AM12TestMutateBarrierAccessOverflow(NSMutableData *data,
                                                const AM12TestTraceIndex *index)
{
    const AM12TestRecordLocation *location = AM12TestFindRecord(index, AM12_TEST_TRACE_COPY, 0);
    if (!location || location->record_offset > data.length ||
        location->total_size > data.length - location->record_offset)
        return NO;

    NSData *record =
        [data subdataWithRange:NSMakeRange(location->record_offset, location->total_size)];
    size_t insertionOffset = location->record_offset + location->total_size;
    for (uint32_t copy = 0; copy < 15; copy++)
        [data replaceBytesInRange:NSMakeRange(insertionOffset, 0)
                        withBytes:record.bytes
                           length:record.length];
    return YES;
}

static BOOL AM12TestExpectRejection(NSData *data, const char *name)
{
    NSString *filename =
        [NSString stringWithFormat:@"alloy-metal12-trace-%@.am12", NSUUID.UUID.UUIDString];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:filename];
    NSError *error = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&error])
    {
        fprintf(stderr, "FAIL %-32s could not write mutation: %s\n", name,
                error.localizedDescription.UTF8String);
        return NO;
    }

    int accepted = AM12ValidateTrace(path.fileSystemRepresentation);
    NSError *removeError = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:path error:&removeError])
    {
        fprintf(stderr, "FAIL %-32s could not remove mutation: %s\n", name,
                removeError.localizedDescription.UTF8String);
        return NO;
    }
    if (accepted)
    {
        fprintf(stderr, "FAIL %-32s validator accepted mutation\n", name);
        return NO;
    }
    printf("PASS %-32s rejected\n", name);
    return YES;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool
    {
        if (argc != 2)
        {
            fprintf(stderr, "usage: %s VALID_CAPTURE.am12\n", argv[0]);
            return 2;
        }
        if (!AM12ValidateTrace(argv[1]))
        {
            fprintf(stderr, "FAIL baseline trace was not accepted: %s\n", argv[1]);
            return 1;
        }

        NSString *path =
            [NSFileManager.defaultManager stringWithFileSystemRepresentation:argv[1]
                                                                      length:strlen(argv[1])];
        NSError *error = nil;
        NSData *baseline = [NSData dataWithContentsOfFile:path
                                                  options:NSDataReadingMappedIfSafe
                                                    error:&error];
        if (!baseline)
        {
            fprintf(stderr, "FAIL could not read baseline trace: %s\n",
                    error.localizedDescription.UTF8String);
            return 1;
        }

        AM12TestTraceIndex index;
        if (!AM12TestIndexTrace(baseline, &index))
        {
            fprintf(stderr, "FAIL could not index accepted baseline trace\n");
            return 1;
        }

        static const AM12TestMutationCase cases[] = {
            {"bad_magic", AM12TestMutateBadMagic},
            {"bad_header_version", AM12TestMutateBadVersion},
            {"truncated_tail", AM12TestMutateTruncatedTail},
            {"unknown_opcode", AM12TestMutateUnknownOpcode},
            {"nonzero_record_flags", AM12TestMutateBadFlags},
            {"missing_metallib", AM12TestMutateMissingMetallib},
            {"missing_output", AM12TestMutateMissingOutput},
            {"duplicate_device", AM12TestMutateDuplicateDevice},
            {"oversized_dimension", AM12TestMutateOversizedDimension},
            {"oversized_frame_count", AM12TestMutateOversizedFrameCount},
            {"oversized_buffer", AM12TestMutateOversizedBuffer},
            {"bad_write_range", AM12TestMutateBadWriteRange},
            {"transition_before_mismatch", AM12TestMutateTransitionBefore},
            {"descriptor_generation_mismatch", AM12TestMutateDescriptorGeneration},
            {"frame_index_mismatch", AM12TestMutateFrameIndex},
            {"oversized_draw", AM12TestMutateOversizedDraw},
            {"barrier_access_overflow", AM12TestMutateBarrierAccessOverflow},
        };

        size_t passed = 0;
        for (size_t caseIndex = 0; caseIndex < sizeof(cases) / sizeof(cases[0]); caseIndex++)
        {
            @autoreleasepool
            {
                NSMutableData *mutation = [baseline mutableCopy];
                if (!cases[caseIndex].mutate(mutation, &index))
                {
                    fprintf(stderr, "FAIL %-32s could not construct mutation\n",
                            cases[caseIndex].name);
                    continue;
                }
                if (AM12TestExpectRejection(mutation, cases[caseIndex].name))
                    passed++;
            }
        }

        free(index.records);
        size_t total = sizeof(cases) / sizeof(cases[0]);
        printf("trace validation mutations: %zu/%zu rejected\n", passed, total);
        return passed == total ? 0 : 1;
    }
}
