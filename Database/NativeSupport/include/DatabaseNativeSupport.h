#ifndef RETRACE_DATABASE_NATIVE_SUPPORT_H
#define RETRACE_DATABASE_NATIVE_SUPPORT_H
#include <stdint.h>
struct sqlite3;
struct sqlite3_value;
typedef void (*retrace_native_preupdate_callback)(void *, struct sqlite3 *, int, const char *, const char *, int64_t, int64_t);
int retrace_native_preupdate_install(struct sqlite3 *, retrace_native_preupdate_callback, void *);
void retrace_native_preupdate_remove(struct sqlite3 *);
int retrace_native_preupdate_count(struct sqlite3 *);
int retrace_native_preupdate_old(struct sqlite3 *, int, struct sqlite3_value **);
int retrace_native_preupdate_new(struct sqlite3 *, int, struct sqlite3_value **);
#endif
