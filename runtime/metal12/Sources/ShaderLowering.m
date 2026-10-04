/*
 * Metal12 public DXIL-to-MSL lowering entry point.
 * Author: Timur Isaev
 */

#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>

#import "../include/AlloyMetal12.h"

#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define AM12_CANONICAL_PYTHON_PATH "/usr/bin/python3"
#define AM12_MAX_CONTAINER_PARTS 64u
#define AM12_MAX_SHADER_INPUT_BYTES (64u * 1024u * 1024u)
#define AM12_MAX_SHADER_OPS 16384u
#define AM12_MAX_MSL_BYTES (16u * 1024u * 1024u)
#define AM12_MAX_PROVENANCE_BYTES (1024u * 1024u)
#define AM12_MAX_LOWERER_BYTES (1024u * 1024u)
#define AM12_COMPUTE_FIXTURE_BYTES (64u * sizeof(uint32_t))
#define AM12_LOWERER_TIMEOUT_MILLISECONDS 30000u

#include "AM12EmbeddedLowerer.inc"

_Static_assert(sizeof(AM12CanonicalLowererBytes) <= AM12_MAX_LOWERER_BYTES,
               "canonical lowerer exceeds the embedded payload limit");

typedef struct AM12LoweringArtifacts
{
    BOOL metal;
    BOOL provenance;
    BOOL inputs[AM12_MAX_RESOURCES];
    BOOL references[AM12_MAX_RESOURCES];
    NSMutableArray<NSString *> *publish_names;
} AM12LoweringArtifacts;

static int AM12LoweringFailure(const char *detail)
{
    fprintf(stderr, "AM12 lowering failure: %s\n", detail ? detail : "unknown error");
    return 0;
}

static int AM12PathIsBounded(const char *path)
{
    if (!path)
        return 0;
    size_t length = strnlen(path, AM12_MAX_PATH_BYTES + 1u);
    return length > 0 && length <= AM12_MAX_PATH_BYTES;
}

static int AM12PathHasMode(const char *path, mode_t mode)
{
    struct stat status;
    return AM12PathIsBounded(path) && lstat(path, &status) == 0 &&
           (status.st_mode & S_IFMT) == mode;
}

static int AM12JoinPath(char result[AM12_MAX_PATH_BYTES + 1u], const char *directory,
                        const char *name)
{
    if (!AM12PathIsBounded(directory) || !name || !name[0])
        return 0;
    int written = snprintf(result, AM12_MAX_PATH_BYTES + 1u, "%s/%s", directory, name);
    return written > 0 && (size_t)written <= AM12_MAX_PATH_BYTES;
}

static int AM12ExtractShaderName(const char *path, char shaderName[AM12_MAX_ENTRY_NAME_BYTES + 1u])
{
    if (!AM12PathIsBounded(path))
        return 0;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    size_t length = strlen(base);
    static const char suffix[] = ".dxil";
    size_t suffixLength = sizeof(suffix) - 1u;
    if (length <= suffixLength || length - suffixLength > AM12_MAX_ENTRY_NAME_BYTES ||
        strcmp(base + length - suffixLength, suffix) != 0)
        return 0;

    size_t nameLength = length - suffixLength;
    if (!(isalpha((unsigned char)base[0]) || base[0] == '_'))
        return 0;
    for (size_t index = 1; index < nameLength; index++)
        if (!(isalnum((unsigned char)base[index]) || base[index] == '_'))
            return 0;

    memcpy(shaderName, base, nameLength);
    shaderName[nameLength] = '\0';
    return 1;
}

static int AM12LoadRegularFile(const char *path, size_t maximumBytes, NSData *__autoreleasing *data)
{
    struct stat status;
    if (!data || !AM12PathIsBounded(path) || lstat(path, &status) != 0 ||
        !S_ISREG(status.st_mode) || status.st_size <= 0 || (uint64_t)status.st_size > maximumBytes)
        return 0;

    NSString *filePath = [NSString stringWithUTF8String:path];
    if (!filePath)
        return 0;
    NSError *error = nil;
    NSData *contents = [NSData dataWithContentsOfFile:filePath options:0 error:&error];
    if (!contents || contents.length != (NSUInteger)status.st_size)
        return 0;
    *data = contents;
    return 1;
}

static void AM12SHA256(NSData *data, uint8_t digest[CC_SHA256_DIGEST_LENGTH])
{
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
}

static void AM12HexDigest(const uint8_t digest[CC_SHA256_DIGEST_LENGTH],
                          char text[CC_SHA256_DIGEST_LENGTH * 2u + 1u])
{
    static const char digits[] = "0123456789abcdef";
    for (size_t index = 0; index < CC_SHA256_DIGEST_LENGTH; index++)
    {
        text[index * 2u] = digits[digest[index] >> 4u];
        text[index * 2u + 1u] = digits[digest[index] & 0x0fu];
    }
    text[CC_SHA256_DIGEST_LENGTH * 2u] = '\0';
}

static int AM12DataMatchesSHA256(NSData *data, const char *expected)
{
    if (!expected || strlen(expected) != CC_SHA256_DIGEST_LENGTH * 2u)
        return 0;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    char actual[CC_SHA256_DIGEST_LENGTH * 2u + 1u];
    AM12SHA256(data, digest);
    AM12HexDigest(digest, actual);
    return strcmp(actual, expected) == 0;
}

static uint32_t AM12ReadUInt32LE(const uint8_t *bytes)
{
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8u | (uint32_t)bytes[2] << 16u |
           (uint32_t)bytes[3] << 24u;
}

