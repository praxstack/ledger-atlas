#include "CSQLite.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

typedef struct {
    sqlite3_vfs vfs;
    sqlite3_vfs *parent;
    int database_fd;
    int parent_directory_fd;
    int recovery_journal_fd;
    int journal_fd;
    int main_opened;
    int journal_owned;
    struct stat database_identity;
    struct stat journal_identity;
    char *leaf_name;
    char *journal_leaf_name;
    char *binding_leaf_name;
    char *vfs_name;
} csqlite_pinned_registration;

typedef struct {
    sqlite3_file base;
    csqlite_pinned_registration *context;
    sqlite3_file *inner;
    // The "/dev/fd/N" name the inner unix file was opened by. The unix VFS keeps the pointer
    // (as zPath) and reads it again at close, so it must live as long as the file.
    char descriptor_path[64];
    max_align_t alignment;
} csqlite_pinned_file;

static int csqlite_pinned_main_is_bound(csqlite_pinned_registration *context);
static int csqlite_sync_directory(int descriptor);

static csqlite_pinned_registration *csqlite_pinned_context(sqlite3_vfs *vfs) {
    return (csqlite_pinned_registration *)vfs;
}

static csqlite_pinned_file *csqlite_pinned_file_context(sqlite3_file *file) {
    return (csqlite_pinned_file *)file;
}

static int csqlite_pinned_io_close(sqlite3_file *file) {
    csqlite_pinned_file *pinned = csqlite_pinned_file_context(file);
    int result = pinned->inner->pMethods->xClose(pinned->inner);
    pinned->base.pMethods = NULL;
    return result;
}

static int csqlite_pinned_io_read(
    sqlite3_file *file,
    void *buffer,
    int amount,
    sqlite3_int64 offset
) {
    csqlite_pinned_file *pinned = csqlite_pinned_file_context(file);
    return pinned->inner->pMethods->xRead(pinned->inner, buffer, amount, offset);
}

static int csqlite_pinned_io_write(
    sqlite3_file *file,
    const void *buffer,
    int amount,
    sqlite3_int64 offset
) {
    csqlite_pinned_file *pinned = csqlite_pinned_file_context(file);
    return pinned->inner->pMethods->xWrite(pinned->inner, buffer, amount, offset);
}

static int csqlite_pinned_io_truncate(sqlite3_file *file, sqlite3_int64 size) {
    csqlite_pinned_file *pinned = csqlite_pinned_file_context(file);
    return pinned->inner->pMethods->xTruncate(pinned->inner, size);
}

static int csqlite_pinned_io_sync(sqlite3_file *file, int flags) {
    csqlite_pinned_file *pinned = csqlite_pinned_file_context(file);
    return pinned->inner->pMethods->xSync(pinned->inner, flags);
}

static int csqlite_pinned_io_file_size(sqlite3_file *file, sqlite3_int64 *size) {
    csqlite_pinned_file *pinned = csqlite_pinned_file_context(file);
    return pinned->inner->pMethods->xFileSize(pinned->inner, size);
}

static int csqlite_pinned_io_lock(sqlite3_file *file, int lock) {
    csqlite_pinned_file *pinned = csqlite_pinned_file_context(file);
    return pinned->inner->pMethods->xLock(pinned->inner, lock);
}

static int csqlite_pinned_io_unlock(sqlite3_file *file, int lock) {
    csqlite_pinned_file *pinned = csqlite_pinned_file_context(file);
    return pinned->inner->pMethods->xUnlock(pinned->inner, lock);
}

static int csqlite_pinned_io_check_reserved(sqlite3_file *file, int *result_out) {
    csqlite_pinned_file *pinned = csqlite_pinned_file_context(file);
    return pinned->inner->pMethods->xCheckReservedLock(pinned->inner, result_out);
}

static int csqlite_pinned_io_file_control(sqlite3_file *file, int operation, void *argument) {
    csqlite_pinned_file *pinned = csqlite_pinned_file_context(file);
    if (operation == SQLITE_FCNTL_VFS_POINTER) {
        if (argument == NULL) return SQLITE_MISUSE;
        *(sqlite3_vfs **)argument = &pinned->context->vfs;
        return SQLITE_OK;
    }
    if (operation == SQLITE_FCNTL_HAS_MOVED) {
        if (argument == NULL) return SQLITE_MISUSE;
        *(int *)argument = !csqlite_pinned_main_is_bound(pinned->context);
        return SQLITE_OK;
    }
    return pinned->inner->pMethods->xFileControl(pinned->inner, operation, argument);
}

