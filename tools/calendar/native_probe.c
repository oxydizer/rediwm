/* Noninstalled Phase 0 dependency probe, not a calendar backend or sync engine.
 * Run only against a fresh private database owned by the qualification harness.
 * Detached exceptions are preserved and inspected, not expanded/merged here.
 */
#include <libical/ical.h>
#include <sqlite3.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char fixture[] =
    "BEGIN:VCALENDAR\r\n"
    "VERSION:2.0\r\n"
    "PRODID:-//RediWM//Phase 0 probe//EN\r\n"
    "BEGIN:VTIMEZONE\r\n"
    "TZID:Pacific/Auckland\r\n"
    "BEGIN:STANDARD\r\n"
    "DTSTART:20260405T030000\r\n"
    "TZOFFSETFROM:+1300\r\n"
    "TZOFFSETTO:+1200\r\n"
    "RRULE:FREQ=YEARLY;BYMONTH=4;BYDAY=1SU\r\n"
    "END:STANDARD\r\n"
    "BEGIN:DAYLIGHT\r\n"
    "DTSTART:20260927T020000\r\n"
    "TZOFFSETFROM:+1200\r\n"
    "TZOFFSETTO:+1300\r\n"
    "RRULE:FREQ=YEARLY;BYMONTH=9;BYDAY=-1SU\r\n"
    "END:DAYLIGHT\r\n"
    "END:VTIMEZONE\r\n"
    "BEGIN:VEVENT\r\n"
    "UID:phase0-series\r\n"
    "DTSTAMP:20261031T000000Z\r\n"
    "DTSTART;TZID=Pacific/Auckland:20260926T090000\r\n"
    "DTEND;TZID=Pacific/Auckland:20260926T100000\r\n"
    "RRULE:FREQ=DAILY;COUNT=5\r\n"
    "EXDATE;TZID=Pacific/Auckland:20260930T090000\r\n"
    "SUMMARY:Dependency probe\r\n"
    "X-EXTERNAL-STATE:preserve-me\r\n"
    "END:VEVENT\r\n"
    "BEGIN:VEVENT\r\n"
    "UID:phase0-series\r\n"
    "DTSTAMP:20261031T000000Z\r\n"
    "RECURRENCE-ID;TZID=Pacific/Auckland:20260928T090000\r\n"
    "DTSTART;TZID=Pacific/Auckland:20260928T110000\r\n"
    "DTEND;TZID=Pacific/Auckland:20260928T120000\r\n"
    "SUMMARY:Moved occurrence\r\n"
    "END:VEVENT\r\n"
    "BEGIN:VEVENT\r\n"
    "UID:phase0-series\r\n"
    "DTSTAMP:20261031T000000Z\r\n"
    "RECURRENCE-ID;TZID=Pacific/Auckland:20260929T090000\r\n"
    "DTSTART;TZID=Pacific/Auckland:20260929T090000\r\n"
    "DTEND;TZID=Pacific/Auckland:20260929T100000\r\n"
    "STATUS:CANCELLED\r\n"
    "END:VEVENT\r\n"
    "END:VCALENDAR\r\n";

static void require(bool condition, const char *stage)
{
    if (!condition) {
        fprintf(stderr, "native calendar probe failed: %s\n", stage);
        exit(EXIT_FAILURE);
    }
}

static bool property_equals(icalcomponent *event, icalproperty_kind kind,
                            const char *value)
{
    icalproperty *property = icalcomponent_get_first_property(event, kind);
    const char *actual = property ? icalproperty_get_value_as_string(property) : NULL;
    return actual && strcmp(actual, value) == 0;
}

static void check_zone(icalcomponent *event, icalproperty_kind kind)
{
    icalproperty *property = icalcomponent_get_first_property(event, kind);
    require(property != NULL, "timezone property exists");
    icalparameter *parameter = icalproperty_get_first_parameter(property, ICAL_TZID_PARAMETER);
    const char *tzid = parameter ? icalparameter_get_tzid(parameter) : NULL;
    require(tzid && strcmp(tzid, "Pacific/Auckland") == 0, "timezone parameter preserved");
}