static int AM12ValidateDXILProgram(const uint8_t *program, size_t length)
{
    if (length < 28u)
        return 0;

    uint32_t programSizeWords = AM12ReadUInt32LE(program + 4u);
    uint32_t bitcodeOffset = AM12ReadUInt32LE(program + 16u);
    uint32_t bitcodeSize = AM12ReadUInt32LE(program + 20u);
    if ((uint64_t)programSizeWords * sizeof(uint32_t) != length ||
        memcmp(program + 8u, "DXIL", 4u) != 0 || bitcodeOffset < 16u ||
        bitcodeOffset % sizeof(uint32_t) != 0 || bitcodeSize < 4u)
        return 0;

    size_t bitcodeStart = 8u + (size_t)bitcodeOffset;
    return bitcodeStart <= length && bitcodeSize == length - bitcodeStart &&
           memcmp(program + bitcodeStart, "BC\xc0\xde", 4u) == 0;
}

static int AM12HexNibble(unichar character)
{
    if (character >= '0' && character <= '9')
        return character - '0';
    if (character >= 'a' && character <= 'f')
        return character - 'a' + 10;
    if (character >= 'A' && character <= 'F')
        return character - 'A' + 10;
    return -1;
}

static int AM12DisassemblyHash(NSData *disassembly, uint8_t digest[16])
{
    NSString *text = [[NSString alloc] initWithData:disassembly encoding:NSUTF8StringEncoding];
    if (!text)
        return 0;

    NSString *prefix = @"; shader hash: ";
    __block NSUInteger matchCount = 0;
    __block BOOL valid = YES;
    [text enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
      if (![line hasPrefix:prefix])
          return;
      matchCount++;
      NSString *value = [line substringFromIndex:prefix.length];
      if (value.length != 32u)
      {
          valid = NO;
          *stop = YES;
          return;
      }
      for (NSUInteger index = 0; index < 16u; index++)
      {
          int high = AM12HexNibble([value characterAtIndex:index * 2u]);
          int low = AM12HexNibble([value characterAtIndex:index * 2u + 1u]);
          if (high < 0 || low < 0)
          {
              valid = NO;
              *stop = YES;
              return;
          }
          digest[index] = (uint8_t)((uint32_t)high << 4u | (uint32_t)low);
      }
    }];
    return valid && matchCount == 1u;
}

static int AM12ContainerHash(NSData *container, uint8_t digest[16])
{
    const uint8_t *bytes = container.bytes;
    size_t length = container.length;
    if (length < 32u || length > UINT32_MAX || memcmp(bytes, "DXBC", 4u) != 0 ||
        AM12ReadUInt32LE(bytes + 20u) != 1u || AM12ReadUInt32LE(bytes + 24u) != length)
        return 0;

    uint32_t partCount = AM12ReadUInt32LE(bytes + 28u);
    if (!partCount || partCount > AM12_MAX_CONTAINER_PARTS ||
        partCount > (length - 32u) / sizeof(uint32_t))
        return 0;
    size_t tableEnd = 32u + (size_t)partCount * sizeof(uint32_t);
    struct
    {
        size_t start;
        size_t end;
    } ranges[AM12_MAX_CONTAINER_PARTS];

    uint32_t hashCount = 0;
    uint32_t dxilCount = 0;
    for (uint32_t part = 0; part < partCount; part++)
    {
        uint32_t offset = AM12ReadUInt32LE(bytes + 32u + (size_t)part * sizeof(uint32_t));
        if (offset % sizeof(uint32_t) != 0 || offset < tableEnd || offset > length - 8u)
            return 0;
        uint32_t partSize = AM12ReadUInt32LE(bytes + offset + 4u);
        if (partSize > length - offset - 8u)
            return 0;
        size_t partEnd = (size_t)offset + 8u + partSize;
        for (uint32_t prior = 0; prior < part; prior++)
            if (offset < ranges[prior].end && partEnd > ranges[prior].start)
                return 0;
        ranges[part].start = offset;
        ranges[part].end = partEnd;

        if (memcmp(bytes + offset, "HASH", 4u) == 0)
        {
            if (partSize != 20u || ++hashCount != 1u)
                return 0;
            memcpy(digest, bytes + offset + 12u, 16u);
        }
        else if (memcmp(bytes + offset, "DXIL", 4u) == 0)
        {
            if (++dxilCount != 1u || !AM12ValidateDXILProgram(bytes + offset + 8u, partSize))
                return 0;
        }
    }
    return hashCount == 1u && dxilCount == 1u;
}

static int AM12InputsAreBound(NSData *container, NSData *disassembly)
{
    uint8_t containerHash[16];
    uint8_t disassemblyHash[16];
    return AM12ContainerHash(container, containerHash) &&
           AM12DisassemblyHash(disassembly, disassemblyHash) &&
           memcmp(containerHash, disassemblyHash, sizeof(containerHash)) == 0;
}

static NSData *AM12PythonNormalizedUTF8Data(NSData *data)
{
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text || [text rangeOfString:@"\0"].location != NSNotFound)
        return nil;
    text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
    text = [text stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    return [text dataUsingEncoding:NSUTF8StringEncoding];
}

static int AM12WriteData(NSData *data, const char *path)
{
    NSString *filePath = [NSString stringWithUTF8String:path];
    if (!filePath)
        return 0;
    NSError *error = nil;
    return [data writeToFile:filePath options:NSDataWritingAtomic error:&error];
}