static int csqlite_pinned_io_sector_size(sqlite3_file *file) {
    csqlite_pinned_file *pinned = csqlite_pinned_file_context(file);
    return pinned->inner->pMethods->xSectorSize(pinned->inner);
}

static int csqlite_pinned_io_device_characteristics(sqlite3_file *file) {
    csqlite_pinned_file *pinned = csqlite_pinned_file_context(file);
    return pinned->inner->pMethods->xDeviceCharacteristics(pinned->inner);
}

static const sqlite3_io_methods csqlite_pinned_io_methods = {
    1,
    csqlite_pinned_io_close,
    csqlite_pinned_io_read,
    csqlite_pinned_io_write,
    csqlite_pinned_io_truncate,
    csqlite_pinned_io_sync,
    csqlite_pinned_io_file_size,
    csqlite_pinned_io_lock,
    csqlite_pinned_io_unlock,
    csqlite_pinned_io_check_reserved,
    csqlite_pinned_io_file_control,
    csqlite_pinned_io_sector_size,
    csqlite_pinned_io_device_characteristics,
};

static int csqlite_duplicate_cloexec(int descriptor) {
    return fcntl(descriptor, F_DUPFD_CLOEXEC, 0);
}

static int csqlite_same_inode(const struct stat *lhs, const struct stat *rhs) {
    return lhs->st_dev == rhs->st_dev && lhs->st_ino == rhs->st_ino;
}

static int csqlite_safe_database_stat(const struct stat *value) {
    return S_ISREG(value->st_mode) && value->st_uid == getuid() && value->st_nlink == 1
        && (value->st_mode & 0777) == 0600;
}

static int csqlite_pinned_main_is_bound(csqlite_pinned_registration *context) {
    struct stat at_parent = {0};
    if (fstatat(
            context->parent_directory_fd,
            context->leaf_name,
            &at_parent,
            AT_SYMLINK_NOFOLLOW
        ) != 0) {
        return 0;
    }
    return csqlite_same_inode(&context->database_identity, &at_parent)
        && csqlite_safe_database_stat(&context->database_identity)
        && csqlite_safe_database_stat(&at_parent);
}

static const char *csqlite_basename(const char *path) {
    if (path == NULL) return NULL;
    const char *separator = strrchr(path, '/');
    return separator == NULL ? path : separator + 1;
}

static int csqlite_is_forbidden_companion(
    const csqlite_pinned_registration *context,
    const char *leaf
) {
    if (context == NULL || leaf == NULL) return 0;
    size_t base_length = strlen(context->leaf_name);
    return strncmp(leaf, context->leaf_name, base_length) == 0
        && (strcmp(leaf + base_length, "-wal") == 0
            || strcmp(leaf + base_length, "-shm") == 0);
}

static int csqlite_safe_journal_stat(const struct stat *value, int require_content) {
    return S_ISREG(value->st_mode) && value->st_uid == getuid() && value->st_nlink == 1
        && (value->st_mode & 0777) == 0600
        && value->st_size >= (require_content ? 512 : 0)
        && value->st_size <= (off_t)(1024LL * 1024LL * 1024LL);
}

static int csqlite_safe_binding_stat(const struct stat *value) {
    return S_ISREG(value->st_mode) && value->st_uid == getuid() && value->st_nlink == 1
        && (value->st_mode & 0777) == 0600 && value->st_size > 0 && value->st_size <= 256;
}

static int csqlite_write_all(int descriptor, const char *value, size_t length) {
    while (length > 0) {
        ssize_t written = write(descriptor, value, length);
        if (written <= 0) return SQLITE_IOERR_WRITE;
        value += written;
        length -= (size_t)written;
    }
    return SQLITE_OK;
}

