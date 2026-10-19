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
LOG = []
wd.log = LOG.append

STUCK = "Failed to lock front buffer on /dev/dri/card0: gbm_surface_lock_front_buffer failed"
HOUR = 3600


class Clock:
    def __init__(self):
        self.t = 1_000_000.0

    def __call__(self):
        return self.t


def make(live=("4248",), settings=None, answer=True, restarts=(), dry_run=False, seat=1000):
    clock = Clock()
    acted, asked = [], []
    st = {"enabled": True} if settings is None else settings

    def ask(uid):
        asked.append(uid)
        return answer() if callable(answer) else answer

    dog = wd.Watchdog(lambda: acted.append(clock.t), clock=clock, is_live=lambda pid: pid in live,
                      owner=lambda pid: 1000, seat_user=lambda: seat, settings=lambda uid: st, ask=ask,
                      restarts=[clock.t - r for r in restarts], dry_run=dry_run)
    dog.st = st
    return dog, clock, acted, asked


def feed(dog, clock, n, pid="4248", msg=STUCK, step=60, exe="/usr/bin/gnome-shell"):
    for _ in range(n):
        dog.feed({"MESSAGE": msg, "_PID": pid, "_EXE": exe})
        clock.t += step


class Detection(unittest.TestCase):
    def test_three_failures_in_ten_minutes_restart_once(self):
        dog, clock, acted, _ = make()
        feed(dog, clock, 2)
        self.assertEqual(acted, [])
        feed(dog, clock, 1)
        self.assertEqual(len(acted), 1)

    def test_scattered_failures_do_nothing(self):
        dog, clock, acted, _ = make()
        feed(dog, clock, 10, step=400)  # never 3 within 10 minutes
        self.assertEqual(acted, [])

    def test_a_one_second_burst_does_nothing(self):
        dog, clock, acted, _ = make()
        feed(dog, clock, 20, step=0.05)  # GNOME recovered from this by itself on 10-15
        self.assertEqual(acted, [])

    def test_a_burst_then_still_failing_two_minutes_later_restarts(self):
        dog, clock, acted, _ = make()
        feed(dog, clock, 20, step=0.05)
        clock.t += 60
        feed(dog, clock, 2)
        self.assertEqual(len(acted), 1)

    def test_another_program_sending_the_message_does_nothing(self):
        dog, clock, acted, _ = make()
        feed(dog, clock, 10, exe="/usr/bin/logger")
        self.assertEqual(acted, [])

    def test_other_messages_do_nothing(self):
        dog, clock, acted, _ = make()
        feed(dog, clock, 10, msg="Failed to query buffer age, got error 300d")
        self.assertEqual(acted, [])

    def test_a_gnome_shell_that_is_gone_does_nothing(self):
        dog, clock, acted, _ = make(live=())
        feed(dog, clock, 10)
        self.assertEqual(acted, [])

    def test_different_processes_are_not_added_together(self):
        dog, clock, acted, _ = make(live=("1", "2", "3"))
        for pid in ("1", "2", "3"):
            feed(dog, clock, 1, pid=pid)
        self.assertEqual(acted, [])