static void AM12CleanupStagingDirectory(const char *directory)
{
    DIR *entries = opendir(directory);
    if (entries)
    {
        struct dirent *entry;
        while ((entry = readdir(entries)))
        {
            if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
                continue;
            char path[AM12_MAX_PATH_BYTES + 1u];
            if (AM12JoinPath(path, directory, entry->d_name))
                unlink(path);
        }
        closedir(entries);
    }
    rmdir(directory);
}

static int AM12MonotonicMilliseconds(uint64_t *milliseconds)
{
    struct timespec time;
    if (!milliseconds || clock_gettime(CLOCK_MONOTONIC, &time) != 0)
        return 0;
    *milliseconds = (uint64_t)time.tv_sec * 1000u + (uint64_t)time.tv_nsec / 1000000u;
    return 1;
}

static void AM12KillAndReap(pid_t process)
{
    if (process <= 0)
        return;
    if (kill(process, SIGKILL) != 0 && errno != ESRCH)
        return;

    int status = 0;
    pid_t waited;
    do
        waited = waitpid(process, &status, 0);
    while (waited < 0 && errno == EINTR);
}

static int AM12PreserveStandardDescriptors(posix_spawn_file_actions_t *actions)
{
    for (int descriptor = STDIN_FILENO; descriptor <= STDERR_FILENO; descriptor++)
    {
        errno = 0;
        if (fcntl(descriptor, F_GETFD) < 0)
        {
            if (errno == EBADF)
                continue;
            return errno;
        }
        int result = posix_spawn_file_actions_adddup2(actions, descriptor, descriptor);
        if (result != 0)
            return result;
    }
    return 0;
}

static int AM12RunCanonicalLowerer(const char *lowererPath, const char *dxilPath,
                                   const char *disassemblyPath, const char *outputDirectory)
{
    char *const arguments[] = {
        (char *)AM12_CANONICAL_PYTHON_PATH,
        (char *)"-I",
        (char *)"-X",
        (char *)"utf8",
        (char *)lowererPath,
        (char *)dxilPath,
        (char *)disassemblyPath,
        (char *)outputDirectory,
        (char *)AM12CanonicalLowererSHA256,
        NULL,
    };
    char *const environment[] = {
        (char *)"PATH=/usr/bin:/bin",
        (char *)"PYTHONHASHSEED=0",
        (char *)"PYTHONNOUSERSITE=1",
        NULL,
    };

    posix_spawn_file_actions_t actions;
    int spawnResult = posix_spawn_file_actions_init(&actions);
    if (spawnResult != 0)
        return AM12LoweringFailure(strerror(spawnResult));
    spawnResult = AM12PreserveStandardDescriptors(&actions);
    if (spawnResult != 0)
    {
        posix_spawn_file_actions_destroy(&actions);
        return AM12LoweringFailure(strerror(spawnResult));
    }

    posix_spawnattr_t attributes;
    spawnResult = posix_spawnattr_init(&attributes);
    if (spawnResult != 0)
    {
        posix_spawn_file_actions_destroy(&actions);
        return AM12LoweringFailure(strerror(spawnResult));
    }
    spawnResult = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    if (spawnResult != 0)
    {
        posix_spawnattr_destroy(&attributes);
        posix_spawn_file_actions_destroy(&actions);
        return AM12LoweringFailure(strerror(spawnResult));
    }

    pid_t process = 0;
    spawnResult = posix_spawn(&process, AM12_CANONICAL_PYTHON_PATH, &actions, &attributes,
                              arguments, environment);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    if (spawnResult != 0)
        return AM12LoweringFailure(strerror(spawnResult));

    uint64_t started = 0;
    if (!AM12MonotonicMilliseconds(&started))
    {
        AM12KillAndReap(process);
        return AM12LoweringFailure("could not start the canonical lowerer deadline");
    }

    int status = 0;
    for (;;)
    {
        pid_t waited = waitpid(process, &status, WNOHANG);
        if (waited == process)
            break;
        if (waited < 0 && errno != EINTR)
        {
            int waitError = errno;
            AM12KillAndReap(process);
            return AM12LoweringFailure(strerror(waitError));
        }

        uint64_t current = 0;
        if (!AM12MonotonicMilliseconds(&current))
        {
            AM12KillAndReap(process);
            return AM12LoweringFailure("could not read the canonical lowerer deadline");
        }
        if (current - started >= AM12_LOWERER_TIMEOUT_MILLISECONDS)
        {
            AM12KillAndReap(process);
            return AM12LoweringFailure("canonical lowerer exceeded its wall-clock deadline");
        }

        struct timespec pause = {
            .tv_nsec = 10000000,
        };
        nanosleep(&pause, NULL);
    }
    if (!WIFEXITED(status))
        return AM12LoweringFailure("canonical lowerer terminated without an exit status");
    if (WEXITSTATUS(status) != 0)
        return AM12LoweringFailure("canonical lowerer rejected the shader");
    return 1;
}

static NSString *AM12ExpectedHash(NSData *data)
{
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    char text[CC_SHA256_DIGEST_LENGTH * 2u + 1u];
    AM12SHA256(data, digest);
    AM12HexDigest(digest, text);
    return [NSString stringWithUTF8String:text];
}

static int AM12ValidateStringField(NSDictionary *record, NSString *field, NSString *expected)
{
    id value = record[field];
    return [value isKindOfClass:[NSString class]] && [value isEqualToString:expected];
}