static int csqlite_write_journal_binding(
    csqlite_pinned_registration *context,
    const struct stat *journal_identity
) {
    char payload[256];
    char temporary_leaf[320];
    int length = snprintf(
        payload,
        sizeof(payload),
        "ledger-atlas-journal-v3\n%llu\n%llu\n%lld\n%ld\n%llu\n%llu\n%lld\n%ld\n",
        (unsigned long long)context->database_identity.st_dev,
        (unsigned long long)context->database_identity.st_ino,
        (long long)context->database_identity.st_birthtimespec.tv_sec,
        context->database_identity.st_birthtimespec.tv_nsec,
        (unsigned long long)journal_identity->st_dev,
        (unsigned long long)journal_identity->st_ino,
        (long long)journal_identity->st_birthtimespec.tv_sec,
        journal_identity->st_birthtimespec.tv_nsec
    );
    if (length <= 0 || (size_t)length >= sizeof(payload)) return SQLITE_CANTOPEN;
    int temporary_length = snprintf(
        temporary_leaf,
        sizeof(temporary_leaf),
        "%s.tmp-%ld-%p",
        context->binding_leaf_name,
        (long)getpid(),
        (void *)context
    );
    if (temporary_length <= 0 || (size_t)temporary_length >= sizeof(temporary_leaf)) {
        return SQLITE_CANTOPEN;
    }
    int descriptor = openat(
        context->parent_directory_fd,
        temporary_leaf,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
        0600
    );
    if (descriptor < 0) return SQLITE_CANTOPEN;
    int result = csqlite_write_all(descriptor, payload, (size_t)length);
    if (result == SQLITE_OK && fsync(descriptor) != 0) result = SQLITE_IOERR_FSYNC;
    close(descriptor);
    if (result == SQLITE_OK
        && renameat(
            context->parent_directory_fd,
            temporary_leaf,
            context->parent_directory_fd,
            context->binding_leaf_name
        ) != 0) {
        result = SQLITE_IOERR;
    }
    if (result != SQLITE_OK) {
        unlinkat(context->parent_directory_fd, temporary_leaf, 0);
        return result;
    }
    struct stat value = {0};
    if (result == SQLITE_OK
        && (fstatat(
                context->parent_directory_fd,
                context->binding_leaf_name,
                &value,
                AT_SYMLINK_NOFOLLOW
            ) != 0
            || !csqlite_safe_binding_stat(&value))) {
        result = SQLITE_CANTOPEN;
    }
    if (result == SQLITE_OK) result = csqlite_sync_directory(context->parent_directory_fd);
    return result;
}

static int csqlite_journal_binding_matches(
    csqlite_pinned_registration *context,
    const struct stat *journal_identity
) {
    int descriptor = openat(
        context->parent_directory_fd,
        context->binding_leaf_name,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    );
    if (descriptor < 0) return 0;
    struct stat value = {0};
    char payload[257] = {0};
    ssize_t length = read(descriptor, payload, sizeof(payload) - 1);
    close(descriptor);
    if (length <= 0
        || fstatat(
            context->parent_directory_fd,
            context->binding_leaf_name,
            &value,
            AT_SYMLINK_NOFOLLOW
        ) != 0
        || !csqlite_safe_binding_stat(&value)
        || length != value.st_size) {
        return 0;
    }
    unsigned long long database_device = 0;
    unsigned long long database_inode = 0;
    long long database_change_seconds = 0;
    long database_change_nanoseconds = 0;
    unsigned long long journal_device = 0;
    unsigned long long journal_inode = 0;
    long long journal_change_seconds = 0;
    long journal_change_nanoseconds = 0;
    int parsed = sscanf(
        payload,
        "ledger-atlas-journal-v3\n%llu\n%llu\n%lld\n%ld\n%llu\n%llu\n%lld\n%ld\n",
        &database_device,
        &database_inode,
        &database_change_seconds,
        &database_change_nanoseconds,
        &journal_device,
        &journal_inode,
        &journal_change_seconds,
        &journal_change_nanoseconds
    );
    return parsed == 8
        && database_device == (unsigned long long)context->database_identity.st_dev
        && database_inode == (unsigned long long)context->database_identity.st_ino
        && database_change_seconds == (long long)context->database_identity.st_birthtimespec.tv_sec
        && database_change_nanoseconds == context->database_identity.st_birthtimespec.tv_nsec
        && journal_device == (unsigned long long)journal_identity->st_dev
        && journal_inode == (unsigned long long)journal_identity->st_ino
        && journal_change_seconds == (long long)journal_identity->st_birthtimespec.tv_sec
        && journal_change_nanoseconds == journal_identity->st_birthtimespec.tv_nsec;
}

