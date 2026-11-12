#include "sqlite3.h"
#include "DatabaseNativeSupport.h"

int retrace_native_preupdate_install(sqlite3 *db, retrace_native_preupdate_callback callback, void *context) {
    if (!sqlite3_compileoption_used("ENABLE_PREUPDATE_HOOK")) return SQLITE_MISUSE;
    sqlite3_preupdate_hook(db, callback, context);
    return SQLITE_OK;
}
void retrace_native_preupdate_remove(sqlite3 *db) { sqlite3_preupdate_hook(db, 0, 0); }
int retrace_native_preupdate_count(sqlite3 *db) { return sqlite3_preupdate_count(db); }
int retrace_native_preupdate_old(sqlite3 *db, int index, sqlite3_value **value) { return sqlite3_preupdate_old(db, index, value); }
int retrace_native_preupdate_new(sqlite3 *db, int index, sqlite3_value **value) { return sqlite3_preupdate_new(db, index, value); }