static int AM12ValidateMSL(NSData *mslData, NSString *shaderName, NSString *stage)
{
    if (!mslData.length || mslData.length > AM12_MAX_MSL_BYTES ||
        memchr(mslData.bytes, '\0', mslData.length))
        return 0;
    NSString *msl = [[NSString alloc] initWithData:mslData encoding:NSUTF8StringEncoding];
    if (!msl || ![msl hasPrefix:@"#include <metal_stdlib>\nusing namespace metal;\n"])
        return 0;

    NSString *entry = [NSString stringWithFormat:@" %@(", shaderName];
    if ([stage isEqualToString:@"compute"])
        return [msl containsString:[NSString stringWithFormat:@"kernel void %@(", shaderName]];
    if ([stage isEqualToString:@"vertex"])
        return [msl containsString:@"\nvertex "] && [msl containsString:entry];
    if ([stage isEqualToString:@"fragment"])
        return [msl containsString:@"\nfragment "] && [msl containsString:entry];
    return 0;
}

static int AM12ValidateProvenance(NSData *provenanceData, NSData *container,
                                  NSData *normalizedDisassembly, NSData *mslData,
                                  NSString *shaderName, NSString *__autoreleasing *stage,
                                  BOOL *hasExternalFeatures)
{
    if (!provenanceData.length || provenanceData.length > AM12_MAX_PROVENANCE_BYTES)
        return 0;
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:provenanceData options:0 error:&error];
    if (![object isKindOfClass:[NSDictionary class]])
        return 0;
    NSDictionary *record = object;

    NSString *recordStage = record[@"stage"];
    NSArray *allowedStages = @[ @"compute", @"vertex", @"fragment" ];
    NSString *model = record[@"model"];
    NSNumber *operations = record[@"ops"];
    NSArray *features = record[@"features"];
    NSArray *resources = record[@"resources"];
    if (![recordStage isKindOfClass:[NSString class]] ||
        ![allowedStages containsObject:recordStage] || ![model isKindOfClass:[NSString class]] ||
        ![operations isKindOfClass:[NSNumber class]] || ![features isKindOfClass:[NSArray class]] ||
        ![resources isKindOfClass:[NSArray class]] ||
        operations.unsignedLongLongValue > AM12_MAX_SHADER_OPS ||
        resources.count > AM12_MAX_RESOURCES)
        return 0;

    NSDictionary<NSString *, NSString *> *prefixes = @{
        @"compute" : @"cs_",
        @"vertex" : @"vs_",
        @"fragment" : @"ps_",
    };
    if (![model hasPrefix:prefixes[recordStage]] ||
        !AM12ValidateStringField(record, @"shader", shaderName) ||
        !AM12ValidateStringField(record, @"container_sha256", AM12ExpectedHash(container)) ||
        !AM12ValidateStringField(record, @"ll_sha256", AM12ExpectedHash(normalizedDisassembly)) ||
        !AM12ValidateStringField(record, @"msl_sha256", AM12ExpectedHash(mslData)) ||
        !AM12ValidateStringField(record, @"lowerer_sha256",
                                 [NSString stringWithUTF8String:AM12CanonicalLowererSHA256]))
        return 0;

    *stage = recordStage;
    *hasExternalFeatures = features.count > 0;
    return 1;
}

static int AM12ParseFixtureName(const char *fileName, const char *shaderName, uint32_t *index,
                                BOOL *reference)
{
    size_t shaderLength = strlen(shaderName);
    if (strncmp(fileName, shaderName, shaderLength) != 0 || fileName[shaderLength] != '.' ||
        fileName[shaderLength + 1u] != 'u')
        return 0;

    const char *cursor = fileName + shaderLength + 2u;
    if (!isdigit((unsigned char)*cursor))
        return 0;
    uint64_t value = 0;
    do
    {
        value = value * 10u + (uint64_t)(*cursor - '0');
        if (value >= AM12_MAX_RESOURCES)
            return 0;
        cursor++;
    } while (isdigit((unsigned char)*cursor));

    if (strcmp(cursor, ".in.bin") == 0)
        *reference = NO;
    else if (strcmp(cursor, ".ref.bin") == 0)
        *reference = YES;
    else
        return 0;
    *index = (uint32_t)value;
    return 1;
}

