"""CryptoKorr Python SDK.

Public surface:

  * ``CryptoKorr`` — the sync client (``from_env`` constructor).
  * ``client.operator`` — operator-only writes (approve / reject /
    pause / resume).
  * ``cryptokorr.errors`` — typed exception hierarchy keyed off the
    wire ``error.code`` (see ``docs/api/error-codes.md``).
  * ``cryptokorr.models`` — ``TypedDict`` result types.

See ``docs/api/sdk-surface.md`` for the full method contract.
Quickstart: ``sdks/python/README.md``.
"""

from __future__ import annotations

from . import errors, models
from ._client import CryptoKorr, OperatorClient
from ._version import __version__
from .errors import (
    APIError,
    AuthenticationError,
    AuthorizationError,
    ChainPausedError,
    ConflictError,
    IdempotencyConflictError,
    MorphoSafetyError,
    NotFoundError,
    RateLimitError,
    ServiceUnavailableError,
    SwapSafetyError,
    UpstreamError,
    ValidationError,
    WorkspacePausedError,
    WrongStateError,
)

__all__ = [
    "__version__",
    # Client.
    "CryptoKorr",
    "OperatorClient",
    # Errors.
    "APIError",
    "AuthenticationError",
    "AuthorizationError",
    "ConflictError",
    "IdempotencyConflictError",
    "WrongStateError",
    "NotFoundError",
    "ValidationError",
    "SwapSafetyError",
    "MorphoSafetyError",
    "RateLimitError",
    "ServiceUnavailableError",
    "WorkspacePausedError",
    "ChainPausedError",
    "UpstreamError",
    # Modules.
    "errors",
    "models",
]
