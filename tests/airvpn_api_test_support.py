import base64
from dataclasses import FrozenInstanceError, replace
import importlib.machinery
import importlib.util
import http.client
import inspect
import io
import ipaddress
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "libexec" / "airvpn-api"
MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_SERVERS = 1000
MAX_NUMERIC_TEXT_CHARS = 64
MAX_DISPLAY_FIELD_CHARS = 256


def _load_helper():
    loader = importlib.machinery.SourceFileLoader("airvpn_api", str(HELPER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


airvpn_api = _load_helper()


def _server(
    name,
    ip,
    *,
    country="GB",
    location="London",
    bw_max=10000,
    load=10,
    users=20,
    health="ok",
    **extra,
):
    server = {
        "public_name": name,
        "country_code": country,
        "location": location,
        "bw_max": bw_max,
        "currentload": load,
        "users": users,
        "health": health,
        "ip_v4_in1": ip,
    }
    server.update(extra)
    return server


def _status(*servers):
    return {"result": "ok", "servers": list(servers)}


def _dummy_wireguard_key(value):
    return base64.b64encode(bytes([value]) * 32).decode("ascii")


def _wireguard_profile(
    *,
    address="10.20.30.40/32",
    private_key=None,
    mtu="1320",
    dns=("10.128.0.1", "1.1.1.1"),
    table="off",
    public_key=None,
    preshared_key=None,
    endpoint="198.51.100.10:1637",
    allowed_ips="0.0.0.0/0",
    persistent_keepalive="15",
    interface_extra=(),
    peer_extra=(),
    trailer=(),
    line_ending="\n",
    terminal_newline=True,
):
    private_key = private_key or _dummy_wireguard_key(1)
    public_key = public_key or _dummy_wireguard_key(2)
    preshared_key = preshared_key or _dummy_wireguard_key(3)
    lines = [
        "# Redacted provider-success shape",
        "[Interface]",
        f"Address = {address}",
        f"PrivateKey = {private_key}",
        f"MTU = {mtu}",
    ]
    if dns is not None:
        lines.append(f"DNS = {', '.join(dns)}")
    if table is not None:
        lines.append(f"Table = {table}")
    lines.extend(interface_extra)
    lines.extend(
        [
            "",
            "[Peer]",
            f"PublicKey = {public_key}",
            f"PresharedKey = {preshared_key}",
            f"Endpoint = {endpoint}",
            f"AllowedIPs = {allowed_ips}",
            f"PersistentKeepalive = {persistent_keepalive}",
        ]
    )
    lines.extend(peer_extra)
    lines.extend(trailer)
    text = line_ending.join(lines)
    if terminal_newline:
        text += line_ending
    return text.encode("utf-8")


def _random_wireguard_key():
    value = bytearray(secrets.token_bytes(32))
    if not any(value):
        value[0] = 1
    return base64.b64encode(value).decode("ascii")


def _generator_profile(**overrides):
    values = {
        "private_key": _random_wireguard_key(),
        "public_key": _random_wireguard_key(),
        "preshared_key": _random_wireguard_key(),
    }
    values.update(overrides)
    return _wireguard_profile(**values)


class _TrackedBytesIO(io.BytesIO):
    def __init__(self, value=b""):
        super().__init__(value)
        self.read_calls = []
        self.write_calls = []
        self.snapshot = value

    def read(self, size=-1):
        self.read_calls.append(size)
        return super().read(size)

    def write(self, value):
        self.write_calls.append(bytes(value))
        return super().write(value)

    def close(self):
        if not self.closed:
            self.snapshot = self.getvalue()
        super().close()


class _Response(_TrackedBytesIO):
    def __init__(self, payload, *, content_type="text/plain", content_encoding=None):
        super().__init__(payload)
        self.status = 200
        self.headers = {}
        if content_type is not None:
            self.headers["Content-Type"] = content_type
        if content_encoding is not None:
            self.headers["Content-Encoding"] = content_encoding

    def getcode(self):
        return self.status

    def __enter__(self):
        return self

    def __exit__(self, _error_type, _error, _traceback):
        self.close()
        return False


class _IncompleteReadResponse(_Response):
    def __init__(self, marker):
        super().__init__(b"")
        self.marker = marker

    def read(self, size=-1):
        self.read_calls.append(size)
        raise http.client.IncompleteRead(self.marker, len(self.marker) + 10)


class _CloseFailureResponse(_Response):
    def __init__(self, marker):
        super().__init__(_generator_profile())
        self.marker = marker

    def close(self):
        super().close()
        raise http.client.BadStatusLine(self.marker.decode("ascii"))


class _NonSeekableOutput(_TrackedBytesIO):
    def seekable(self):
        return False

    def seek(self, *_args, **_kwargs):
        raise OSError("not seekable")

    def truncate(self, *_args, **_kwargs):
        raise OSError("not truncatable")


class _ShortWriteOutput(_TrackedBytesIO):
    def write(self, value):
        if self.write_calls:
            self.write_calls.append(bytes(value))
            return 0
        partial = bytes(value[: max(1, len(value) // 2)])
        return super().write(partial)


class _FlushFailureOutput(_TrackedBytesIO):
    def flush(self):
        if self.write_calls:
            raise OSError("flush failed")
        return super().flush()



__all__ = [name for name in globals() if not name.startswith("__")]
