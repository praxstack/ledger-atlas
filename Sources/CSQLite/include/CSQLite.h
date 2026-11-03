#ifndef CSQLITE_H
#define CSQLITE_H

#include <stddef.h>
#include <stdint.h>
#include <sqlite3.h>

int csqlite_inflate_raw(
    const uint8_t *source,
    size_t source_length,
    uint8_t *destination,
    size_t destination_length
);
uint32_t csqlite_crc32(const uint8_t *source, size_t source_length);

/// 1 when the volume holding `descriptor` keeps change times to the nanosecond (APFS on macOS),
/// so that any write to a file moves its change time. 0 when it doesn't or can't be told.
int csqlite_has_fine_timestamps(int descriptor);

int csqlite_open_pinned_rw(
    const char *canonical_path,
    int authenticated_fd,
    int parent_directory_fd,
    int authenticated_journal_fd,
    const char *leaf_name,
    sqlite3 **database_out,
    void **registration_out
);
int csqlite_close_pinned(sqlite3 *database, void *registration);
/// Test diagnostics only: describes the main database file descriptor SQLite holds for this
/// connection (number, open flags or errno, inode) and every other open descriptor on the same
/// inode (scanning at most 65,536 descriptors). Writes at most `size` bytes, NUL-terminated.
void csqlite_debug_describe_main_descriptor(sqlite3 *database, char *output, size_t size);

#endif
