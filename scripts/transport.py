#!/usr/bin/env python3
"""Transport layer for the UART test controller.

The host-side test framework originally reached the device by writing a vector image to
a file, launching a simulator, and reading a results file back. That works, but it means
the framework is coupled to simulation: none of the code that talks to the device would
survive contact with real hardware, because there is no serial stack in it anywhere.

This module puts a transport abstraction underneath instead. The test logic -- generate
vectors, send, receive, score -- becomes identical whether the far end is a simulator or
a board on a USB cable, and the only thing that changes is which Transport is
constructed.

Three implementations:

  SimulationTransport  file-image handoff plus a simulator subprocess (what the framework
                       already did, kept working, now behind the interface)
  SerialTransport      pyserial against a real device node, 8N1, configurable baud
  PtyLoopbackTransport a SerialTransport pointed at a pseudo-terminal pair with an echo
                       thread on the far end

The third one exists so the serial path is not dead code until hardware shows up. It is
a genuine pyserial port with genuine termios configuration -- open, baud rate, byte size,
parity, stop bits, timeouts -- exercised end to end. Swapping in a real board is then a
change of port name, not a change of code.

Self-test (no hardware required):

    python3 scripts/transport.py --selftest
"""

import abc
import argparse
import os
import tty
import pathlib
import subprocess
import sys
import threading
import time

try:
    import serial
except ImportError:
    serial = None


class Transport(abc.ABC):
    """A byte pipe to the device under test."""

    @abc.abstractmethod
    def open(self):
        ...

    @abc.abstractmethod
    def close(self):
        ...

    @abc.abstractmethod
    def write(self, data: bytes) -> int:
        ...

    @abc.abstractmethod
    def read(self, count: int, timeout: float = 1.0) -> bytes:
        ...

    def __enter__(self):
        self.open()
        return self

    def __exit__(self, *exc):
        self.close()
        return False


class SerialTransport(Transport):
    """Real serial port via pyserial.

    Defaults are 8N1, which is what rtl/uart.v implements: one start bit, eight data bits
    LSB first, no parity, one stop bit. Framing has to match on both ends or the receiver
    samples the wrong bits and reports a framing error -- which the RTL does detect, and
    which is worth provoking deliberately once hardware is attached.
    """

    def __init__(self, port, baudrate=115200, timeout=1.0):
        self.port = port
        self.baudrate = baudrate
        self.timeout = timeout
        self._ser = None

    def open(self):
        if serial is None:
            raise RuntimeError("pyserial is not installed (pip install pyserial)")
        self._ser = serial.Serial(
            port=self.port,
            baudrate=self.baudrate,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=self.timeout,
        )
        # A device that was mid-frame when we attached would otherwise hand us a
        # fragment as if it were the first byte of our own test.
        self._ser.reset_input_buffer()
        self._ser.reset_output_buffer()
        return self

    def close(self):
        if self._ser is not None:
            self._ser.close()
            self._ser = None

    def write(self, data: bytes) -> int:
        n = self._ser.write(data)
        self._ser.flush()          # block until the bytes are actually on the wire
        return n

    def read(self, count: int, timeout: float = 1.0) -> bytes:
        # pyserial's own timeout is per-call, but a short read can return early, so this
        # loops until the full count arrives or the deadline passes. Returning a short
        # buffer silently is how a transport turns a timing problem into a data problem.
        self._ser.timeout = timeout
        deadline = time.monotonic() + timeout
        buf = bytearray()
        while len(buf) < count and time.monotonic() < deadline:
            chunk = self._ser.read(count - len(buf))
            if chunk:
                buf += chunk
        return bytes(buf)


class PtyLoopbackTransport(SerialTransport):
    """A SerialTransport against a pseudo-terminal whose far end echoes.

    This is what lets the serial path be tested with no board attached. The kernel gives
    a master/slave PTY pair; pyserial opens the slave exactly as it would open
    /dev/ttyUSB0, and a thread on the master end writes back whatever it reads. From the
    framework's point of view that is indistinguishable from the RTL's tx-tied-to-rx
    loopback, so the same vectors exercise the same code path.

    What it does NOT prove: baud rate, bit timing, framing, or signal integrity. A PTY
    has no wire. Those only get verified against real hardware, and that gap is stated
    here rather than left for someone to assume otherwise.
    """

    def __init__(self, baudrate=115200, timeout=1.0):
        super().__init__(port=None, baudrate=baudrate, timeout=timeout)
        self._master_fd = None
        self._keeper_fd = None
        self._echo_thread = None
        self._stop = threading.Event()

    def open(self):
        self._master_fd, self._keeper_fd = os.openpty()
        self.port = os.ttyname(self._keeper_fd)

        # The slave fd is held open for the lifetime of the transport rather than closed
        # once its name has been read. Closing the last slave fd hangs up the pty: the
        # master immediately reads EOF, the echo thread exits, and every subsequent read
        # times out with nothing on the line -- which looks exactly like a dead device.
        #
        # Both ends are forced into raw mode. A pty comes up with a terminal line
        # discipline attached: canonical mode holds bytes until a newline, ECHO reflects
        # them, and ONLCR rewrites \n as \r\n. All three corrupt a binary byte stream,
        # and 0x0A is an ordinary test vector here, not a line terminator.
        tty.setraw(self._master_fd)
        tty.setraw(self._keeper_fd)

        self._stop.clear()
        self._echo_thread = threading.Thread(target=self._echo, daemon=True)
        self._echo_thread.start()

        return super().open()

    def _echo(self):
        while not self._stop.is_set():
            try:
                data = os.read(self._master_fd, 256)
            except OSError:
                return
            if not data:
                return
            try:
                os.write(self._master_fd, data)
            except OSError:
                return

    def close(self):
        self._stop.set()
        super().close()
        for attr in ("_master_fd", "_keeper_fd"):
            fd = getattr(self, attr)
            if fd is not None:
                try:
                    os.close(fd)
                except OSError:
                    pass
                setattr(self, attr, None)