static icalcomponent *check_components(icalcomponent *calendar)
{
    require(calendar && icalcomponent_isa(calendar) == ICAL_VCALENDAR_COMPONENT,
            "parse VCALENDAR");
    require(icalcomponent_count_errors(calendar) == 0, "no parse errors");
    require(icalcomponent_get_timezone(calendar, "Pacific/Auckland") != NULL,
            "embedded timezone preserved");
    icalcomponent *master = NULL;
    unsigned moved = 0, cancelled = 0, count = 0;
    for (icalcomponent *event = icalcomponent_get_first_component(calendar, ICAL_VEVENT_COMPONENT);
         event; event = icalcomponent_get_next_component(calendar, ICAL_VEVENT_COMPONENT)) {
        require(++count <= 3, "bounded component count");
        const char *uid = icalcomponent_get_uid(event);
        require(uid && strcmp(uid, "phase0-series") == 0, "series identity preserved");
        check_zone(event, ICAL_DTSTART_PROPERTY);
        if (icaltime_is_null_time(icalcomponent_get_recurrenceid(event))) {
            require(!master, "one series master");
            master = event;
            require(property_equals(event, ICAL_RRULE_PROPERTY, "FREQ=DAILY;COUNT=5"),
                    "recurrence rule preserved");
            require(property_equals(event, ICAL_EXDATE_PROPERTY, "20260930T090000"),
                    "excluded occurrence preserved");
            require(property_equals(event, ICAL_X_PROPERTY, "preserve-me"),
                    "unrecognized metadata preserved");
        } else {
            check_zone(event, ICAL_RECURRENCEID_PROPERTY);
            if (icalcomponent_get_status(event) == ICAL_STATUS_CANCELLED) {
                require(property_equals(event, ICAL_RECURRENCEID_PROPERTY, "20260929T090000"),
                        "cancelled occurrence retains original identity");
                cancelled++;
            } else {
                require(property_equals(event, ICAL_RECURRENCEID_PROPERTY, "20260928T090000"),
                        "moved occurrence retains original identity");
                require(property_equals(event, ICAL_DTSTART_PROPERTY, "20260928T110000"),
                        "moved start remains separate from identity");
                moved++;
            }
        }
    }
    require(count == 3 && master && moved == 1 && cancelled == 1, "exception components preserved");
    return master;
}

struct expansion {
    icaltimezone *zone;
    unsigned count;
    icaltime_t previous;
};

static void occurrence(icalcomponent *event, const struct icaltime_span *span, void *data)
{
    (void)event;
    struct expansion *result = data;
    require(result->count < 4, "bounded recurrence output");
    struct icaltimetype local = icaltime_from_timet_with_zone(span->start, false, result->zone);
    require(local.year == 2026 && local.month == 9 && local.day == 26 + (int)result->count &&
                local.hour == 9 && local.minute == 0, "wall time preserved across DST");
    require(span->end - span->start == 3600, "occurrence duration preserved");
    if (result->count)
        require(span->start - result->previous == (result->count == 1 ? 23 : 24) * 3600,
                "UTC spacing changes across DST");
    result->previous = span->start;
    result->count++;
}

static void check_expansion(icalcomponent *calendar)
{
    icalcomponent *master = check_components(calendar);
    struct expansion result = { .zone = icalcomponent_get_timezone(calendar, "Pacific/Auckland") };
    icalcomponent_foreach_recurrence(master, icaltime_from_string("20260925T000000Z"),
                                    icaltime_from_string("20261001T000000Z"), occurrence, &result);
    require(result.count == 4, "bounded master expansion honors EXDATE");
}

static void sql(sqlite3 *db, const char *statement)
{
    require(sqlite3_exec(db, statement, NULL, NULL, NULL) == SQLITE_OK, "SQLite statement");
}

static void insert_remote(sqlite3 *db, const char *calendar, int revision)
{
    sqlite3_stmt *statement = NULL;
    require(sqlite3_prepare_v2(db, "INSERT INTO remote VALUES('phase0-series',?1,?2)",
                              -1, &statement, NULL) == SQLITE_OK, "prepare cache insert");
    require(sqlite3_bind_int(statement, 1, revision) == SQLITE_OK &&
            sqlite3_bind_text(statement, 2, calendar, -1, SQLITE_TRANSIENT) == SQLITE_OK,
            "bind cache insert");
    require(sqlite3_step(statement) == SQLITE_DONE, "insert cache record");
    require(sqlite3_finalize(statement) == SQLITE_OK, "finalize cache insert");
}

