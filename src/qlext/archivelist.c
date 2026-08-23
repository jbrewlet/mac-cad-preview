#include "archivelist.h"

#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

// System libarchive. The public headers were removed from the macOS SDK;
// these prototypes match the stable C ABI still exported by libarchive.tbd.
struct archive;
struct archive_entry;

#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0
#define ARCHIVE_WARN (-20)

#define AE_IFMT 0170000
#define AE_IFDIR 0040000

struct archive *archive_read_new(void);
int archive_read_free(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_support_format_7zip(struct archive *);
int archive_read_open_filename(struct archive *, const char *, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_skip(struct archive *);
const char *archive_error_string(struct archive *);

const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);

#define DEFAULT_MAX_ENTRIES 10000
#define BLOCK_SIZE 16384

static char *dup_cstr(const char *text) {
    if (!text) return NULL;
    const size_t len = strlen(text);
    char *copy = malloc(len + 1);
    if (!copy) return NULL;
    memcpy(copy, text, len + 1);
    return copy;
}

static char *normalize_path(const char *raw) {
    if (!raw || raw[0] == '\0') return NULL;

    // Drop a leading "./" and any absolute-root slash so the tree starts
    // at the archive's own top level.
    if (raw[0] == '.' && raw[1] == '/') raw += 2;
    while (raw[0] == '/' || raw[0] == '\\') raw += 1;
    if (raw[0] == '\0' || (raw[0] == '.' && raw[1] == '\0')) return NULL;

    const size_t len = strlen(raw);
    char *out = malloc(len + 1);
    if (!out) return NULL;
    size_t w = 0;
    for (size_t i = 0; i < len; ++i) {
        char ch = raw[i] == '\\' ? '/' : raw[i];
        // Collapse repeated slashes.
        if (ch == '/' && w > 0 && out[w - 1] == '/') continue;
        out[w++] = ch;
    }
    while (w > 0 && out[w - 1] == '/') --w;
    out[w] = '\0';
    if (w == 0) {
        free(out);
        return NULL;
    }
    return out;
}

static void set_error(ArchiveList *list, const char *message) {
    free(list->error);
    list->error = dup_cstr(message ? message : "Could not read this archive.");
}

static void fail_from_archive(ArchiveList *list, struct archive *archive) {
    const char *message = archive_error_string(archive);
    set_error(list, message && message[0] ? message : "Could not read this archive.");
}

ArchiveList *archivelist_read(const char *path, int max_entries) {
    ArchiveList *list = calloc(1, sizeof(*list));
    if (!list) return NULL;
    if (!path || path[0] == '\0') {
        set_error(list, "No file path.");
        return list;
    }

    if (max_entries <= 0) max_entries = DEFAULT_MAX_ENTRIES;

    struct archive *archive = archive_read_new();
    if (!archive) {
        set_error(list, "Out of memory.");
        return list;
    }

    // Only the formats we claim. Enabling every filter would let libarchive
    // spawn helper programs for odd compressors, which a sandbox cannot do.
    archive_read_support_format_zip(archive);
    archive_read_support_format_rar(archive);
    archive_read_support_format_rar5(archive);
    archive_read_support_format_7zip(archive);

    if (archive_read_open_filename(archive, path, BLOCK_SIZE) != ARCHIVE_OK) {
        fail_from_archive(list, archive);
        archive_read_free(archive);
        return list;
    }

    ArchiveListEntry *entries = NULL;
    int stored = 0;
    int capacity = 0;

    for (;;) {
        struct archive_entry *entry = NULL;
        const int status = archive_read_next_header(archive, &entry);
        if (status == ARCHIVE_EOF) break;
        if (status < ARCHIVE_WARN) {
            // A later entry can fail after we already listed some; keep the
            // names we have unless we got nothing at all.
            if (stored == 0) fail_from_archive(list, archive);
            break;
        }

        const char *raw = archive_entry_pathname_utf8(entry);
        if (!raw) raw = archive_entry_pathname(entry);
        char *name = normalize_path(raw);
        if (!name) {
            archive_read_data_skip(archive);
            continue;
        }
        const mode_t type = archive_entry_filetype(entry);
        const int is_dir = ((type & AE_IFMT) == AE_IFDIR) ||
                           (raw && raw[0] && raw[strlen(raw) - 1] == '/');
        const int encrypted = archive_entry_is_encrypted(entry) ? 1 : 0;
        const int size_set = archive_entry_size_is_set(entry);
        const int64_t size = size_set ? archive_entry_size(entry) : (int64_t)-1;

        if (encrypted) list->encrypted_count += 1;
        if (is_dir) {
            list->dir_count += 1;
        } else {
            list->file_count += 1;
            if (size >= 0) list->total_size += size;
        }

        if (name && stored < max_entries) {
            if (stored == capacity) {
                const int next = capacity == 0 ? 64 : capacity * 2;
                ArchiveListEntry *grown = realloc(entries, (size_t)next * sizeof(*grown));
                if (!grown) {
                    free(name);
                    set_error(list, "Out of memory.");
                    break;
                }
                entries = grown;
                capacity = next;
            }
            entries[stored].path = name;
            entries[stored].size = is_dir ? (int64_t)-1 : size;
            entries[stored].is_directory = is_dir;
            entries[stored].is_encrypted = encrypted;
            stored += 1;
            name = NULL;
        } else if (name) {
            list->omitted += 1;
            list->truncated = 1;
            free(name);
        }

        archive_read_data_skip(archive);
    }

    list->entries = entries;
    list->count = stored;
    archive_read_free(archive);

    if (!list->error && stored == 0 && list->omitted == 0) {
        set_error(list, "This archive is empty.");
    }
    return list;
}

void archivelist_free(ArchiveList *list) {
    if (!list) return;
    if (list->entries) {
        for (int i = 0; i < list->count; ++i) {
            free(list->entries[i].path);
        }
        free(list->entries);
    }
    free(list->error);
    free(list);
}