static int AM12CollectArtifacts(const char *stagingDirectory, const char *shaderName,
                                AM12LoweringArtifacts *artifacts)
{
    *artifacts = (AM12LoweringArtifacts){
        .publish_names = [NSMutableArray array],
    };

    char metalName[AM12_MAX_ENTRY_NAME_BYTES + 32u];
    char provenanceName[AM12_MAX_ENTRY_NAME_BYTES + 32u];
    snprintf(metalName, sizeof(metalName), "%s.metal", shaderName);
    snprintf(provenanceName, sizeof(provenanceName), "%s.provenance.json", shaderName);

    DIR *directory = opendir(stagingDirectory);
    if (!directory)
        return 0;

    int valid = 1;
    struct dirent *entry;
    while (valid)
    {
        errno = 0;
        entry = readdir(directory);
        if (!entry)
        {
            if (errno != 0)
                valid = 0;
            break;
        }
        const char *name = entry->d_name;
        if (strcmp(name, ".") == 0 || strcmp(name, "..") == 0 ||
            strcmp(name, ".am12-canonical-lowerer.py") == 0)
            continue;

        size_t nameLength = strlen(name);
        size_t shaderLength = strlen(shaderName);
        if ((nameLength == shaderLength + 5u && strcmp(name + shaderLength, ".dxil") == 0) ||
            (nameLength == shaderLength + 3u && strcmp(name + shaderLength, ".ll") == 0))
            continue;

        char path[AM12_MAX_PATH_BYTES + 1u];
        struct stat status;
        if (!AM12JoinPath(path, stagingDirectory, name) || lstat(path, &status) != 0 ||
            !S_ISREG(status.st_mode) || status.st_size <= 0)
        {
            valid = 0;
            break;
        }

        if (strcmp(name, metalName) == 0)
        {
            artifacts->metal = YES;
            valid = (uint64_t)status.st_size <= AM12_MAX_MSL_BYTES;
        }
        else if (strcmp(name, provenanceName) == 0)
        {
            artifacts->provenance = YES;
            valid = (uint64_t)status.st_size <= AM12_MAX_PROVENANCE_BYTES;
        }
        else
        {
            uint32_t fixtureIndex = 0;
            BOOL reference = NO;
            if (!AM12ParseFixtureName(name, shaderName, &fixtureIndex, &reference) ||
                status.st_size != AM12_COMPUTE_FIXTURE_BYTES)
            {
                valid = 0;
                break;
            }
            if (reference)
                artifacts->references[fixtureIndex] = YES;
            else
                artifacts->inputs[fixtureIndex] = YES;
        }
        [artifacts->publish_names addObject:[NSString stringWithUTF8String:name]];
    }
    closedir(directory);
    return valid && artifacts->metal && artifacts->provenance;
}

static int AM12ValidateFixtureInventory(const AM12LoweringArtifacts *artifacts, NSString *stage,
                                        BOOL hasExternalFeatures)
{
    if (![stage isEqualToString:@"compute"])
    {
        for (uint32_t index = 0; index < AM12_MAX_RESOURCES; index++)
            if (artifacts->inputs[index] || artifacts->references[index])
                return 0;
        return 1;
    }

    if (!artifacts->inputs[0])
        return 0;
    BOOL gap = NO;
    for (uint32_t index = 0; index < AM12_MAX_RESOURCES; index++)
    {
        if (!artifacts->inputs[index])
            gap = YES;
        else if (gap)
            return 0;
        if (hasExternalFeatures ? artifacts->references[index]
                                : artifacts->references[index] != artifacts->inputs[index])
            return 0;
    }
    return 1;
}

static int AM12IsPublishedArtifactName(const char *name, const char *shaderName)
{
    char metalName[AM12_MAX_ENTRY_NAME_BYTES + 32u];
    char provenanceName[AM12_MAX_ENTRY_NAME_BYTES + 32u];
    snprintf(metalName, sizeof(metalName), "%s.metal", shaderName);
    snprintf(provenanceName, sizeof(provenanceName), "%s.provenance.json", shaderName);

    uint32_t fixtureIndex = 0;
    BOOL reference = NO;
    return strcmp(name, metalName) == 0 || strcmp(name, provenanceName) == 0 ||
           AM12ParseFixtureName(name, shaderName, &fixtureIndex, &reference);
}

static int AM12CollectPublishedArtifacts(const char *directoryPath, const char *shaderName,
                                         NSMutableArray<NSString *> **names)
{
    if (!names)
        return 0;
    *names = [NSMutableArray array];

    DIR *directory = opendir(directoryPath);
    if (!directory)
        return 0;
    int valid = 1;
    struct dirent *entry;
    while (valid)
    {
        errno = 0;
        entry = readdir(directory);
        if (!entry)
        {
            if (errno != 0)
                valid = 0;
            break;
        }
        const char *name = entry->d_name;
        if (!AM12IsPublishedArtifactName(name, shaderName))
            continue;

        char path[AM12_MAX_PATH_BYTES + 1u];
        struct stat status;
        NSString *publishedName = [NSString stringWithUTF8String:name];
        if (!AM12JoinPath(path, directoryPath, name) || lstat(path, &status) != 0 ||
            !S_ISREG(status.st_mode) || !publishedName)
            valid = 0;
        else
            [*names addObject:publishedName];
    }
    closedir(directory);
    return valid;
}

static int AM12PublicationPath(char path[AM12_MAX_PATH_BYTES + 1u], const char *outputDirectory,
                               const char *shaderName, const char *phase)
{
    char name[AM12_MAX_ENTRY_NAME_BYTES + 48u];
    int written = snprintf(name, sizeof(name), ".am12-publish-%s.%s", shaderName, phase);
    return written > 0 && (size_t)written < sizeof(name) &&
           AM12JoinPath(path, outputDirectory, name);
}

static int AM12DirectoryPresence(const char *path, int *present)
{
    struct stat status;
    if (!present)
        return 0;
    if (lstat(path, &status) == 0)
    {
        *present = 1;
        return S_ISDIR(status.st_mode);
    }
    if (errno != ENOENT)
        return 0;
    *present = 0;
    return 1;
}

static int AM12FilesAreIdentical(const char *first, const char *second)
{
    struct stat firstStatus;
    struct stat secondStatus;
    return lstat(first, &firstStatus) == 0 && lstat(second, &secondStatus) == 0 &&
           S_ISREG(firstStatus.st_mode) && S_ISREG(secondStatus.st_mode) &&
           firstStatus.st_dev == secondStatus.st_dev && firstStatus.st_ino == secondStatus.st_ino;
}