static int scalar(sqlite3 *db, const char *query)
{
    sqlite3_stmt *statement = NULL;
    require(sqlite3_prepare_v2(db, query, -1, &statement, NULL) == SQLITE_OK, "prepare scalar query");
    require(sqlite3_step(statement) == SQLITE_ROW, "read scalar row");
    int result = sqlite3_column_int(statement, 0);
    require(sqlite3_step(statement) == SQLITE_DONE, "only one scalar row");
    require(sqlite3_finalize(statement) == SQLITE_OK, "finalize scalar query");
    return result;
}

static void check_store(const char *path, const char *calendar)
{
    sqlite3 *db = NULL;
    require(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) == SQLITE_OK,
            "open private database");
    /* Refuse a pre-existing schema before any PRAGMA or write. */
    require(scalar(db, "SELECT count(*) FROM sqlite_master") == 0, "database must be fresh");
    sql(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; BEGIN IMMEDIATE;"
            "CREATE TABLE remote(uid TEXT PRIMARY KEY,revision INTEGER NOT NULL,ical TEXT NOT NULL);"
            "CREATE TABLE pending(id TEXT PRIMARY KEY,base_revision INTEGER NOT NULL,edit TEXT NOT NULL);");
    insert_remote(db, calendar, 1);
    sql(db, "INSERT INTO pending VALUES('local-1',1,'offline title edit'); COMMIT;"
            "BEGIN IMMEDIATE; UPDATE remote SET revision=99; DELETE FROM pending; ROLLBACK;");
    require(scalar(db, "SELECT revision FROM remote") == 1 &&
            scalar(db, "SELECT count(*) FROM pending") == 1, "rollback preserves cache and pending edit");
    sql(db, "BEGIN IMMEDIATE; DELETE FROM remote;");
    insert_remote(db, calendar, 2);
    sql(db, "COMMIT;");
    require(sqlite3_close(db) == SQLITE_OK, "close database");
    require(sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, NULL) == SQLITE_OK, "reopen database");
    require(scalar(db, "SELECT revision FROM remote") == 2 &&
            scalar(db, "SELECT count(*) FROM pending WHERE id='local-1' AND base_revision=1 "
                       "AND edit='offline title edit'") == 1,
            "pending edit and base revision survive cache replacement and reopen");
    sqlite3_stmt *statement = NULL;
    require(sqlite3_prepare_v2(db, "SELECT ical FROM remote", -1, &statement, NULL) == SQLITE_OK &&
            sqlite3_step(statement) == SQLITE_ROW, "load durable calendar");
    const char *stored = (const char *)sqlite3_column_text(statement, 0);
    require(stored && strcmp(stored, calendar) == 0, "calendar bytes survive reopen");
    icalcomponent *restored = icalparser_parse_string(stored);
    check_expansion(restored);
    icalcomponent_free(restored);
    require(sqlite3_finalize(statement) == SQLITE_OK, "finalize calendar load");
    require(sqlite3_close(db) == SQLITE_OK, "close reopened database");
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: native-probe FRESH_PRIVATE_DATABASE\n");
        return EXIT_FAILURE;
    }
    icalcomponent *original = icalparser_parse_string(fixture);
    check_expansion(original);
    char *rendered = icalcomponent_as_ical_string_r(original);
    require(rendered != NULL, "serialize calendar");
    icalcomponent *roundtrip = icalparser_parse_string(rendered);
    check_expansion(roundtrip);
    check_store(argv[1], rendered);
    icalcomponent_free(roundtrip);
    icalmemory_free_buffer(rendered);
    icalcomponent_free(original);
    icaltimezone_free_builtin_timezones();
    puts("{\"status\":\"pass\",\"ical_roundtrip\":true,\"dst_master_expansion\":true,"
         "\"exception_identity_preservation\":true,\"sqlite_rollback\":true,"
         "\"pending_survives_cache_refresh_and_reopen\":true,"
         "\"exception_overlay_applied\":false,\"provider_qualification\":false}");
    return EXIT_SUCCESS;
}