static int csqlite_unlink_owned_journal(
    csqlite_pinned_registration *context,
    const struct stat *identity,
    int sync_directory
) {
    struct stat retained = {0};
    if (context->journal_fd < 0
        || identity == NULL
        || fstat(context->journal_fd, &retained) != 0
        || !csqlite_same_inode(identity, &retained)
        || !csqlite_safe_journal_stat(&retained, 0)
        || ftruncate(context->journal_fd, 0) != 0
        || fsync(context->journal_fd) != 0) {
        return SQLITE_IOERR_DELETE;
    }
    // Keep the zero-length journal pathname and invalidate it through the retained
    // descriptor. POSIX has no unlink-by-open-fd primitive, so pathname deletion
    // would allow a same-user replacement to be removed.
    return sync_directory ? csqlite_sync_directory(context->parent_directory_fd) : SQLITE_OK;
}

static int csqlite_open_parent_from_fd(
    csqlite_pinned_registration *context,
    int descriptor,
    sqlite3_file *file,
    char *descriptor_path,
    size_t descriptor_path_size,
    int flags,
    int *out_flags
) {
    // `descriptor_path` must outlive `file`: the parent VFS keeps the pointer, not a copy.
    int length = snprintf(
        descriptor_path,
        descriptor_path_size,
        "/dev/fd/%d",
        descriptor
    );
    if (length <= 0 || (size_t)length >= descriptor_path_size) return SQLITE_CANTOPEN;
    int delegated_flags = (flags | SQLITE_OPEN_READWRITE)
        & ~(SQLITE_OPEN_CREATE | SQLITE_OPEN_EXCLUSIVE | SQLITE_OPEN_DELETEONCLOSE
            | SQLITE_OPEN_URI | SQLITE_OPEN_MAIN_JOURNAL | SQLITE_OPEN_WAL);
    int result = context->parent->xOpen(
        context->parent,
        descriptor_path,
        file,
        delegated_flags,
        out_flags
    );
    if (result != SQLITE_OK) return result;
    if (out_flags != NULL && (*out_flags & SQLITE_OPEN_READWRITE) == 0) {
        file->pMethods->xClose(file);
        file->pMethods = NULL;
        return SQLITE_READONLY;
    }
    return SQLITE_OK;
}

static int csqlite_open_pinned_main(
    csqlite_pinned_registration *context,
    sqlite3_file *file,
    int flags,
    int *out_flags
) {
    csqlite_pinned_file *pinned = csqlite_pinned_file_context(file);
    memset(pinned, 0, sizeof(*pinned));
    pinned->context = context;
    pinned->inner = (sqlite3_file *)((unsigned char *)file + sizeof(*pinned));
    memset(pinned->inner, 0, (size_t)context->parent->szOsFile);
    int result = csqlite_open_parent_from_fd(
        context,
        context->database_fd,
        pinned->inner,
        pinned->descriptor_path,
        sizeof(pinned->descriptor_path),
        flags,
        out_flags
    );
    if (result != SQLITE_OK) return result;
    close(context->database_fd);
    context->database_fd = -1;
    pinned->base.pMethods = &csqlite_pinned_io_methods;
    return SQLITE_OK;
}