static int AM12LinkOrVerify(const char *source, const char *destination)
{
    if (link(source, destination) == 0)
        return 1;
    return errno == EEXIST && AM12FilesAreIdentical(source, destination);
}

static int AM12RestorePriorArtifacts(const char *phaseDirectory, const char *outputDirectory,
                                     const char *shaderName)
{
    char priorDirectory[AM12_MAX_PATH_BYTES + 1u];
    if (!AM12JoinPath(priorDirectory, phaseDirectory, "old"))
        return 0;
    int present = 0;
    if (!AM12DirectoryPresence(priorDirectory, &present))
        return 0;
    if (!present)
        return 1;

    NSMutableArray<NSString *> *priorNames = nil;
    if (!AM12CollectPublishedArtifacts(priorDirectory, shaderName, &priorNames))
        return 0;
    NSArray<NSString *> *sortedNames = [priorNames sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in sortedNames)
    {
        char source[AM12_MAX_PATH_BYTES + 1u];
        char destination[AM12_MAX_PATH_BYTES + 1u];
        if (!AM12JoinPath(source, priorDirectory, name.UTF8String) ||
            !AM12JoinPath(destination, outputDirectory, name.UTF8String) ||
            !AM12LinkOrVerify(source, destination))
            return 0;
    }
    for (NSString *name in sortedNames)
    {
        char source[AM12_MAX_PATH_BYTES + 1u];
        if (!AM12JoinPath(source, priorDirectory, name.UTF8String) ||
            (unlink(source) != 0 && errno != ENOENT))
            return 0;
    }
    return rmdir(priorDirectory) == 0 || errno == ENOENT;
}

static int AM12RemoveInstalledArtifacts(const char *phaseDirectory, const char *outputDirectory,
                                        const char *shaderName)
{
    NSMutableArray<NSString *> *newNames = nil;
    if (!AM12CollectPublishedArtifacts(phaseDirectory, shaderName, &newNames))
        return 0;
    for (NSString *name in newNames)
    {
        char source[AM12_MAX_PATH_BYTES + 1u];
        char destination[AM12_MAX_PATH_BYTES + 1u];
        if (!AM12JoinPath(source, phaseDirectory, name.UTF8String) ||
            !AM12JoinPath(destination, outputDirectory, name.UTF8String))
            return 0;

        struct stat status;
        if (lstat(destination, &status) != 0)
        {
            if (errno == ENOENT)
                continue;
            return 0;
        }
        if (!AM12FilesAreIdentical(source, destination) || unlink(destination) != 0)
            return 0;
    }
    return 1;
}

