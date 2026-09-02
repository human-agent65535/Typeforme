"""JSON-line workers with bounded waits and explicit failure propagation."""

import json
import os
import selectors
import signal
import subprocess
import threading


def own_process_group(parent_pid):
    """Keep native workers owned by the app even after an app crash."""
    if parent_pid <= 1 or os.getppid() != parent_pid:
        raise ValueError('Service parent is no longer alive')
    os.setpgid(0, 0)

    def watch_parent():
        while not threading.Event().wait(1):
            if os.getppid() != parent_pid:
                os.killpg(os.getpid(), signal.SIGKILL)

    threading.Thread(target=watch_parent, daemon=True).start()


class LineTool:
    def __init__(self, command, timeout=90):
        self.process = subprocess.Popen(
            command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            text=True, bufsize=1,
        )
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.timeout = timeout

    def query(self, line):
        if self.process.poll() is not None:
            raise RuntimeError('Decoder worker exited')
        self.process.stdin.write(line + '\n')
        self.process.stdin.flush()
        if not self.selector.select(self.timeout):
            # An unanswered request must not become the next request's answer.
            self.close()
            raise TimeoutError('Decoder worker exceeded its response budget')
        response = self.process.stdout.readline()
        if not response:
            raise RuntimeError('Decoder worker closed its output')
        value = json.loads(response)
        if 'error' in value:
            raise RuntimeError(value['error'])
        return value

    def close(self):
        self.selector.close()
        if self.process.stdin and not self.process.stdin.closed:
            try:
                self.process.stdin.close()
            except BrokenPipeError:
                pass
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.process.stdout:
            self.process.stdout.close()
