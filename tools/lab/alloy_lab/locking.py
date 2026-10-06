"""Cooperating host-wide shared/exclusive leases. Author: Timur Isaev."""

import fcntl
import os
from pathlib import Path
import stat
import time

from .common import Invalid, require
from .storage import private_directory

HOST_ROOT = Path('/private/tmp/alloy-lab-host')


class Lease:
    def __init__(self, path, exclusive=True):
        self.fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        info = os.fstat(self.fd)
        try:
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1 and
                    info.st_mode & 0o077 == 0, "lock:unsafe_file")
            self.operation = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
        except BaseException:
            self.close()
            raise

    def try_acquire(self):
        try:
            fcntl.flock(self.fd, self.operation | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            return False

    def close(self):
        if self.fd is not None:
            # Do not LOCK_UN: an inherited descriptor must retain the lease
            # until its worker has completed cleanup and closed its own copy.
            os.close(self.fd)
            self.fd = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


class HostLease(Lease):
    def __init__(self, exclusive, root=HOST_ROOT):
        self.root = private_directory(root)
        super().__init__(self.root / 'resource.lock', exclusive)

    def acquire(self, deadline, stop=lambda: False):
        # A waiting exclusive participant keeps this admission gate, so new
        # shared participants cannot continuously overtake an exclusive waiter.
        with Lease(self.root / 'admission.lock') as gate:
            for lease in (gate, self):
                while not lease.try_acquire():
                    if stop():
                        raise Invalid('lock:cancelled')
                    if time.time() >= deadline:
                        raise Invalid('lock:deadline')
                    time.sleep(0.02)
                if stop() or time.time() >= deadline:
                    raise Invalid('lock:cancelled_or_deadline')
        return self


def available(exclusive=True):
    with HostLease(exclusive) as resource, Lease(resource.root / 'admission.lock') as gate:
        return gate.try_acquire() and resource.try_acquire()
