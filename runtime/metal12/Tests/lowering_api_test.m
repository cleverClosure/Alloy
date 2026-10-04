/*
 * Metal12 public lowering API validation test.
 * Author: Timur Isaev
 */

#import <Foundation/Foundation.h>

#import "../include/AlloyMetal12.h"

#include <fcntl.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static void AM12WriteUInt32LE(uint8_t *destination, uint32_t value)
{
    destination[0] = (uint8_t)value;
    destination[1] = (uint8_t)(value >> 8u);
    destination[2] = (uint8_t)(value >> 16u);
    destination[3] = (uint8_t)(value >> 24u);
}

static int AM12WriteFile(const char *path, const void *bytes, size_t length)
{
    int descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (descriptor < 0)
        return 0;

    const uint8_t *cursor = bytes;
    size_t remaining = length;
    while (remaining)
    {
        ssize_t written = write(descriptor, cursor, remaining);
        if (written <= 0)
        {
            close(descriptor);
            return 0;
        }
        cursor += (size_t)written;
        remaining -= (size_t)written;
    }
    return close(descriptor) == 0;
}

static int AM12CreateDXILFixture(const char *path, const uint8_t shaderHash[16])
{
    uint8_t container[104] = {0};
    memcpy(container, "DXBC", 4u);
    AM12WriteUInt32LE(container + 20u, 1u);
    AM12WriteUInt32LE(container + 24u, sizeof(container));
    AM12WriteUInt32LE(container + 28u, 2u);
    AM12WriteUInt32LE(container + 32u, 40u);
    AM12WriteUInt32LE(container + 36u, 68u);

    memcpy(container + 40u, "HASH", 4u);
    AM12WriteUInt32LE(container + 44u, 20u);
    memcpy(container + 52u, shaderHash, 16u);

    memcpy(container + 68u, "DXIL", 4u);
    AM12WriteUInt32LE(container + 72u, 28u);
    AM12WriteUInt32LE(container + 76u, 0x00010060u);
    AM12WriteUInt32LE(container + 80u, 7u);
    memcpy(container + 84u, "DXIL", 4u);
    AM12WriteUInt32LE(container + 88u, 0x00000100u);
    AM12WriteUInt32LE(container + 92u, 16u);
    AM12WriteUInt32LE(container + 96u, 4u);
    static const uint8_t bitcodeMagic[4] = {0x42u, 0x43u, 0xc0u, 0xdeu};
    memcpy(container + 100u, bitcodeMagic, sizeof(bitcodeMagic));
    return AM12WriteFile(path, container, sizeof(container));
}

static int AM12CreateOversizedPartCountDXILFixture(const char *path)
{
    uint8_t container[32] = {0};
    memcpy(container, "DXBC", 4u);
    AM12WriteUInt32LE(container + 20u, 1u);
    AM12WriteUInt32LE(container + 24u, sizeof(container));
    AM12WriteUInt32LE(container + 28u, 65u);
    return AM12WriteFile(path, container, sizeof(container));
}

static NSString *AM12HashText(const uint8_t shaderHash[16])
{
    static const char digits[] = "0123456789abcdef";
    char text[33];
    for (size_t index = 0; index < 16u; index++)
    {
        text[index * 2u] = digits[shaderHash[index] >> 4u];
        text[index * 2u + 1u] = digits[shaderHash[index] & 0x0fu];
    }
    text[32] = '\0';
    return [NSString stringWithUTF8String:text];
}

static int AM12CreateDisassemblyFixture(const char *path, const uint8_t shaderHash[16])
{
    NSMutableString *text =
        [NSMutableString stringWithFormat:@"; shader hash: %@\n", AM12HashText(shaderHash)];
    [text appendString:@";PSVRuntimeInfo:\n"
                        "; Compute Shader\n"
                        "\n"
                        "define void @main() {\n"
                        "  %1 = call %dx.types.Handle @dx.op.createHandle(i32 57, i8 1, "
                        "i32 0, i32 0, i1 false)\n"
                        "  %2 = call i32 @dx.op.threadId.i32(i32 93, i32 0)\n"
                        "  call void @dx.op.bufferStore.f32(i32 69, %dx.types.Handle %1, "
                        "i32 %2, i32 0, float 1.000000e+00, float undef, float undef, "
                        "float undef, i8 1)\n"
                        "  ret void\n"
                        "}\n"];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    return AM12WriteFile(path, data.bytes, data.length);
}

