/* SPDX-License-Identifier: LGPL-2.1-or-later */

#include "journald-context.h"
#include "journald-manager.h"
#include "tests.h"
#include "time-util.h"

/* Fork-only regression test for G1b (journal forward flood): the forward sinks (syslog/kmsg/console/wall)
 * must share one per-message rate-limit decision with storage, so that a storage-suppressed message is never
 * forwarded. manager_check_ratelimit() is that single decision point; the transports call it before the
 * forwards and storage honors it via manager_dispatch_message_prechecked(). */
TEST(manager_check_ratelimit) {
        Manager m = {};
        ClientContext with_unit = {}, without_unit = {}, disabled = {};
        char unit[] = "test-forward-flood.service";

        /* Point the space check at a directory that always exists, so the helper never asserts. The bucket
         * itself does not depend on the reported space at this size. */
        m.runtime_storage.path = (char*) "/tmp";

        with_unit.unit = unit;
        with_unit.log_ratelimit_interval = USEC_PER_SEC;
        with_unit.log_ratelimit_burst = 10;

        /* Within burst: every message is allowed exactly once. */
        for (unsigned i = 0; i < 10; i++)
                assert_se(manager_check_ratelimit(&m, &with_unit, LOG_DEBUG) == 1);

        /* Past burst inside the window: suppressed, so forwards and storage must both drop. */
        for (unsigned i = 0; i < 5; i++)
                assert_se(manager_check_ratelimit(&m, &with_unit, LOG_DEBUG) == 0);

        /* A different priority pool with the same unit is not rate limited. */
        assert_se(manager_check_ratelimit(&m, &with_unit, LOG_EMERG) == 1);

        /* Still suppressed on the exhausted pool. */
        assert_se(manager_check_ratelimit(&m, &with_unit, LOG_DEBUG) == 0);

        /* Senders without a unit are never limited, exactly like the storage path. */
        for (unsigned i = 0; i < 20; i++) {
                assert_se(manager_check_ratelimit(&m, &without_unit, LOG_DEBUG) > 0);
                assert_se(manager_check_ratelimit(&m, NULL, LOG_DEBUG) > 0);
        }

        /* A disabled limiter (zero interval/burst) never suppresses. */
        disabled.unit = unit;
        for (unsigned i = 0; i < 5; i++)
                assert_se(manager_check_ratelimit(&m, &disabled, LOG_DEBUG) > 0);
}

DEFINE_TEST_MAIN(LOG_INFO);
