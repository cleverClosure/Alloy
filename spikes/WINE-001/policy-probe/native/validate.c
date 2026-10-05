/* Author: Timur Isaev */
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <stdlib.h>

#include "snapshot-v2.h"

int main(int argc, char **argv)
{
    FILE *file;
    unsigned char *bytes, expected[32], actual[32], content[32];
    const char *reason = NULL;
    long size;
    if (argc != 2 || !(file = fopen(argv[1], "rb")))
        return 64;
    if (fseek(file, 0, SEEK_END) || (size = ftell(file)) < 0 || size > AP2_MAX ||
        fseek(file, 0, SEEK_SET))
    {
        fclose(file);
        fprintf(stderr, "policy-layout\n");
        return 65;
    }
    bytes = calloc(1, (size_t)size + 1);
    if (!bytes || fread(bytes, 1, (size_t)size, file) != (size_t)size)
    {
        free(bytes);
        fclose(file);
        return 66;
    }
    fclose(file);
    if (size >= 8 && !memcmp(bytes, "ALLOYP01", 8))
        reason = "policy-legacy-version";
    else if (size < AP2_HEADER)
        reason = "policy-layout";
    else
    {
        memcpy(expected, bytes + 64, 32);
        memset(bytes + 64, 0, 32);
        CC_SHA256(bytes, (CC_LONG)size, actual);
        memcpy(bytes + 64, expected, 32);
        CC_SHA256(bytes + AP2_HEADER, (CC_LONG)(size - AP2_HEADER), content);
        if (memcmp(expected, actual, 32) || memcmp(content, bytes + 32, 32))
            reason = "policy-integrity";
        else
            reason = ap2_validate(bytes, (size_t)size);
    }
    free(bytes);
    if (reason)
    {
        fprintf(stderr, "%s\n", reason);
        return 65;
    }
    puts("policy-import-marker");
    return 0;
}
