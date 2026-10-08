"""Savoia as a wptrunner product: how to start it, and where its WebDriver is.

Savoia is its own driver. It listens for WebDriver on loopback while Allow Remote Automation is on
(docs/devtools.md), on the port SAVOIA_WEBDRIVER_PORT names, so the "WebDriver binary" wptrunner
starts is the Debug Savoia itself, in a throwaway home that has the switch on and trusts wpt's CA.
scripts/wpt.py puts this file where `./wpt run savoia` finds it.
"""

import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
import time
from glob import glob

from wptrunner.browsers.base import WebDriverBrowser, require_arg
from wptrunner.browsers.base import get_timeout_multiplier   # noqa: F401
from wptrunner.executors import executor_kwargs as base_executor_kwargs
from wptrunner.executors.executorwebdriver import (WebDriverCrashtestExecutor,
                                                   WebDriverProtocol,
                                                   WebDriverTestDriverProtocolPart,
                                                   WebDriverTestharnessExecutor,
                                                   WebDriverTestharnessProtocolPart)
from wptrunner.products import Product

__wptrunner__ = {"product": "savoia",
                 "check_args": "check_args",
                 "browser": "SavoiaBrowser",
                 "executor": {"testharness": "SavoiaTestharnessExecutor",
                              "crashtest": "SavoiaCrashtestExecutor"},
                 "browser_kwargs": "browser_kwargs",
                 "executor_kwargs": "executor_kwargs",
                 "env_extras": "env_extras",
                 "env_options": "env_options",
                 "run_info_extras": "run_info_extras",
                 "timeout_multiplier": "get_timeout_multiplier"}


def product():
    import sys
    return Product._from_dunder_wptrunner(sys.modules[__name__])


def check_args(**kwargs):
    require_arg(kwargs, "binary")


def browser_kwargs(logger, test_type, run_info_data, config, **kwargs):
    return {"binary": kwargs["binary"],
            "webdriver_binary": kwargs["binary"],
            "ca_certificate": config.ssl_config["ca_cert_path"]}


def executor_kwargs(logger, test_type, test_environment, run_info_data, **kwargs):
    rv = base_executor_kwargs(test_type, test_environment, run_info_data, **kwargs)
    rv["close_after_done"] = True
    # What wptrunner asks of Safari, less acceptInsecureCerts: the home trusts wpt's CA instead.
    rv["capabilities"] = {"webkit:alwaysAllowAutoplay": True}
    if test_type == "testharness":
        rv["capabilities"]["pageLoadStrategy"] = "eager"
    return rv


def env_extras(**kwargs):
    return []


def env_options():
    return {}


def run_info_extras(logger, **kwargs):
    info = os.path.join(os.path.dirname(os.path.dirname(kwargs["binary"])), "Info.plist")
    try:
        import plistlib
        with open(info, "rb") as file:
            return {"browser_marketing_version": plistlib.load(file).get("CFBundleShortVersionString")}
    except OSError:
        return {}