static int csqlite_pinned_open(
    sqlite3_vfs *vfs,
    const char *name,
    sqlite3_file *file,
    int flags,
    int *out_flags
) {
    csqlite_pinned_registration *context = csqlite_pinned_context(vfs);
    if ((flags & SQLITE_OPEN_WAL) != 0) return SQLITE_CANTOPEN;
    if ((flags & SQLITE_OPEN_MAIN_DB) != 0) {
        if (context->main_opened || !csqlite_pinned_main_is_bound(context)) {
            return SQLITE_CANTOPEN;
        }
        context->main_opened = 1;
        return csqlite_open_pinned_main(
            context,
            file,
            flags,
            out_flags
        );
    }
    if ((flags & SQLITE_OPEN_MAIN_JOURNAL) != 0) {
        if (!csqlite_pinned_main_is_bound(context)
            || strcmp(csqlite_basename(name), context->journal_leaf_name) != 0
            || (flags & SQLITE_OPEN_DELETEONCLOSE) != 0) {
            return SQLITE_CANTOPEN;
        }
        int journal = context->recovery_journal_fd;
        int recovery = journal >= 0;
        int owned_existing = !recovery && context->journal_owned;
        int created = !recovery && !owned_existing;
        if (!recovery) {
            if (!owned_existing) {
                struct stat existing = {0};
                if (fstatat(
                        context->parent_directory_fd,
                        context->journal_leaf_name,
                        &existing,
                        AT_SYMLINK_NOFOLLOW
                    ) == 0) {
                    if (existing.st_size != 0
                        || !csqlite_safe_journal_stat(&existing, 0)
                        || !csqlite_journal_binding_matches(context, &existing)) {
                        return SQLITE_CANTOPEN;
                    }
                    // Adopt the empty journal an earlier session left; later checks
                    // compare the opened descriptor against this identity.
                    context->journal_identity = existing;
                    owned_existing = 1;
                    created = 0;
                } else if (errno != ENOENT) {
                    return SQLITE_CANTOPEN;
                }
            }
            int open_flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW;
            if (created) open_flags |= O_CREAT | O_EXCL;
            journal = openat(
                context->parent_directory_fd,
                context->journal_leaf_name,
                open_flags,
                0600
            );
            if (journal < 0) return SQLITE_CANTOPEN;
        }
        int retained_journal = csqlite_duplicate_cloexec(journal);
        if (retained_journal < 0) {
            if (recovery) context->recovery_journal_fd = -1;
            close(journal);
            return SQLITE_CANTOPEN;
        }
        if (context->journal_fd >= 0) close(context->journal_fd);
        context->journal_fd = retained_journal;
        struct stat value = {0};
        struct stat at_parent = {0};
        if (fstat(journal, &value) != 0
            || !csqlite_safe_journal_stat(&value, recovery && !owned_existing)
            || fstatat(
                context->parent_directory_fd,
                context->journal_leaf_name,
                &at_parent,
                AT_SYMLINK_NOFOLLOW
            ) != 0
            || (owned_existing && !csqlite_same_inode(&context->journal_identity, &value))
            || !csqlite_same_inode(&value, &at_parent)
            || (recovery && !csqlite_journal_binding_matches(context, &value))) {
            if (created && value.st_ino != 0) {
                csqlite_unlink_owned_journal(context, &value, 1);
            }
            if (recovery) context->recovery_journal_fd = -1;
            close(journal);
            return SQLITE_CANTOPEN;
        }
        context->journal_identity = value;
        context->journal_owned = 1;
        if (!recovery && csqlite_write_journal_binding(context, &value) != SQLITE_OK) {
            csqlite_unlink_owned_journal(context, &value, 1);
            close(journal);
            context->journal_owned = 0;
            return SQLITE_CANTOPEN;
        }
        if (!recovery && csqlite_sync_directory(context->parent_directory_fd) != SQLITE_OK) {
            csqlite_unlink_owned_journal(context, &value, 1);
            close(journal);
            context->journal_owned = 0;
            return SQLITE_IOERR_DIR_FSYNC;
        }
        // The journal is the parent's own file, so the name goes in the spare bytes after it:
        // this VFS's szOsFile adds sizeof(csqlite_pinned_file) to the parent's.
        int result = csqlite_open_parent_from_fd(
            context,
            journal,
            file,
            (char *)file + context->parent->szOsFile,
            sizeof(csqlite_pinned_file),
            flags,
            out_flags
        );
        close(journal);
        if (recovery) context->recovery_journal_fd = -1;
        if (result != SQLITE_OK) {
            if (!recovery) {
                csqlite_unlink_owned_journal(context, &value, 1);
                context->journal_owned = 0;
            }
        }
        return result;
    }
    return context->parent->xOpen(context->parent, name, file, flags, out_flags);
}

static int csqlite_sync_directory(int descriptor) {
#ifdef F_FULLFSYNC
    if (fcntl(descriptor, F_FULLFSYNC) == 0) return SQLITE_OK;
    if (errno != EINVAL && errno != ENOTSUP) return SQLITE_IOERR_DIR_FSYNC;
#endif
    return fsync(descriptor) == 0 ? SQLITE_OK : SQLITE_IOERR_DIR_FSYNC;
}

