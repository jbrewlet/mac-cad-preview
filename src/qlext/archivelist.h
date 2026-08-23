// Lists zip / rar / 7z members through the system libarchive, without
// extracting anything. The SDK no longer ships archive.h, so the .c file
// declares the handful of symbols it needs.
#ifndef ARCHIVELIST_H
#define ARCHIVELIST_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ArchiveListEntry {
    char *path;
    // Uncompressed size. -1 when the archive does not report one.
    int64_t size;
    int is_directory;
    int is_encrypted;
} ArchiveListEntry;

typedef struct ArchiveList {
    ArchiveListEntry *entries;
    int count;
    int truncated;
    int omitted;
    int64_t total_size;
    int file_count;
    int dir_count;
    int encrypted_count;
    // NULL on success, else a description of what went wrong.
    char *error;
} ArchiveList;

// max_entries <= 0 means a built-in cap. Returns NULL only on allocation
// failure; check ->error otherwise.
ArchiveList *archivelist_read(const char *path, int max_entries);
void archivelist_free(ArchiveList *list);

#ifdef __cplusplus
}
#endif

#endif
