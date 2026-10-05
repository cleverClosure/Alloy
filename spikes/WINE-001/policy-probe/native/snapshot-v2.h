/* Author: Timur Isaev
 * Bounded, allocation-free ALLOYP02 validator shared by the Wine policy patch
 * and the host malformed-input control. Only little-endian hosts are supported.
 */
#ifndef ALLOY_SNAPSHOT_V2_H
#define ALLOY_SNAPSHOT_V2_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define AP2_HEADER 96
#define AP2_ENTRY 7472
#define AP2_COUNT 1024
#define AP2_ROUTES 32
#define AP2_ENV 16
#define AP2_MAX (AP2_HEADER + AP2_ENTRY * AP2_COUNT)

struct ap2_route
{
    char module[32];
    uint32_t order;
};
struct ap2_environment
{
    char key[64];
    char value[256];
};
struct ap2_entry
{
    unsigned char image[32];
    char id[64];
    char graphics[64];
    char directory[512];
    uint32_t presence;
    uint32_t cpu;
    uint32_t routes_count;
    uint32_t environment_count;
    char working[512];
    struct ap2_route routes[AP2_ROUTES];
    struct ap2_environment environment[AP2_ENV];
};
struct ap2_header
{
    unsigned char magic[8];
    uint32_t version, endian, header_size, entry_size, count, default_index;
    unsigned char source_digest[32], content_digest[32];
};

#ifndef AP2_TYPES_ONLY

/* NULL means valid; errors are stable public reason names. Integrity is checked
 * by the caller on its private immutable copy before invoking this parser. */
static int ap2_zero(const void *value, size_t size)
{
    const unsigned char *bytes = value;
    while (size--)
        if (*bytes++)
            return 0;
    return 1;
}

static int ap2_text(const char *text, size_t size)
{
    size_t index;
    for (index = 0; index < size; index++)
    {
        if (!text[index])
            return ap2_zero(text + index, size - index);
        if ((unsigned char)text[index] < 32 || (unsigned char)text[index] > 126)
            return 0;
    }
    return 0;
}

static int ap2_identifier(const char *text)
{
    if (!*text)
        return 0;
    for (; *text; text++)
        if (!((*text >= 'a' && *text <= 'z') || (*text >= 'A' && *text <= 'Z') ||
              (*text >= '0' && *text <= '9') || *text == '_' || *text == '-' || *text == '.'))
            return 0;
    return 1;
}

static int ap2_path(const char *text)
{
    const char *start, *end;
    if (!((*text >= 'a' && *text <= 'z') || (*text >= 'A' && *text <= 'Z')) || text[1] != ':' ||
        (text[2] != '\\' && text[2] != '/'))
        return 0;
    if (strpbrk(text + 2, ":;*?\"<>|"))
        return 0;
    start = text + 3;
    for (;;)
    {
        end = start + strcspn(start, "\\/");
        if (end > start && (end[-1] == '.' || end[-1] == ' '))
            return 0;
        if (!*end)
            break;
        start = end + 1;
    }
    return 1;
}

static int ap2_environment_key(const char *key)
{
    if (!*key)
        return 0;
    if (!strncmp(key, "ALLOY_", 6) || !strncmp(key, "WINE", 4) || !strncmp(key, "DYLD_", 5) ||
        !strncmp(key, "LD_", 3) || !strncmp(key, "FEX", 3) || !strcmp(key, "PATH") ||
        !strcmp(key, "HOME") || !strcmp(key, "TMPDIR") || !strcmp(key, "SYSTEMROOT") ||
        !strcmp(key, "SYSTEMDRIVE") || !strcmp(key, "COMSPEC"))
        return 0;
    for (; *key; key++)
        if (!((*key >= 'A' && *key <= 'Z') || (*key >= '0' && *key <= '9') || *key == '_'))
            return 0;
    return 1;
}