static int AM12CleanupPublicationTree(const char *phaseDirectory, const char *shaderName)
{
    char priorDirectory[AM12_MAX_PATH_BYTES + 1u];
    if (!AM12JoinPath(priorDirectory, phaseDirectory, "old"))
        return 0;
    int priorPresent = 0;
    if (!AM12DirectoryPresence(priorDirectory, &priorPresent))
        return 0;
    if (priorPresent)
    {
        NSMutableArray<NSString *> *priorNames = nil;
        if (!AM12CollectPublishedArtifacts(priorDirectory, shaderName, &priorNames))
            return 0;
        for (NSString *name in priorNames)
        {
            char path[AM12_MAX_PATH_BYTES + 1u];
            if (!AM12JoinPath(path, priorDirectory, name.UTF8String) ||
                (unlink(path) != 0 && errno != ENOENT))
                return 0;
        }
        if (rmdir(priorDirectory) != 0 && errno != ENOENT)
            return 0;
    }

    DIR *directory = opendir(phaseDirectory);
    if (!directory)
        return errno == ENOENT;
    int cleaned = 1;
    struct dirent *entry;
    while (cleaned)
    {
        errno = 0;
        entry = readdir(directory);
        if (!entry)
        {
            if (errno != 0)
                cleaned = 0;
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;
        char path[AM12_MAX_PATH_BYTES + 1u];
        struct stat status;
        if (!AM12JoinPath(path, phaseDirectory, entry->d_name) || lstat(path, &status) != 0 ||
            (!S_ISREG(status.st_mode) && !S_ISLNK(status.st_mode)) || unlink(path) != 0)
            cleaned = 0;
    }
    closedir(directory);
    return cleaned && (rmdir(phaseDirectory) == 0 || errno == ENOENT);
}

static int AM12RecoverPublication(const char *outputDirectory, const char *shaderName)
{
    static const char *phases[] = {"backing", "installing", "committed"};
    char paths[3][AM12_MAX_PATH_BYTES + 1u];
    int present[3] = {0};
    uint32_t presentCount = 0;
    for (uint32_t index = 0; index < 3u; index++)
    {
        if (!AM12PublicationPath(paths[index], outputDirectory, shaderName, phases[index]) ||
            !AM12DirectoryPresence(paths[index], &present[index]))
            return 0;
        presentCount += (uint32_t)present[index];
    }
    if (presentCount > 1u)
        return 0;
    if (!presentCount)
        return 1;

    if (present[0])
    {
        if (!AM12RestorePriorArtifacts(paths[0], outputDirectory, shaderName))
            return 0;
        return AM12CleanupPublicationTree(paths[0], shaderName);
    }
    if (present[1])
    {
        if (!AM12RemoveInstalledArtifacts(paths[1], outputDirectory, shaderName) ||
            rename(paths[1], paths[0]) != 0 ||
            !AM12RestorePriorArtifacts(paths[0], outputDirectory, shaderName))
            return 0;
        return AM12CleanupPublicationTree(paths[0], shaderName);
    }
    return AM12CleanupPublicationTree(paths[2], shaderName);
}

static int AM12VisibleInventoryMatches(const char *outputDirectory, const char *shaderName,
                                       NSArray<NSString *> *expectedNames)
{
    NSMutableArray<NSString *> *visibleNames = nil;
    if (!AM12CollectPublishedArtifacts(outputDirectory, shaderName, &visibleNames) ||
        visibleNames.count != expectedNames.count)
        return 0;
    NSSet<NSString *> *visible = [NSSet setWithArray:visibleNames];
    NSSet<NSString *> *expected = [NSSet setWithArray:expectedNames];
    return [visible isEqualToSet:expected];
}

static int AM12PublishArtifactsLocked(const char *stagingDirectory, const char *outputDirectory,
                                      const char *shaderName, AM12LoweringArtifacts *artifacts)
{
    char backingDirectory[AM12_MAX_PATH_BYTES + 1u];
    char installingDirectory[AM12_MAX_PATH_BYTES + 1u];
    char committedDirectory[AM12_MAX_PATH_BYTES + 1u];
    if (!AM12PublicationPath(backingDirectory, outputDirectory, shaderName, "backing") ||
        !AM12PublicationPath(installingDirectory, outputDirectory, shaderName, "installing") ||
        !AM12PublicationPath(committedDirectory, outputDirectory, shaderName, "committed") ||
        rename(stagingDirectory, backingDirectory) != 0)
        return 0;

    char priorDirectory[AM12_MAX_PATH_BYTES + 1u];
    NSMutableArray<NSString *> *priorNames = nil;
    if (!AM12JoinPath(priorDirectory, backingDirectory, "old") ||
        mkdir(priorDirectory, 0700) != 0 ||
        !AM12CollectPublishedArtifacts(outputDirectory, shaderName, &priorNames))
    {
        AM12RecoverPublication(outputDirectory, shaderName);
        return 0;
    }

    NSArray<NSString *> *sortedPriorNames =
        [priorNames sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in sortedPriorNames)
    {
        char source[AM12_MAX_PATH_BYTES + 1u];
        char destination[AM12_MAX_PATH_BYTES + 1u];
        if (!AM12JoinPath(source, outputDirectory, name.UTF8String) ||
            !AM12JoinPath(destination, priorDirectory, name.UTF8String) ||
            rename(source, destination) != 0)
        {
            AM12RecoverPublication(outputDirectory, shaderName);
            return 0;
        }
    }

    if (rename(backingDirectory, installingDirectory) != 0)
    {
        AM12RecoverPublication(outputDirectory, shaderName);
        return 0;
    }

    NSArray<NSString *> *newNames =
        [artifacts->publish_names sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in newNames)
    {
        char source[AM12_MAX_PATH_BYTES + 1u];
        char destination[AM12_MAX_PATH_BYTES + 1u];
        if (!AM12JoinPath(source, installingDirectory, name.UTF8String) ||
            !AM12JoinPath(destination, outputDirectory, name.UTF8String) ||
            !AM12LinkOrVerify(source, destination))
        {
            AM12RecoverPublication(outputDirectory, shaderName);
            return 0;
        }
    }
    if (!AM12VisibleInventoryMatches(outputDirectory, shaderName, newNames) ||
        rename(installingDirectory, committedDirectory) != 0)
    {
        AM12RecoverPublication(outputDirectory, shaderName);
        return 0;
    }

    if (!AM12CleanupPublicationTree(committedDirectory, shaderName))
        fprintf(stderr, "AM12 lowering warning: committed artifact cleanup was deferred\n");
    return 1;
}

static pthread_mutex_t AM12PublicationMutex = PTHREAD_MUTEX_INITIALIZER;

static int AM12PublishArtifacts(const char *stagingDirectory, const char *outputDirectory,
                                const char *shaderName, AM12LoweringArtifacts *artifacts)
{
    if (pthread_mutex_lock(&AM12PublicationMutex) != 0)
        return 0;

    char lockName[AM12_MAX_ENTRY_NAME_BYTES + 32u];
    char lockPath[AM12_MAX_PATH_BYTES + 1u];
    snprintf(lockName, sizeof(lockName), ".am12-publish-%s.lock", shaderName);
    int published = 0;
    int lockDescriptor = -1;
    if (AM12JoinPath(lockPath, outputDirectory, lockName))
        lockDescriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, (mode_t)0600);
    if (lockDescriptor >= 0)
    {
        int lockResult;
        do
            lockResult = flock(lockDescriptor, LOCK_EX);
        while (lockResult != 0 && errno == EINTR);
        if (lockResult == 0)
        {
            if (AM12RecoverPublication(outputDirectory, shaderName))
                published = AM12PublishArtifactsLocked(stagingDirectory, outputDirectory,
                                                       shaderName, artifacts);
            flock(lockDescriptor, LOCK_UN);
        }
        close(lockDescriptor);
    }
    pthread_mutex_unlock(&AM12PublicationMutex);
    return published;
}

