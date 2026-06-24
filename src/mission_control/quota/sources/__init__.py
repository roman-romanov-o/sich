"""Quota source adapters.

Each source returns a :class:`SourceReading` (value + ``inferred`` +
``available``). All sources are dependency-injectable and do no real I/O — they
never call ``claude``/``claude -p``, the network, or a provider API.
"""

from mission_control.quota.sources.base import QuotaSource
from mission_control.quota.sources.stub import (
    AbsentSource,
    AgentSdkCreditSource,
    InteractiveWindowSource,
    StubSource,
)

__all__ = [
    "AbsentSource",
    "AgentSdkCreditSource",
    "InteractiveWindowSource",
    "QuotaSource",
    "StubSource",
]
