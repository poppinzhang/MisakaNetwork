"""Minimal host environment for isolated runtime tests, never production code."""
import os


def isolated_environment(values=None):
    # Windows cryptographic providers need the OS installation location. Keep
    # only these system variables; proxy, CA and upstream settings stay absent.
    environment = {
        name: value for name, value in os.environ.items()
        if os.name == "nt" and name.upper() in {"SYSTEMROOT", "WINDIR"}
    }
    environment.update(values or {})
    return environment