static int csqlite_pinned_delete(sqlite3_vfs *vfs, const char *name, int sync_directory) {
    csqlite_pinned_registration *context = csqlite_pinned_context(vfs);
    const char *leaf = csqlite_basename(name);
    if (csqlite_is_forbidden_companion(context, leaf)) return SQLITE_IOERR_DELETE;
    if (leaf != NULL && strcmp(leaf, context->journal_leaf_name) == 0) {
        if (!context->journal_owned) return SQLITE_IOERR_DELETE;
        int result = csqlite_unlink_owned_journal(
            context,
            &context->journal_identity,
            sync_directory
        );
        if (result != SQLITE_OK) return result;
        context->journal_owned = 0;
        return SQLITE_OK;
    }
    if (leaf != NULL && strcmp(leaf, context->leaf_name) == 0) return SQLITE_IOERR_DELETE;
    return context->parent->xDelete(context->parent, name, sync_directory);
}

static int csqlite_pinned_access(
    sqlite3_vfs *vfs,
    const char *name,
    int flags,
    int *result_out
) {
    csqlite_pinned_registration *context = csqlite_pinned_context(vfs);
    const char *leaf = csqlite_basename(name);
    if (csqlite_is_forbidden_companion(context, leaf)) {
        *result_out = 0;
        return SQLITE_OK;
    }
    if (leaf != NULL && strcmp(leaf, context->leaf_name) == 0) {
        *result_out = csqlite_pinned_main_is_bound(context);
        return SQLITE_OK;
    }
    if (leaf != NULL && strcmp(leaf, context->journal_leaf_name) == 0) {
        struct stat value = {0};
        *result_out = (context->journal_owned || context->recovery_journal_fd >= 0)
            && fstatat(
            context->parent_directory_fd,
            context->journal_leaf_name,
            &value,
            AT_SYMLINK_NOFOLLOW
        ) == 0 && csqlite_same_inode(&context->journal_identity, &value)
            && csqlite_safe_journal_stat(&value, context->recovery_journal_fd >= 0);
        return SQLITE_OK;
    }
    return context->parent->xAccess(context->parent, name, flags, result_out);
}

static int csqlite_pinned_full_pathname(
    sqlite3_vfs *vfs,
    const char *name,
    int output_size,
    char *output
) {
    csqlite_pinned_registration *context = csqlite_pinned_context(vfs);
    return context->parent->xFullPathname(
        context->parent,
        name,
        output_size,
        output
    );
}

static void csqlite_free_pinned_registration(csqlite_pinned_registration *context) {
    if (context == NULL) return;
    if (context->database_fd >= 0) close(context->database_fd);
    if (context->parent_directory_fd >= 0) close(context->parent_directory_fd);
    if (context->recovery_journal_fd >= 0) close(context->recovery_journal_fd);
    if (context->journal_fd >= 0) close(context->journal_fd);
    free(context->leaf_name);
    free(context->journal_leaf_name);
    free(context->binding_leaf_name);
    free(context->vfs_name);
    free(context);
}

int csqlite_inflate_raw(
    const uint8_t *source,
    size_t source_length,
    uint8_t *destination,
    size_t destination_length
) {
    z_stream stream = {0};
    stream.next_in = (Bytef *)source;
    stream.avail_in = (uInt)source_length;
    stream.next_out = destination;
    stream.avail_out = (uInt)destination_length;

    int result = inflateInit2(&stream, -MAX_WBITS);
    if (result != Z_OK) return result;
    result = inflate(&stream, Z_FINISH);
    int end_result = inflateEnd(&stream);
    if (result != Z_STREAM_END) return result;
    if (end_result != Z_OK) return end_result;
    if (stream.avail_in != 0) return Z_DATA_ERROR;
    return stream.total_out == destination_length ? Z_OK : Z_DATA_ERROR;
}

uint32_t csqlite_crc32(const uint8_t *source, size_t source_length) {
    return (uint32_t)crc32(0L, source, (uInt)source_length);
}

