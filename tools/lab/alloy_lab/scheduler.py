"""Queue admission and independent worker supervision. Author: Timur Isaev."""

import os
from pathlib import Path
import subprocess
import sys
import time

from .common import Invalid, require
from .locking import HOST_ROOT, HostLease
from .queue import Queue

CLI = Path(__file__).resolve().parents[1] / 'lab.py'


def work_one(root, lock_root=HOST_ROOT, after_claim=None):
    queue = Queue(root)
    try:
        queue.recover()
        for job_id in queue.candidates():
            with queue.lease(job_id) as job_lease:
                if not job_lease.try_acquire():
                    continue
                job = queue.get(job_id)
                with HostLease(job['definition']['timing_sensitive'], lock_root) as host_lease:
                    try:
                        host_lease.acquire(job['deadline'], lambda: queue.cancelled(job_id))
                    except Invalid:
                        queue.candidates()
                        return job_id
                    job = queue.claim(job_id)
                    if job is None:
                        continue
                    if after_claim:
                        after_claim(job)
                    parent_read, parent_write = os.pipe()
                    try:
                        command = [sys.executable, '-B', str(CLI), '_worker', str(queue.root), job_id,
                                   job['owner'], str(parent_read), str(job_lease.fd), str(host_lease.fd)]
                        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, start_new_session=True,
                            pass_fds=(parent_read, job_lease.fd, host_lease.fd))
                        os.close(parent_read)
                        parent_read = None
                        # The parent retains copies while waiting; the child holds
                        # the same open descriptions after an abrupt parent death.
                        try:
                            child.wait(timeout=max(1, min(job['deadline'] - time.time(), job['definition']['timeout_seconds'])) + 110)
                        except (KeyboardInterrupt, subprocess.TimeoutExpired):
                            os.close(parent_write)
                            parent_write = None
                            child.wait(timeout=105)
                    finally:
                        for fd in (parent_read, parent_write):
                            if fd is not None:
                                os.close(fd)
                    # Child publication is checked, not inferred from its exit.
                    if queue.get(job_id)['state'] == 'RUNNING':
                        # Our own descriptor still holds the lease here; after
                        # leaving this scope the next recovery can claim it.
                        queue.finish(job_id, job['owner'], 'INTERRUPTED', failure='worker exited without a result')
                    return job_id
        return None
    finally:
        queue.close()


def worker(root, job_id, owner, parent_fd, job_fd, host_fd):
    from .runner import execute
    queue = Queue(root)
    try:
        job = queue.get(job_id)
        require(job['state'] == 'RUNNING' and job['owner'] == owner, 'worker:stale_owner')
        try:
            record, path = execute(job, queue, parent_fd, (job_fd, host_fd))
            reason = '; '.join(item['code'] for item in record['failures']) or None
            queue.finish(job_id, owner, record['state'], path, reason)
            return 0 if record['state'] == 'COMPLETED' else 1
        except Exception as error:
            queue.finish(job_id, owner, 'FAILED', failure=f'worker failure: {error}')
            return 1
    finally:
        queue.close()
        for fd in (parent_fd, job_fd, host_fd):
            os.close(fd)