class SimulationTransport(Transport):
    """File-image handoff to an RTL simulation.

    Not a byte pipe in the same sense as a serial port -- the simulator is handed a whole
    vector image up front and produces a whole results file at the end, rather than being
    fed a byte at a time. write() therefore stages bytes, and the first read() after a
    write runs the simulation and returns what came back.
    """

    def __init__(self, sim, hexfile, vectors_path, results_path, vvp=None):
        self.sim = sim
        self.hexfile = hexfile
        self.vectors_path = vectors_path
        self.results_path = results_path
        self.vvp = vvp
        self._pending = bytearray()
        self._received = bytearray()
        self.cycles = None

    def open(self):
        return self

    def close(self):
        pass

    def write(self, data: bytes) -> int:
        self._pending += data
        return len(data)

    def read(self, count: int, timeout: float = 1.0) -> bytes:
        if self._pending:
            self._run()
        out = bytes(self._received[:count])
        del self._received[:count]
        return out

    def _run(self):
        vectors = list(self._pending)
        self._pending.clear()

        with open(self.vectors_path, "w") as f:
            f.write(f"{len(vectors):08x}\n")
            for v in vectors:
                f.write(f"{v:08x}\n")

        cmd = ([self.vvp, self.sim] if self.vvp else [self.sim]) + [
            f"+hex={self.hexfile}",
            f"+vectors={self.vectors_path}",
            f"+out={self.results_path}",
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise RuntimeError(f"simulator exited {proc.returncode}: {proc.stderr[:500]}")

        if not pathlib.Path(self.results_path).exists():
            raise RuntimeError("simulator produced no results file")

        for line in open(self.results_path):
            parts = line.split()
            if not parts:
                continue
            if parts[0] == "cycles":
                self.cycles = int(parts[1])
            elif parts[0] == "rx":
                self._received.append(int(parts[1], 0) & 0xFF)


def make_transport(kind, **kw):
    if kind == "serial":
        return SerialTransport(kw["port"], kw.get("baudrate", 115200))
    if kind == "pty":
        return PtyLoopbackTransport(kw.get("baudrate", 115200))
    if kind == "sim":
        return SimulationTransport(kw["sim"], kw["hexfile"], kw["vectors"],
                                   kw["results"], kw.get("vvp"))
    raise ValueError(f"unknown transport {kind!r}")


# The same directed set the device-side harness uses: values chosen to break specific
# plausible implementations rather than for coverage's sake.
DIRECTED = [0x00, 0xFF, 0xAA, 0x55, 0x01, 0x80, 0x0F, 0xF0, 0x7F, 0xFE]


def selftest(baudrate):
    """Round-trip the directed vectors through a real pyserial stack over a PTY pair."""
    import random

    vectors = DIRECTED + [random.Random(1).randrange(256) for _ in range(200)]

    with PtyLoopbackTransport(baudrate=baudrate) as t:
        print(f"[selftest] pyserial {serial.__version__} on {t.port} "
              f"@ {baudrate} 8N1")
        mismatches = []
        for v in vectors:
            t.write(bytes([v]))
            got = t.read(1, timeout=2.0)
            if len(got) != 1:
                mismatches.append((v, None))
            elif got[0] != v:
                mismatches.append((v, got[0]))

    print(f"[selftest] {len(vectors)} bytes round-tripped, "
          f"{len(mismatches)} mismatches")
    if mismatches:
        for sent, got in mismatches[:10]:
            print(f"[selftest]   sent 0x{sent:02x} got {got}")
        return 1
    print("[selftest] PASS")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--selftest", action="store_true",
                    help="round-trip vectors through a PTY loopback, no hardware needed")
    ap.add_argument("--baud", type=int, default=115200)
    args = ap.parse_args()

    if args.selftest:
        return selftest(args.baud)

    ap.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