int csqlite_open_pinned_rw(
    const char *canonical_path,
    int authenticated_fd,
    int parent_directory_fd,
    int authenticated_journal_fd,
    const char *leaf_name,
    sqlite3 **database_out,
    void **registration_out
) {
    if (canonical_path == NULL || canonical_path[0] != '/'
        || leaf_name == NULL || leaf_name[0] == '\0' || strchr(leaf_name, '/') != NULL
        || database_out == NULL || registration_out == NULL) {
        return SQLITE_MISUSE;
    }
    *database_out = NULL;
    *registration_out = NULL;
    csqlite_pinned_registration *context = calloc(1, sizeof(*context));
    if (context == NULL) return SQLITE_NOMEM;
    context->database_fd = -1;
    context->parent_directory_fd = -1;
    context->recovery_journal_fd = -1;
    context->journal_fd = -1;
    context->parent = sqlite3_vfs_find(NULL);
    if (context->parent == NULL) {
        csqlite_free_pinned_registration(context);
        return SQLITE_CANTOPEN;
    }
    context->database_fd = csqlite_duplicate_cloexec(authenticated_fd);
    context->parent_directory_fd = csqlite_duplicate_cloexec(parent_directory_fd);
    if (authenticated_journal_fd >= 0) {
        context->recovery_journal_fd = csqlite_duplicate_cloexec(authenticated_journal_fd);
    }
    context->leaf_name = strdup(leaf_name);
    size_t journal_length = strlen(leaf_name) + strlen("-journal") + 1;
    size_t binding_length = strlen(leaf_name) + strlen("-journal.ledger-atlas-binding") + 1;
    context->journal_leaf_name = malloc(journal_length);
    context->binding_leaf_name = malloc(binding_length);
    context->vfs_name = malloc(96);
    if (context->database_fd < 0 || context->parent_directory_fd < 0
        || (authenticated_journal_fd >= 0 && context->recovery_journal_fd < 0)
        || context->leaf_name == NULL || context->journal_leaf_name == NULL
        || context->binding_leaf_name == NULL
        || context->vfs_name == NULL) {
        csqlite_free_pinned_registration(context);
        return SQLITE_NOMEM;
    }
    snprintf(
        context->journal_leaf_name,
        journal_length,
        "%s-journal",
        leaf_name
    );
    snprintf(
        context->binding_leaf_name,
        binding_length,
        "%s-journal.ledger-atlas-binding",
        leaf_name
    );
    snprintf(
        context->vfs_name,
        96,
        "ledger-atlas-pinned-%ld-%p",
        (long)getpid(),
        (void *)context
    );
    struct stat parent = {0};
    int access_mode = fcntl(context->database_fd, F_GETFL);
    struct stat database_identity = {0};
    if (access_mode < 0 || (access_mode & O_ACCMODE) != O_RDWR
        || fstat(context->database_fd, &database_identity) != 0
        || !csqlite_safe_database_stat(&database_identity)
        || fstat(context->parent_directory_fd, &parent) != 0 || !S_ISDIR(parent.st_mode)
        || parent.st_uid != getuid() || (parent.st_mode & 0022) != 0) {
        csqlite_free_pinned_registration(context);
        return SQLITE_CANTOPEN;
    }
    context->database_identity = database_identity;
    if (!csqlite_pinned_main_is_bound(context)) {
        csqlite_free_pinned_registration(context);
        return SQLITE_CANTOPEN;
    }
    if (context->recovery_journal_fd >= 0) {
        struct stat journal = {0};
        struct stat at_parent = {0};
        if (fstat(context->recovery_journal_fd, &journal) != 0
            || !csqlite_safe_journal_stat(&journal, 1)
            || fstatat(
                context->parent_directory_fd,
                context->journal_leaf_name,
                &at_parent,
                AT_SYMLINK_NOFOLLOW
            ) != 0
            || !csqlite_same_inode(&journal, &at_parent)
            || !csqlite_journal_binding_matches(context, &journal)) {
            csqlite_free_pinned_registration(context);
            return SQLITE_CANTOPEN;
        }
        context->journal_identity = journal;
    }
    context->vfs = *context->parent;
    context->vfs.pNext = NULL;
    context->vfs.zName = context->vfs_name;
    context->vfs.szOsFile = (int)(sizeof(csqlite_pinned_file) + context->parent->szOsFile);
    context->vfs.xOpen = csqlite_pinned_open;
    context->vfs.xDelete = csqlite_pinned_delete;
    context->vfs.xAccess = csqlite_pinned_access;
    context->vfs.xFullPathname = csqlite_pinned_full_pathname;
    int result = sqlite3_vfs_register(&context->vfs, 0);
    if (result != SQLITE_OK) {
        csqlite_free_pinned_registration(context);
        return result;
    }
    sqlite3 *database = NULL;
    result = sqlite3_open_v2(
        canonical_path,
        &database,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        context->vfs_name
    );
    if (result != SQLITE_OK || database == NULL
        || sqlite3_db_readonly(database, "main") != 0) {
        if (database != NULL) sqlite3_close(database);
        if (sqlite3_vfs_unregister(&context->vfs) == SQLITE_OK) {
            csqlite_free_pinned_registration(context);
        }
        return result == SQLITE_OK ? SQLITE_READONLY : result;
    }
    *database_out = database;
    *registration_out = context;
    return SQLITE_OK;
}