int AM12LowerDXILToMSL(const AM12ShaderLoweringRequest *request)
{
    @autoreleasepool
    {
        if (!request || !AM12PathHasMode(request->dxil_path, S_IFREG) ||
            !AM12PathHasMode(request->disassembly_path, S_IFREG) ||
            !AM12PathHasMode(request->output_directory, S_IFDIR) ||
            !AM12PathHasMode(AM12_CANONICAL_PYTHON_PATH, S_IFREG) ||
            access(AM12_CANONICAL_PYTHON_PATH, X_OK) != 0)
            return AM12LoweringFailure("invalid input, output, or canonical interpreter path");

        char shaderName[AM12_MAX_ENTRY_NAME_BYTES + 1u];
        if (!AM12ExtractShaderName(request->dxil_path, shaderName))
            return AM12LoweringFailure("DXIL filename must be a bounded shader identifier");

        NSData *container = nil;
        NSData *disassembly = nil;
        NSData *lowerer = [NSData dataWithBytes:AM12CanonicalLowererBytes
                                         length:sizeof(AM12CanonicalLowererBytes)];
        if (!AM12LoadRegularFile(request->dxil_path, AM12_MAX_SHADER_INPUT_BYTES, &container) ||
            !AM12LoadRegularFile(request->disassembly_path, AM12_MAX_SHADER_INPUT_BYTES,
                                 &disassembly))
            return AM12LoweringFailure("could not read a bounded regular lowering input");
        if (!lowerer || lowerer.length > AM12_MAX_LOWERER_BYTES ||
            !AM12DataMatchesSHA256(lowerer, AM12CanonicalLowererSHA256))
            return AM12LoweringFailure("canonical lowerer does not match its build-time hash");
        if (!AM12InputsAreBound(container, disassembly))
            return AM12LoweringFailure("DXIL and disassembly shader hashes do not match");

        NSData *normalizedDisassembly = AM12PythonNormalizedUTF8Data(disassembly);
        if (!normalizedDisassembly)
            return AM12LoweringFailure("disassembly is not bounded UTF-8 text");

        char stagingTemplate[AM12_MAX_PATH_BYTES + 1u];
        if (!AM12JoinPath(stagingTemplate, request->output_directory, ".am12-lowering-XXXXXX") ||
            !mkdtemp(stagingTemplate))
            return AM12LoweringFailure("could not create isolated artifact staging");

        int success = 0;
        do
        {
            char stagedLowerer[AM12_MAX_PATH_BYTES + 1u];
            char dxilName[AM12_MAX_ENTRY_NAME_BYTES + 16u];
            char disassemblyName[AM12_MAX_ENTRY_NAME_BYTES + 16u];
            char stagedDXIL[AM12_MAX_PATH_BYTES + 1u];
            char stagedDisassembly[AM12_MAX_PATH_BYTES + 1u];
            snprintf(dxilName, sizeof(dxilName), "%s.dxil", shaderName);
            snprintf(disassemblyName, sizeof(disassemblyName), "%s.ll", shaderName);
            if (!AM12JoinPath(stagedLowerer, stagingTemplate, ".am12-canonical-lowerer.py") ||
                !AM12JoinPath(stagedDXIL, stagingTemplate, dxilName) ||
                !AM12JoinPath(stagedDisassembly, stagingTemplate, disassemblyName) ||
                !AM12WriteData(lowerer, stagedLowerer) || !AM12WriteData(container, stagedDXIL) ||
                !AM12WriteData(disassembly, stagedDisassembly))
            {
                AM12LoweringFailure("could not stage immutable lowering inputs");
                break;
            }
            if (!AM12RunCanonicalLowerer(stagedLowerer, stagedDXIL, stagedDisassembly,
                                         stagingTemplate))
                break;

            char metalName[AM12_MAX_ENTRY_NAME_BYTES + 32u];
            char provenanceName[AM12_MAX_ENTRY_NAME_BYTES + 32u];
            char metalPath[AM12_MAX_PATH_BYTES + 1u];
            char provenancePath[AM12_MAX_PATH_BYTES + 1u];
            snprintf(metalName, sizeof(metalName), "%s.metal", shaderName);
            snprintf(provenanceName, sizeof(provenanceName), "%s.provenance.json", shaderName);
            NSData *msl = nil;
            NSData *provenance = nil;
            if (!AM12JoinPath(metalPath, stagingTemplate, metalName) ||
                !AM12JoinPath(provenancePath, stagingTemplate, provenanceName) ||
                !AM12LoadRegularFile(metalPath, AM12_MAX_MSL_BYTES, &msl) ||
                !AM12LoadRegularFile(provenancePath, AM12_MAX_PROVENANCE_BYTES, &provenance))
            {
                AM12LoweringFailure("canonical lowerer emitted incomplete artifacts");
                break;
            }

            NSString *stage = nil;
            BOOL hasExternalFeatures = NO;
            NSString *shader = [NSString stringWithUTF8String:shaderName];
            AM12LoweringArtifacts artifacts;
            if (!AM12ValidateProvenance(provenance, container, normalizedDisassembly, msl, shader,
                                        &stage, &hasExternalFeatures) ||
                !AM12ValidateMSL(msl, shader, stage) ||
                !AM12CollectArtifacts(stagingTemplate, shaderName, &artifacts) ||
                !AM12ValidateFixtureInventory(&artifacts, stage, hasExternalFeatures))
            {
                AM12LoweringFailure("canonical lowerer emitted invalid or unbound artifacts");
                break;
            }
            if (!AM12PublishArtifacts(stagingTemplate, request->output_directory, shaderName,
                                      &artifacts))
            {
                AM12LoweringFailure("could not publish validated lowering artifacts");
                break;
            }
            success = 1;
        } while (0);

        AM12CleanupStagingDirectory(stagingTemplate);
        return success;
    }
}