static int AM12CreateUnsupportedGraphicsDisassemblyFixture(const char *path,
                                                           const uint8_t shaderHash[16])
{
    NSMutableString *text =
        [NSMutableString stringWithFormat:@"; shader hash: %@\n", AM12HashText(shaderHash)];
    [text appendString:@";PSVRuntimeInfo:\n"
                        "; Vertex Shader\n"
                        "\n"
                        "define void @main() {\n"
                        "  %1 = call %dx.types.Handle @dx.op.createHandle(i32 57, i8 2, "
                        "i32 1, i32 0, i1 false)\n"
                        "  ret void\n"
                        "}\n"];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    return AM12WriteFile(path, data.bytes, data.length);
}

static int AM12CreateOversizedResourceDisassemblyFixture(const char *path,
                                                         const uint8_t shaderHash[16])
{
    NSMutableString *text =
        [NSMutableString stringWithFormat:@"; shader hash: %@\n", AM12HashText(shaderHash)];
    [text appendString:@";PSVRuntimeInfo:\n"
                        "; Compute Shader\n"
                        "\n"
                        "define void @main() {\n"
                        "  %1 = call %dx.types.Handle @dx.op.createHandle(i32 57, i8 1, "
                        "i32 64, i32 0, i1 false)\n"
                        "  ret void\n"
                        "}\n"];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    return AM12WriteFile(path, data.bytes, data.length);
}

static int AM12CreateOversizedOperationDisassemblyFixture(const char *path,
                                                          const uint8_t shaderHash[16])
{
    NSMutableString *text =
        [NSMutableString stringWithFormat:@"; shader hash: %@\n", AM12HashText(shaderHash)];
    [text appendString:@";PSVRuntimeInfo:\n"
                        "; Compute Shader\n"
                        "\n"
                        "define void @main() {\n"];
    for (uint32_t index = 0; index <= 16384u; index++)
        [text appendFormat:@"  %%%u = call i32 @dx.op.threadId.i32(i32 93, i32 0)\n", index + 1u];
    [text appendString:@"  ret void\n}\n"];
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    return AM12WriteFile(path, data.bytes, data.length);
}

static int AM12JoinPath(char result[AM12_MAX_PATH_BYTES + 1u], const char *directory,
                        const char *name)
{
    int written = snprintf(result, AM12_MAX_PATH_BYTES + 1u, "%s/%s", directory, name);
    return written > 0 && (size_t)written <= AM12_MAX_PATH_BYTES;
}

static int AM12LegacyTrueBypassIsRejected(const char *testExecutable, const char *dxilPath,
                                          const char *disassemblyPath, const char *outputDirectory)
{
    char resolved[AM12_MAX_PATH_BYTES + 1u];
    if (!realpath(testExecutable, resolved))
        return 0;
    char *separator = strrchr(resolved, '/');
    if (!separator)
        return 0;
    strcpy(separator + 1, "metal12_lower");
    if (access(resolved, X_OK) != 0)
        return 0;

    char *const arguments[] = {
        resolved,
        (char *)"/usr/bin/true",
        (char *)"/usr/bin/true",
        (char *)dxilPath,
        (char *)disassemblyPath,
        (char *)outputDirectory,
        NULL,
    };
    pid_t process = 0;
    if (posix_spawn(&process, resolved, NULL, NULL, arguments, environ) != 0)
        return 0;
    int status = 0;
    if (waitpid(process, &status, 0) != process)
        return 0;
    return WIFEXITED(status) && WEXITSTATUS(status) != 0;
}

static int AM12OutputContains(const char *path, NSString *needle)
{
    NSString *filePath = [NSString stringWithUTF8String:path];
    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfFile:filePath
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];
    return contents && [contents containsString:needle];
}

static int AM12ProvenanceHasPinnedLowerer(const char *path)
{
    NSString *filePath = [NSString stringWithUTF8String:path];
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data)
        return 0;
    NSError *error = nil;
    NSDictionary *record = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    NSString *hash = [record isKindOfClass:[NSDictionary class]] ? record[@"lowerer_sha256"] : nil;
    if (![hash isKindOfClass:[NSString class]] || hash.length != 64u)
        return 0;
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    return [hash rangeOfCharacterFromSet:hex.invertedSet].location == NSNotFound;
}

