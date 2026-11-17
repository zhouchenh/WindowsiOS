/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef WINIOS_VA_CENSUS_H
#define WINIOS_VA_CENSUS_H

#include <stdint.h>

/* Read-only, non-atomic observations within [lower, upper). A gap between
 * reported mappings is NOT guaranteed allocatable: kernel policies and guard
 * holes can still exclude it. An incomplete walk never counts its unknown tail.
 * Time limits are checked BETWEEN calls; an entered kernel call can exceed one. */
enum WiniosVaStatus {
    WINIOS_VA_COMPLETE, WINIOS_VA_CALL_LIMIT, WINIOS_VA_TIME_LIMIT,
    WINIOS_VA_QUERY_ERROR, WINIOS_VA_MALFORMED, WINIOS_VA_BAD_BOUNDS
};
struct WiniosVaCensus {
    uint64_t largest_gap, observed_span;
    unsigned calls, regions;
    enum WiniosVaStatus status;
    int query_error;
};
/* next: 0=region, 1=no later region, -1=error. now returns monotonic ns. */
typedef int (*WiniosVaNext)(void *, uint64_t, uint64_t *, uint64_t *);
typedef uint64_t (*WiniosVaNow)(void *);

static inline struct WiniosVaCensus
winios_va_census(uint64_t lower, uint64_t upper, unsigned max_calls,
                 uint64_t budget_ns, WiniosVaNext next, WiniosVaNow now, void *ctx) {
    struct WiniosVaCensus out = {.status = WINIOS_VA_BAD_BOUNDS};
    if (lower >= upper || !next || !now) return out;
    uint64_t cursor = lower, started = now(ctx);
    if (started == UINT64_MAX) { out.status = WINIOS_VA_TIME_LIMIT; return out; }
    for (;;) {
        if (out.calls >= max_calls) { out.status = WINIOS_VA_CALL_LIMIT; break; }
        uint64_t current = now(ctx);
        if (current == UINT64_MAX || current < started || current - started >= budget_ns) {
            out.status = WINIOS_VA_TIME_LIMIT; break;
        }
        uint64_t start = 0, length = 0;
        out.calls++;
        int rc = next(ctx, cursor, &start, &length);
        if (rc < 0) { out.status = WINIOS_VA_QUERY_ERROR; break; }
        if (rc == 1) {
            uint64_t gap = upper - cursor;
            if (gap > out.largest_gap) out.largest_gap = gap;
            cursor = upper; out.status = WINIOS_VA_COMPLETE; break;
        }
        if (rc != 0 || !length || start > UINT64_MAX - length ||
            start + length <= cursor || (out.regions && start < cursor)) {
            out.status = WINIOS_VA_MALFORMED; break;
        }
        /* The initial returned region may contain the lower scan boundary. */
        uint64_t gap_end = start < upper ? start : upper;
        if (gap_end > cursor && gap_end - cursor > out.largest_gap)
            out.largest_gap = gap_end - cursor;
        if (start >= upper) { cursor = upper; out.status = WINIOS_VA_COMPLETE; break; }
        out.regions++;
        cursor = start + length;
        if (cursor >= upper) { cursor = upper; out.status = WINIOS_VA_COMPLETE; break; }
    }
    out.observed_span = cursor - lower;
    return out;
}

static inline const char *winios_va_status_name(enum WiniosVaStatus status) {
    switch (status) {
    case WINIOS_VA_COMPLETE: return "complete";
    case WINIOS_VA_CALL_LIMIT: return "call-limit";
    case WINIOS_VA_TIME_LIMIT: return "time-limit";
    case WINIOS_VA_QUERY_ERROR: return "query-error";
    case WINIOS_VA_MALFORMED: return "malformed";
    case WINIOS_VA_BAD_BOUNDS: return "bounds-unavailable";
    }
    return "unknown";
}
#endif
