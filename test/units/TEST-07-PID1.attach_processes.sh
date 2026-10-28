#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -eux

# Assert when calling AttachProcesses on a unit without ref_uid set
# (CVE-2026-40223: an unprivileged caller must get "Access denied" instead of
# crashing PID 1 in process_is_owned_by_uid() on the invalid ref_uid).

sleeper=""

at_exit() {
    set +e

    if [ -n "$sleeper" ]; then
        kill "$sleeper" 2>/dev/null
    fi
    systemctl stop attach_and_barf.service
    rm -f /run/systemd/system/attach_and_barf.service
    systemctl daemon-reload
}

trap at_exit EXIT

mkdir -p /run/systemd/system

cat >/run/systemd/system/attach_and_barf.service <<EOF
[Service]
Type=simple
Delegate=yes
ExecStart=sleep infinity
EOF

systemctl daemon-reload
systemctl start attach_and_barf.service

# A dedicated process the privileged case below may attach. Never attach the
# test shell itself: stopping the service would signal our own cgroup.
sleep infinity &
sleeper="$!"

# Unprivileged caller, empty subcgroup path: must be refused, not crash PID 1.
run0 -u testuser \
    busctl --system call \
        org.freedesktop.systemd1 \
        /org/freedesktop/systemd1 \
        org.freedesktop.systemd1.Manager \
        AttachProcessesToUnit \
        "ssau" "attach_and_barf.service" "" 1 0 |& grep -F "Access denied" &>/dev/null

# Unprivileged caller, absolute subcgroup path: same refusal further down the
# suffix path that feeds unit_attach_pids_to_cgroup().
run0 -u testuser \
    busctl --system call \
        org.freedesktop.systemd1 \
        /org/freedesktop/systemd1 \
        org.freedesktop.systemd1.Manager \
        AttachProcessesToUnit \
        "ssau" "attach_and_barf.service" "/subgroup" 1 0 |& grep -F "Access denied" &>/dev/null

# Privileged caller keeps working on ref_uid-less delegate units: attaching an
# unrelated process as root must succeed, and the process must actually land
# in the unit's cgroup.
busctl --system call \
    org.freedesktop.systemd1 \
    /org/freedesktop/systemd1 \
    org.freedesktop.systemd1.Manager \
    AttachProcessesToUnit \
    "ssau" "attach_and_barf.service" "" 1 "$sleeper" &>/dev/null
grep -F -q "attach_and_barf.service" "/proc/$sleeper/cgroup"