static int AM12CreateInterruptedPublicationFixture(const char *outputDirectory,
                                                   const char *phaseDirectory)
{
    static const char *artifactNames[] = {
        "positive.metal",
        "positive.provenance.json",
        "positive.u0.in.bin",
        "positive.u0.ref.bin",
    };
    char priorDirectory[AM12_MAX_PATH_BYTES + 1u];
    if (mkdir(phaseDirectory, 0700) != 0 || !AM12JoinPath(priorDirectory, phaseDirectory, "old") ||
        mkdir(priorDirectory, 0700) != 0)
        return 0;

    for (size_t index = 0; index < sizeof(artifactNames) / sizeof(artifactNames[0]); index++)
    {
        char visible[AM12_MAX_PATH_BYTES + 1u];
        char prior[AM12_MAX_PATH_BYTES + 1u];
        char staged[AM12_MAX_PATH_BYTES + 1u];
        const char *name = artifactNames[index];
        if (!AM12JoinPath(visible, outputDirectory, name) ||
            !AM12JoinPath(prior, priorDirectory, name) ||
            !AM12JoinPath(staged, phaseDirectory, name) || rename(visible, prior) != 0 ||
            link(prior, staged) != 0)
            return 0;
    }

    char stagedMetal[AM12_MAX_PATH_BYTES + 1u];
    char visibleMetal[AM12_MAX_PATH_BYTES + 1u];
    return AM12JoinPath(stagedMetal, phaseDirectory, artifactNames[0]) &&
           AM12JoinPath(visibleMetal, outputDirectory, artifactNames[0]) &&
           link(stagedMetal, visibleMetal) == 0;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool
    {
        AM12ShaderLoweringRequest empty = {0};
        if (AM12LowerDXILToMSL(NULL) || AM12LowerDXILToMSL(&empty))
        {
            fputs("lowering API accepted an invalid request\n", stderr);
            return 1;
        }

        char temporary[] = "/private/tmp/am12-lowering-api-XXXXXX";
        if (!mkdtemp(temporary))
        {
            fputs("lowering API test could not create temporary directory\n", stderr);
            return 1;
        }
        NSString *temporaryPath = [NSString stringWithUTF8String:temporary];
        NSFileManager *files = [NSFileManager defaultManager];
        int result = 1;

        do
        {
            char output[AM12_MAX_PATH_BYTES + 1u];
            char attack[AM12_MAX_PATH_BYTES + 1u];
            char attackPython[AM12_MAX_PATH_BYTES + 1u];
            char dxil[AM12_MAX_PATH_BYTES + 1u];
            char disassembly[AM12_MAX_PATH_BYTES + 1u];
            char mismatchedDXIL[AM12_MAX_PATH_BYTES + 1u];
            char oversizedPartCountDXIL[AM12_MAX_PATH_BYTES + 1u];
            char oversizedResourceDXIL[AM12_MAX_PATH_BYTES + 1u];
            char oversizedResourceDisassembly[AM12_MAX_PATH_BYTES + 1u];
            char oversizedOperationDXIL[AM12_MAX_PATH_BYTES + 1u];
            char oversizedOperationDisassembly[AM12_MAX_PATH_BYTES + 1u];
            char unsupportedGraphicsDXIL[AM12_MAX_PATH_BYTES + 1u];
            char unsupportedGraphicsDisassembly[AM12_MAX_PATH_BYTES + 1u];
            char metal[AM12_MAX_PATH_BYTES + 1u];
            char provenance[AM12_MAX_PATH_BYTES + 1u];
            char staleReference[AM12_MAX_PATH_BYTES + 1u];
            char mismatchedMetal[AM12_MAX_PATH_BYTES + 1u];
            char oversizedPartCountMetal[AM12_MAX_PATH_BYTES + 1u];
            char oversizedResourceMetal[AM12_MAX_PATH_BYTES + 1u];
            char oversizedOperationMetal[AM12_MAX_PATH_BYTES + 1u];
            char unsupportedGraphicsMetal[AM12_MAX_PATH_BYTES + 1u];
            char unsupportedGraphicsProvenance[AM12_MAX_PATH_BYTES + 1u];
            char interruptedPublication[AM12_MAX_PATH_BYTES + 1u];
            if (!AM12JoinPath(output, temporary, "output") ||
                !AM12JoinPath(attack, temporary, "attack") ||
                !AM12JoinPath(attackPython, attack, "python3") ||
                !AM12JoinPath(dxil, temporary, "positive.dxil") ||
                !AM12JoinPath(disassembly, temporary, "positive.ll") ||
                !AM12JoinPath(mismatchedDXIL, temporary, "mismatched.dxil") ||
                !AM12JoinPath(oversizedPartCountDXIL, temporary, "oversized_parts.dxil") ||
                !AM12JoinPath(oversizedResourceDXIL, temporary, "oversized_resource.dxil") ||
                !AM12JoinPath(oversizedResourceDisassembly, temporary, "oversized_resource.ll") ||
                !AM12JoinPath(oversizedOperationDXIL, temporary, "oversized_operation.dxil") ||
                !AM12JoinPath(oversizedOperationDisassembly, temporary, "oversized_operation.ll") ||
                !AM12JoinPath(unsupportedGraphicsDXIL, temporary, "unsupported_graphics.dxil") ||
                !AM12JoinPath(unsupportedGraphicsDisassembly, temporary,
                              "unsupported_graphics.ll") ||
                !AM12JoinPath(metal, output, "positive.metal") ||
                !AM12JoinPath(provenance, output, "positive.provenance.json") ||
                !AM12JoinPath(staleReference, output, "positive.u7.ref.bin") ||
                !AM12JoinPath(mismatchedMetal, output, "mismatched.metal") ||
                !AM12JoinPath(oversizedPartCountMetal, output, "oversized_parts.metal") ||
                !AM12JoinPath(oversizedResourceMetal, output, "oversized_resource.metal") ||
                !AM12JoinPath(oversizedOperationMetal, output, "oversized_operation.metal") ||
                !AM12JoinPath(unsupportedGraphicsMetal, output, "unsupported_graphics.metal") ||
                !AM12JoinPath(unsupportedGraphicsProvenance, output,
                              "unsupported_graphics.provenance.json") ||
                !AM12JoinPath(interruptedPublication, output,
                              ".am12-publish-positive.installing") ||
                mkdir(output, 0700) != 0 || mkdir(attack, 0700) != 0 ||
                symlink("/usr/bin/true", attackPython) != 0)
            {
                fputs("lowering API test fixture paths failed\n", stderr);
                break;
            }

            uint8_t matchingHash[16];
            uint8_t otherHash[16];
            uint8_t oversizedResourceHash[16];
            uint8_t oversizedOperationHash[16];
            uint8_t unsupportedGraphicsHash[16];
            for (uint8_t index = 0; index < 16u; index++)
            {
                matchingHash[index] = index;
                otherHash[index] = (uint8_t)(0xf0u + index);
                oversizedResourceHash[index] = (uint8_t)(0x40u + index);
                oversizedOperationHash[index] = (uint8_t)(0x60u + index);
                unsupportedGraphicsHash[index] = (uint8_t)(0x80u + index);
            }
            static const char staleMetal[] = "stale MSL";
            static const char staleProvenance[] = "{}";
            uint8_t staleBytes[256] = {0};
            if (!AM12CreateDXILFixture(dxil, matchingHash) ||
                !AM12CreateDisassemblyFixture(disassembly, matchingHash) ||
                !AM12CreateDXILFixture(mismatchedDXIL, otherHash) ||
                !AM12CreateOversizedPartCountDXILFixture(oversizedPartCountDXIL) ||
                !AM12CreateDXILFixture(oversizedResourceDXIL, oversizedResourceHash) ||
                !AM12CreateOversizedResourceDisassemblyFixture(oversizedResourceDisassembly,
                                                               oversizedResourceHash) ||
                !AM12CreateDXILFixture(oversizedOperationDXIL, oversizedOperationHash) ||
                !AM12CreateOversizedOperationDisassemblyFixture(oversizedOperationDisassembly,
                                                                oversizedOperationHash) ||
                !AM12CreateDXILFixture(unsupportedGraphicsDXIL, unsupportedGraphicsHash) ||
                !AM12CreateUnsupportedGraphicsDisassemblyFixture(unsupportedGraphicsDisassembly,
                                                                 unsupportedGraphicsHash) ||
                !AM12WriteFile(metal, staleMetal, sizeof(staleMetal) - 1u) ||
                !AM12WriteFile(provenance, staleProvenance, sizeof(staleProvenance) - 1u) ||
                !AM12WriteFile(staleReference, staleBytes, sizeof(staleBytes)))
            {
                fputs("lowering API test fixture creation failed\n", stderr);
                break;
            }

            const char *oldPath = getenv("PATH");
            const char *oldPythonPath = getenv("PYTHONPATH");
            char *savedPath = oldPath ? strdup(oldPath) : NULL;
            char *savedPythonPath = oldPythonPath ? strdup(oldPythonPath) : NULL;
            setenv("PATH", attack, 1);
            setenv("PYTHONPATH", attack, 1);

            AM12ShaderLoweringRequest request = {
                .dxil_path = dxil,
                .disassembly_path = disassembly,
                .output_directory = output,
            };
            int lowered = AM12LowerDXILToMSL(&request);

            if (savedPath)
                setenv("PATH", savedPath, 1);
            else
                unsetenv("PATH");
            if (savedPythonPath)
                setenv("PYTHONPATH", savedPythonPath, 1);
            else
                unsetenv("PYTHONPATH");
            free(savedPath);
            free(savedPythonPath);

            if (!lowered || !AM12OutputContains(metal, @"kernel void positive(") ||
                !AM12OutputContains(provenance, @"\"shader\": \"positive\"") ||
                !AM12ProvenanceHasPinnedLowerer(provenance) || access(staleReference, F_OK) == 0)
            {
                fputs("lowering API did not validate and replace canonical artifacts\n", stderr);
                break;
            }
            if (!AM12CreateInterruptedPublicationFixture(output, interruptedPublication) ||
                !AM12LowerDXILToMSL(&request) || access(interruptedPublication, F_OK) == 0 ||
                !AM12OutputContains(metal, @"kernel void positive(") ||
                !AM12ProvenanceHasPinnedLowerer(provenance))
            {
                fputs("lowering API did not recover an interrupted publication\n", stderr);
                break;
            }

            AM12ShaderLoweringRequest mismatch = {
                .dxil_path = mismatchedDXIL,
                .disassembly_path = disassembly,
                .output_directory = output,
            };
            if (AM12LowerDXILToMSL(&mismatch) || access(mismatchedMetal, F_OK) == 0)
            {
                fputs("lowering API accepted mismatched DXIL and disassembly\n", stderr);
                break;
            }

            AM12ShaderLoweringRequest oversizedParts = {
                .dxil_path = oversizedPartCountDXIL,
                .disassembly_path = disassembly,
                .output_directory = output,
            };
            if (AM12LowerDXILToMSL(&oversizedParts) || access(oversizedPartCountMetal, F_OK) == 0)
            {
                fputs("lowering API accepted an oversized DXBC part table\n", stderr);
                break;
            }

            AM12ShaderLoweringRequest oversizedResource = {
                .dxil_path = oversizedResourceDXIL,
                .disassembly_path = oversizedResourceDisassembly,
                .output_directory = output,
            };
            if (AM12LowerDXILToMSL(&oversizedResource) || access(oversizedResourceMetal, F_OK) == 0)
            {
                fputs("lowering API accepted resource index 64\n", stderr);
                break;
            }

            AM12ShaderLoweringRequest oversizedOperation = {
                .dxil_path = oversizedOperationDXIL,
                .disassembly_path = oversizedOperationDisassembly,
                .output_directory = output,
            };
            if (AM12LowerDXILToMSL(&oversizedOperation) ||
                access(oversizedOperationMetal, F_OK) == 0)
            {
                fputs("lowering API accepted more than 16384 operations\n", stderr);
                break;
            }

            AM12ShaderLoweringRequest unsupportedGraphics = {
                .dxil_path = unsupportedGraphicsDXIL,
                .disassembly_path = unsupportedGraphicsDisassembly,
                .output_directory = output,
            };
            if (AM12LowerDXILToMSL(&unsupportedGraphics) ||
                access(unsupportedGraphicsMetal, F_OK) == 0 ||
                access(unsupportedGraphicsProvenance, F_OK) == 0)
            {
                fputs("lowering API accepted graphics CBV range 1\n", stderr);
                break;
            }
            if (argc < 1 || !AM12LegacyTrueBypassIsRejected(argv[0], dxil, disassembly, output))
            {
                fputs("lowering CLI accepted the legacy /usr/bin/true bypass\n", stderr);
                break;
            }

            puts("lowering API: canonical positive path passed");
            puts("lowering API: interrupted publication recovered");
            puts("lowering API: /usr/bin/true override rejected");
            puts("lowering API: mismatched DXIL/disassembly rejected");
            puts("lowering API: oversized DXBC part table rejected");
            puts("lowering API: resource index limit enforced");
            puts("lowering API: operation limit enforced");
            puts("lowering API: unsupported graphics CBV range rejected");
            result = 0;
        } while (0);

        NSError *cleanupError = nil;
        if (![files removeItemAtPath:temporaryPath error:&cleanupError] && result == 0)
        {
            fputs("lowering API test cleanup failed\n", stderr);
            result = 1;
        }
        return result;
    }
}
