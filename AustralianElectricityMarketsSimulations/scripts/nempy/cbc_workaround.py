"""CBC segfault workaround for mip 1.16rc0: import this module before nempy.

With direct cffi calls CBC segfaults after Cbc_solve in some environments; routing every call
through a Python wrapper avoids it. Garbage collection is disabled for the same reason.
"""
import gc

gc.disable()

import mip.cbc as _cbc  # noqa: E402


class _Proxy:
    def __init__(self, lib):
        self._lib = lib

    def __getattr__(self, name):
        attr = getattr(self._lib, name)
        if callable(attr):
            def call(*args):
                return attr(*args)
            return call
        return attr


_cbc.cbclib = _Proxy(_cbc.cbclib)
