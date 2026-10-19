"""Run: python3 -m unittest linux-host/display-watchdog/test_watchdog.py"""
import importlib.machinery
import importlib.util
import os
import unittest

_path = os.path.join(os.path.dirname(__file__), "sill-display-watchdog")
_loader = importlib.machinery.SourceFileLoader("watchdog", _path)
_spec = importlib.util.spec_from_loader("watchdog", _loader)
wd = importlib.util.module_from_spec(_spec)
_loader.exec_module(wd)
wd.log = lambda msg: None

STUCK = "Failed to lock front buffer on /dev/dri/card0: gbm_surface_lock_front_buffer failed"


class Clock:
    def __init__(self):
        self.t = 100_000.0

    def __call__(self):
        return self.t


def make(live=("4248",), last_restart=0.0, dry_run=False):
    clock = Clock()
    acted = []
    dog = wd.Watchdog(lambda: acted.append(clock.t), clock=clock, is_live=lambda pid: pid in live,
                      last_restart=last_restart, dry_run=dry_run)
    return dog, clock, acted


def feed(dog, clock, n, pid="4248", msg=STUCK, step=60, exe="/usr/bin/gnome-shell"):
    for _ in range(n):
        dog.feed({"MESSAGE": msg, "_PID": pid, "_EXE": exe})
        clock.t += step


class WatchdogTest(unittest.TestCase):
    def test_three_failures_in_ten_minutes_restart_once(self):
        dog, clock, acted = make()
        feed(dog, clock, 2)
        self.assertEqual(acted, [])
        feed(dog, clock, 1)
        self.assertEqual(len(acted), 1)

    def test_scattered_failures_do_nothing(self):
        dog, clock, acted = make()
        feed(dog, clock, 10, step=400)  # never 3 within 10 minutes
        self.assertEqual(acted, [])

    def test_a_one_second_burst_does_nothing(self):
        dog, clock, acted = make()
        feed(dog, clock, 20, step=0.05)  # GNOME recovered from this by itself on 10-15
        self.assertEqual(acted, [])

    def test_a_burst_then_still_failing_two_minutes_later_restarts(self):
        dog, clock, acted = make()
        feed(dog, clock, 20, step=0.05)
        clock.t += 60
        feed(dog, clock, 2)
        self.assertEqual(len(acted), 1)

    def test_another_program_sending_the_message_does_nothing(self):
        dog, clock, acted = make()
        feed(dog, clock, 10, exe="/usr/bin/logger")
        self.assertEqual(acted, [])

    def test_other_messages_do_nothing(self):
        dog, clock, acted = make()
        feed(dog, clock, 10, msg="Failed to query buffer age, got error 300d")
        self.assertEqual(acted, [])

    def test_a_gnome_shell_that_is_gone_does_nothing(self):
        dog, clock, acted = make(live=())
        feed(dog, clock, 10)
        self.assertEqual(acted, [])

    def test_different_processes_are_not_added_together(self):
        dog, clock, acted = make(live=("1", "2", "3"))
        for pid in ("1", "2", "3"):
            feed(dog, clock, 1, pid=pid)
        self.assertEqual(acted, [])

    def test_no_second_restart_within_an_hour(self):
        dog, clock, acted = make(live=("4248", "5000"))
        feed(dog, clock, 3)
        feed(dog, clock, 30, pid="5000")  # still stuck after the restart, 30 min
        self.assertEqual(len(acted), 1)
        feed(dog, clock, 40, pid="5000")  # past the hour
        self.assertEqual(len(acted), 2)

    def test_cooldown_survives_a_restart_of_the_watchdog(self):
        dog, clock, acted = make(last_restart=100_000.0 - 60)
        feed(dog, clock, 5)
        self.assertEqual(acted, [])

    def test_dry_run_never_acts(self):
        dog, clock, acted = make(dry_run=True)
        feed(dog, clock, 20)
        self.assertEqual(acted, [])


if __name__ == "__main__":
    unittest.main()