class OnOffAndPause(unittest.TestCase):
    def test_off_by_default(self):
        dog, clock, acted, asked = make(settings={})
        feed(dog, clock, 30)
        self.assertEqual((acted, asked), ([], []))

    def test_a_gnome_shell_of_someone_not_on_the_monitor_does_nothing(self):
        dog, clock, acted, asked = make(seat=1001)
        feed(dog, clock, 30)
        self.assertEqual((acted, asked), ([], []))

    def test_nobody_on_the_monitor_does_nothing(self):
        dog, clock, acted, _ = make(seat=None)
        feed(dog, clock, 30)
        self.assertEqual(acted, [])

    def test_a_bad_pause_value_means_not_paused_and_does_not_crash(self):
        for bad in ("soon", [1], {"a": 1}, "nan"):
            dog, clock, acted, _ = make(settings={"enabled": True, "pausedUntil": bad})
            feed(dog, clock, 3)
            self.assertEqual(len(acted), 1, bad)

    def test_turned_off(self):
        dog, clock, acted, _ = make(settings={"enabled": False})
        feed(dog, clock, 30)
        self.assertEqual(acted, [])

    def test_paused(self):
        dog, clock, acted, _ = make(settings={"enabled": True, "pausedUntil": 1_000_000.0 + 4 * HOUR})
        feed(dog, clock, 30)  # 30 minutes, still paused
        self.assertEqual(acted, [])

    def test_a_pause_that_ran_out_lets_it_act(self):
        dog, clock, acted, _ = make(settings={"enabled": True, "pausedUntil": 1_000_000.0 - 1})
        feed(dog, clock, 3)
        self.assertEqual(len(acted), 1)

    def test_turned_off_during_the_warning(self):
        holder = {}

        def answer():
            holder["dog"].st["enabled"] = False
            return True
        dog, clock, acted, asked = make(answer=answer)
        holder["dog"] = dog
        feed(dog, clock, 3)
        self.assertEqual((len(asked), acted), (1, []))

    def test_off_logs_once_not_every_minute(self):
        LOG.clear()
        dog, clock, acted, _ = make(settings={})
        feed(dog, clock, 60)
        self.assertEqual(len(LOG), 1)


class Warning(unittest.TestCase):
    def test_warns_before_restarting(self):
        dog, clock, acted, asked = make()
        feed(dog, clock, 3)
        self.assertEqual((asked, len(acted)), ([1000], 1))

    def test_dont_restart_leaves_that_desktop_alone_for_good(self):
        dog, clock, acted, asked = make(answer=False)
        feed(dog, clock, 120)  # 2 hours more of the same message
        self.assertEqual((len(asked), acted), (1, []))

    def test_dont_restart_does_not_cover_the_next_desktop(self):
        dog, clock, acted, asked = make(live=("4248", "5000"), answer=False)
        feed(dog, clock, 3)
        dog.ask = lambda uid: True
        feed(dog, clock, 3, pid="5000")
        self.assertEqual(len(acted), 1)

    def test_dry_run_never_warns_or_acts(self):
        dog, clock, acted, asked = make(dry_run=True)
        feed(dog, clock, 20)
        self.assertEqual((acted, asked), ([], []))


class NoEndlessLoop(unittest.TestCase):
    def test_no_second_restart_within_an_hour(self):
        dog, clock, acted, _ = make(live=("4248", "5000"))
        feed(dog, clock, 3)
        feed(dog, clock, 30, pid="5000")  # stuck again right after the restart, 30 min
        self.assertEqual(len(acted), 1)
        feed(dog, clock, 40, pid="5000")  # past the hour: second try
        self.assertEqual(len(acted), 2)

    def test_gives_up_after_two_restarts_in_a_day(self):
        dog, clock, acted, _ = make(live=("1", "2", "3"))
        feed(dog, clock, 3, pid="1")
        clock.t += 2 * HOUR
        feed(dog, clock, 3, pid="2")
        clock.t += 2 * HOUR
        feed(dog, clock, 600, pid="3")  # stuck for 10 more hours
        self.assertEqual(len(acted), 2)

    def test_tries_again_once_a_restart_held_for_a_day(self):
        dog, clock, acted, _ = make(live=("1", "2", "3"))
        feed(dog, clock, 3, pid="1")
        clock.t += 2 * HOUR
        feed(dog, clock, 3, pid="2")
        clock.t += 25 * HOUR
        feed(dog, clock, 3, pid="3")
        self.assertEqual(len(acted), 3)

    def test_the_count_survives_a_restart_of_the_watchdog(self):
        dog, clock, acted, _ = make(restarts=(5 * HOUR, 2 * HOUR))
        feed(dog, clock, 30)
        self.assertEqual(acted, [])


if __name__ == "__main__":
    unittest.main()