static const char *ap2_policy(const struct ap2_entry *entry)
{
    uint32_t index;
    if (!ap2_text(entry->id, sizeof(entry->id)) || !ap2_identifier(entry->id) ||
        !ap2_text(entry->graphics, sizeof(entry->graphics)) ||
        !ap2_text(entry->directory, sizeof(entry->directory)) ||
        !ap2_text(entry->working, sizeof(entry->working)) || (entry->presence & ~31u) ||
        entry->cpu > 2 || entry->routes_count > AP2_ROUTES || entry->environment_count > AP2_ENV)
        return "policy-invalid-field";
    if (entry->presence & 1)
    {
        if (!ap2_identifier(entry->graphics) || !ap2_path(entry->directory))
            return "policy-invalid-field";
    }
    else if (*entry->graphics || *entry->directory)
        return "policy-noncanonical";
    if (!!(entry->presence & 2) != !!entry->cpu)
        return "policy-noncanonical";
    if ((entry->presence & 8) ? !ap2_path(entry->working) : !!*entry->working)
        return "policy-invalid-field";
    if ((!(entry->presence & 4) && entry->environment_count) ||
        (!(entry->presence & 16) && entry->routes_count))
        return "policy-noncanonical";
    for (index = 0; index < AP2_ROUTES; index++)
    {
        const struct ap2_route *route = &entry->routes[index];
        const char *name = route->module;
        if (index >= entry->routes_count)
        {
            if (!ap2_zero(route, sizeof(*route)))
                return "policy-noncanonical";
            continue;
        }
        if (!ap2_text(name, sizeof(route->module)) || !ap2_identifier(name) || route->order < 1 ||
            route->order > 5 || !strcmp(name, "ntdll") || !strcmp(name, "kernel32") ||
            !strcmp(name, "kernelbase") || !strcmp(name, "libarm64ecfex"))
            return "policy-invalid-field";
        if (strpbrk(name, "ABCDEFGHIJKLMNOPQRSTUVWXYZ") ||
            (strlen(name) >= 4 && !strcmp(name + strlen(name) - 4, ".dll")) ||
            (index && strcmp(entry->routes[index - 1].module, name) >= 0))
            return "policy-noncanonical";
    }
    for (index = 0; index < AP2_ENV; index++)
    {
        const struct ap2_environment *env = &entry->environment[index];
        if (index >= entry->environment_count)
        {
            if (!ap2_zero(env, sizeof(*env)))
                return "policy-noncanonical";
            continue;
        }
        if (!ap2_text(env->key, sizeof(env->key)) || !ap2_environment_key(env->key) ||
            !ap2_text(env->value, sizeof(env->value)))
            return "policy-invalid-field";
        if (index && strcmp(entry->environment[index - 1].key, env->key) >= 0)
            return "policy-noncanonical";
    }
    return NULL;
}

static const char *ap2_validate(const void *bytes, size_t size)
{
    const struct ap2_header *header = bytes;
    const struct ap2_entry *entries;
    uint32_t index;
    const char *reason;
    if (size >= 8 && !memcmp(bytes, "ALLOYP01", 8))
        return "policy-legacy-version";
    if (size < AP2_HEADER || size > AP2_MAX || sizeof(*header) != AP2_HEADER ||
        sizeof(struct ap2_entry) != AP2_ENTRY || memcmp(header->magic, "ALLOYP02", 8) ||
        header->version != 2 || header->endian != 0x01020304 || header->header_size != AP2_HEADER ||
        header->entry_size != AP2_ENTRY || !header->count || header->count > AP2_COUNT ||
        header->default_index || size != AP2_HEADER + (size_t)header->count * AP2_ENTRY)
        return "policy-layout";
    entries = (const struct ap2_entry *)(header + 1);
    for (index = 0; index < header->count; index++)
    {
        if ((index == 0) != !!ap2_zero(entries[index].image, 32) ||
            (index > 1 && memcmp(entries[index - 1].image, entries[index].image, 32) >= 0))
            return "policy-noncanonical";
        reason = ap2_policy(&entries[index]);
        if (reason)
            return reason;
    }
    return NULL;
}
#endif /* AP2_TYPES_ONLY */
#endif