class SavoiaBrowser(WebDriverBrowser):
    """A Debug Savoia in a home of its own. Nothing of the person's is read or written: the Release
    Savoia and the dev build's own state are other directories."""

    def __init__(self, logger, ca_certificate=None, **kwargs):
        super().__init__(logger, supports_pac=False, **kwargs)
        self.ca_certificate = ca_certificate
        self.home = tempfile.mkdtemp(prefix="savoia-wpt-", dir="/tmp")
        self.env.update(CFFIXED_USER_HOME=self.home, SAVOIA_TESTDRIVER="1",
                        SAVOIA_MCP_SOCKET=os.path.join(self.home, "mcp.sock"))
        # A sleeping display hides every page, and a hidden page is refused fullscreen and focus.
        self.awake = subprocess.Popen(["caffeinate", "-d", "-u", "-w", str(os.getpid())])
        self.prepared = False

    def database(self):
        found = glob(os.path.join(self.home, "Library/Application Support/*/savoia.sqlite"))
        return found[0] if found else None

    def has_settings(self):
        try:
            with sqlite3.connect(self.database()) as db:
                return bool(db.execute("select 1 from sqlite_master where name = 'settings'").fetchone())
        except (sqlite3.Error, TypeError):
            return False

    def prepare(self):
        """The settings table exists only after a first launch, and both settings are read at launch."""
        first = subprocess.Popen([self.binary], env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.time() + 60
        while not self.has_settings():
            if first.poll() is not None or time.time() > deadline:
                raise OSError("Savoia did not start; run this from a shell that is not sandboxed")
            time.sleep(0.5)
        time.sleep(1)
        first.terminate()
        try:
            first.wait(10)
        except subprocess.TimeoutExpired:
            first.kill()
        support = os.path.dirname(self.database())
        settings = {"devtools.automation": "1"}
        if self.ca_certificate:
            os.makedirs(os.path.join(support, "Certificates"), exist_ok=True)
            shutil.copy(self.ca_certificate, os.path.join(support, "Certificates", "wpt.pem"))
            settings["trust.certificates"] = json.dumps(["file:wpt.pem"])
        with sqlite3.connect(self.database()) as db:
            db.executemany("insert or replace into settings (key, value) values (?, ?)", settings.items())
        self.prepared = True

    def make_command(self):
        return [self.binary]

    def start(self, group_metadata, **kwargs):
        if not self.prepared:
            self.prepare()
        self.env["SAVOIA_WEBDRIVER_PORT"] = str(self.port)
        super().start(group_metadata, **kwargs)

    def cleanup(self):
        super().cleanup()
        self.awake.terminate()
        # Savoia's own account of the run outlives the home it was written in.
        for log in glob(os.path.join(self.home, "Library/Logs/*/savoia.log")):
            shutil.copy(log, os.path.join(os.getcwd(), "savoia-app.log"))
        shutil.rmtree(self.home, ignore_errors=True)


class SavoiaTestharnessProtocolPart(WebDriverTestharnessProtocolPart):
    def reset_browser_state(self):
        """The answers about location and notifications, the stand-in position, the notifications shown."""
        self.webdriver.send_session_command("POST", "savoia/reset", {})


class SavoiaTestDriverProtocolPart(WebDriverTestDriverProtocolPart):
    """Two testdriver actions that wptrunner sends over WebDriver BiDi, which WebKit's automation does
    not carry for them. Savoia answers both over HTTP, so they are served here and never reach
    wptrunner's handler, which would call them not implemented."""

    def get_next_message(self, url, script_resume, test_window):
        while True:
            message = super().get_next_message(url, script_resume, test_window)
            if not (isinstance(message, list) and len(message) == 3 and message[1] == "action"):
                return message
            payload = message[2]
            action, params = payload.get("action"), payload.get("params") or {}
            if action == "bidi.permissions.set_permission":
                command, body = "savoia/permissions", {"descriptor": params["descriptor"], "state": params["state"],
                                                       "origin": params["origin"]}
            elif action == "bidi.emulation.set_geolocation_override":
                command, body = "savoia/geolocation", {key: params[key] for key in ("coordinates", "error")
                                                       if params.get(key) is not None}
            else:
                return message
            try:
                self.webdriver.send_session_command("POST", command, body)
                self.send_message(payload["id"], "complete", "success", json.dumps({"result": None}))
            except Exception as error:
                self.send_message(payload["id"], "complete", "error", f"Action {action} failed: {error}")


class SavoiaProtocol(WebDriverProtocol):
    implements = [{WebDriverTestharnessProtocolPart: SavoiaTestharnessProtocolPart,
                   WebDriverTestDriverProtocolPart: SavoiaTestDriverProtocolPart}.get(part, part)
                  for part in WebDriverProtocol.implements]


class SavoiaTestharnessExecutor(WebDriverTestharnessExecutor):
    protocol_cls = SavoiaProtocol


class SavoiaCrashtestExecutor(WebDriverCrashtestExecutor):
    protocol_cls = SavoiaProtocol
