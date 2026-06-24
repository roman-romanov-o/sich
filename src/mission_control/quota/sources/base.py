"""The quota source adapter Protocol."""

from typing import Protocol, runtime_checkable

from mission_control.quota.models import SourceReading


@runtime_checkable
class QuotaSource(Protocol):
    """A pool's usage signal, normalized to a :class:`SourceReading`.

    Implementations carry their own ``provider``/``pool`` labels so the
    aggregator can place each reading on its own independent gauge.
    """

    provider: str
    pool: str

    def read(self) -> SourceReading:
        """Return the current reading. Must not perform real I/O here."""
        ...
