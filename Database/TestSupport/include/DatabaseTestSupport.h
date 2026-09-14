#ifndef RETRACE_DATABASE_TEST_SUPPORT_H
#define RETRACE_DATABASE_TEST_SUPPORT_H

struct sqlite3;
int retrace_test_enable_defensive(struct sqlite3 *database, int *enabled);

#endif