int csqlite_close_pinned(sqlite3 *database, void *registration) {
    csqlite_pinned_registration *context = registration;
    if (database == NULL || context == NULL) return SQLITE_MISUSE;
    int result = sqlite3_close(database);
    if (result != SQLITE_OK) return result;
    int unregister_result = sqlite3_vfs_unregister(&context->vfs);
    if (unregister_result == SQLITE_OK) csqlite_free_pinned_registration(context);
    return unregister_result;
}

void csqlite_debug_describe_main_descriptor(sqlite3 *database, char *output, size_t size) {
    if (output == NULL || size == 0) return;
    output[0] = 0;
    sqlite3_file *file = NULL;
    if (database == NULL
        || sqlite3_file_control(database, "main", SQLITE_FCNTL_FILE_POINTER, &file) != SQLITE_OK
        || file == NULL || file->pMethods == NULL) {
        snprintf(output, size, "no main file");
        return;
    }
    csqlite_pinned_registration *registration = NULL;
    int pinned = file->pMethods == &csqlite_pinned_io_methods;
    if (pinned) {
        csqlite_pinned_file *wrapper = csqlite_pinned_file_context(file);
        registration = wrapper->context;
        file = wrapper->inner;
    }
    // SQLite's unixFile starts with pMethods, pVfs and pInode, then the descriptor.
    int descriptor = *(int *)((unsigned char *)file + 3 * sizeof(void *));
    struct stat main_identity = {0};
    int flags = fcntl(descriptor, F_GETFL);
    int flags_errno = flags < 0 ? errno : 0;
    int have_identity = fstat(descriptor, &main_identity) == 0;
    // A closed main descriptor is the case worth describing, so fall back to the pinned file's
    // recorded identity to still find other handles on the same file.
    if (!have_identity && registration != NULL) {
        main_identity = registration->database_identity;
        have_identity = 1;
    }
    int length = snprintf(
        output, size, "%s fd %d flags %d errno %d ino %llu;", pinned ? "pinned" : "plain",
        descriptor, flags, flags_errno,
        have_identity ? (unsigned long long)main_identity.st_ino : 0ULL);
    // Scan the whole descriptor table, capped so an unlimited table cannot stall a failing test.
    long table_size = sysconf(_SC_OPEN_MAX);
    int limit = table_size > 0 ? (int)(table_size < 65536 ? table_size : 65536) : 1024;
    for (int other = 0; other < limit && length > 0 && (size_t)length < size; other++) {
        struct stat value = {0};
        if (other == descriptor || fstat(other, &value) != 0) continue;
        if (!have_identity || !csqlite_same_inode(&value, &main_identity)) continue;
        length += snprintf(
            output + length, size - (size_t)length, " also fd %d flags %d;", other,
            fcntl(other, F_GETFL));
    }
}

#if defined(__APPLE__)
#include <sys/mount.h>
#else
#include <sys/vfs.h>
#endif

int csqlite_has_fine_timestamps(int descriptor) {
  struct statfs value;
  if (fstatfs(descriptor, &value) != 0) return 0;
#if defined(__APPLE__)
  return strcmp(value.f_fstypename, "apfs") == 0;
#else
  // Linux stamps change times from a coarse clock tick, so two writes a few milliseconds apart
  // can share one; callers then fall back to requiring a change time two seconds old.
  (void)value;
  return 0;
#endif
}
