#include "DatabaseTestSupport.h"
#include <sqlite3.h>

int retrace_test_enable_defensive(sqlite3 *database, int *enabled) {
    return sqlite3_db_config(database, SQLITE_DBCONFIG_DEFENSIVE, 1, enabled);
}
