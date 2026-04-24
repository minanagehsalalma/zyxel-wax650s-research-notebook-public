#!/usr/bin/env python3
import argparse
import ctypes
from ctypes import c_int, c_void_p


IPC_CREAT = 0o1000
IPC_RMID = 0
MSG_RMID = 0
SETVAL = 16
MODE_666 = 0o666

SEM_KEYS = [
    0x6E010545,
    0x72010545,
]

SHM_KEYS = []
MSG_KEYS = []

CLEANUP_ONLY_SEM_KEYS = [
    0x12340001,
    0x12340003,
    0x11111111,
]

CLEANUP_ONLY_SHM_KEYS = [
    (0x12340002, 1257176),
    (0x12340004, 696),
    (0x11111111, 147464),
    (0x11111112, 24),
]

CLEANUP_ONLY_MSG_KEYS = [
    0x64010147,
]

UAM_LOCKOUT_SEM_KEYS = [
    0x11111111,
]

UAM_LOCKOUT_SHM_KEYS = [
    (0x11111111, 147464),
    (0x11111112, 24),
]


class Semun(ctypes.Union):
    _fields_ = [
        ("val", c_int),
        ("buf", c_void_p),
        ("array", c_void_p),
        ("__buf", c_void_p),
    ]


libc = ctypes.CDLL("libc.so.6", use_errno=True)
libc.semget.argtypes = [c_int, c_int, c_int]
libc.semget.restype = c_int
libc.semctl.argtypes = [c_int, c_int, c_int, Semun]
libc.semctl.restype = c_int
libc.shmget.argtypes = [c_int, ctypes.c_size_t, c_int]
libc.shmget.restype = c_int
libc.shmctl.argtypes = [c_int, c_int, c_void_p]
libc.shmctl.restype = c_int
libc.msgget.argtypes = [c_int, c_int]
libc.msgget.restype = c_int
libc.msgctl.argtypes = [c_int, c_int, c_void_p]
libc.msgctl.restype = c_int


def ensure_sem(key: int) -> None:
    semid = libc.semget(key, 1, IPC_CREAT | MODE_666)
    if semid < 0:
        err = ctypes.get_errno()
        raise OSError(err, f"semget failed for {hex(key)}")
    if libc.semctl(semid, 0, SETVAL, Semun(val=1)) < 0:
        err = ctypes.get_errno()
        raise OSError(err, f"semctl SETVAL failed for {hex(key)}")


def cleanup_sem(key: int) -> None:
    semid = libc.semget(key, 1, MODE_666)
    if semid < 0:
        return
    if libc.semctl(semid, 0, IPC_RMID, Semun(val=0)) < 0:
        err = ctypes.get_errno()
        raise OSError(err, f"semctl IPC_RMID failed for {hex(key)}")


def ensure_shm(key: int, size: int) -> None:
    shmid = libc.shmget(key, size, IPC_CREAT | MODE_666)
    if shmid < 0:
        err = ctypes.get_errno()
        raise OSError(err, f"shmget failed for {hex(key)}")


def cleanup_shm(key: int, size: int) -> None:
    shmid = libc.shmget(key, size, MODE_666)
    if shmid < 0:
        return
    if libc.shmctl(shmid, IPC_RMID, None) < 0:
        err = ctypes.get_errno()
        raise OSError(err, f"shmctl IPC_RMID failed for {hex(key)}")


def ensure_msg(key: int) -> None:
    msgid = libc.msgget(key, IPC_CREAT | MODE_666)
    if msgid < 0:
        err = ctypes.get_errno()
        raise OSError(err, f"msgget failed for {hex(key)}")


def cleanup_msg(key: int) -> None:
    msgid = libc.msgget(key, MODE_666)
    if msgid < 0:
        return
    if libc.msgctl(msgid, MSG_RMID, None) < 0:
        err = ctypes.get_errno()
        raise OSError(err, f"msgctl IPC_RMID failed for {hex(key)}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Seed Zyxel SysV IPC keys for local emulation")
    parser.add_argument("mode", choices=("up", "down"))
    parser.add_argument(
        "--include-uam-lockout",
        action="store_true",
        help="Seed the 0x11111111 UAM lockout IPC objects used by uamd",
    )
    args = parser.parse_args()

    sem_keys = list(SEM_KEYS)
    shm_keys = list(SHM_KEYS)
    if args.include_uam_lockout:
        sem_keys.extend(UAM_LOCKOUT_SEM_KEYS)
        shm_keys.extend(UAM_LOCKOUT_SHM_KEYS)

    if args.mode == "up":
        for key in sem_keys:
            ensure_sem(key)
        for key, size in shm_keys:
            ensure_shm(key, size)
        for key in MSG_KEYS:
            ensure_msg(key)
    else:
        for key in SEM_KEYS + CLEANUP_ONLY_SEM_KEYS:
            cleanup_sem(key)
        for key, size in SHM_KEYS + CLEANUP_ONLY_SHM_KEYS:
            cleanup_shm(key, size)
        for key in MSG_KEYS + CLEANUP_ONLY_MSG_KEYS:
            cleanup_msg(key)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
