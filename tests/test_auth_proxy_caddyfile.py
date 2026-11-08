# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""The auth-proxy sidecar config: constant text, and what it does to requests.

Static half: every config file run.sh stages for the sidecar is a quoted
heredoc, so its `{$VAR}` / `{env.VAR}` references reach Caddy unexpanded and no
credential is ever baked into a staged file. Each heredoc is run through bash
with those variables set and must come out byte for byte.

Behavioural half: run.sh's own staging functions write the glab site config
into a temp dir, a real Caddy serves it, and mock upstreams record what
arrives. Skipped unless a `caddy` binary is on PATH (or named by CADDY_BIN) —
use the version pinned in run.sh's PROXY_IMAGE; CI copies it out of that image
and sets VIBE_DOCKER_TEST_REQUIRE_CADDY=1 so a missing binary fails. gh's sites listen on :443 and
are covered by tests/integration/gh-proxy-integration.sh instead; Docker-level wiring
(--add-host, env in the agent container) is covered there and in
tests/bats/run.bats.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import http.client
import http.server
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
from pathlib import Path

RUN_SH = Path(__file__).resolve().parent.parent / "run.sh"
HEREDOC = re.compile(
    r"^[ \t]*cat <<(\S+) >\"\$1/([^\"]+)\"[^\n]*\n(.*?\n)(\w+)\n",
    re.S | re.M,
)
SECRETS = {
    "GH_PROXY_BASIC": "Basic LEAK", "GH_PROXY_BEARER": "Bearer LEAK",
    "GLAB_PROXY_BEARER": "Bearer LEAK", "GLAB_PROXY_BASIC": "Basic LEAK",
    "GH_HOST_TOKEN": "LEAK", "GLAB_HOST_TOKEN": "LEAK",
    "GLAB_PROXY_SITE": "LEAK", "GLAB_PROXY_UPSTREAM": "LEAK",
}


class ConstantConfigTest(unittest.TestCase):
    def test_every_staged_file_is_written_verbatim(self):
        src = RUN_SH.read_text()
        found = {}
        for m in HEREDOC.finditer(src):
            delim, target, body, end = m.groups()
            self.assertEqual(delim, f"'{end}'", f"{target}: heredoc delimiter must stay single-quoted")
            script = m.group(0).lstrip().replace(f' >"$1/{target}"', "", 1)
            env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), **SECRETS}
            out = subprocess.run(
                ["bash", "-c", script], env=env, capture_output=True, text=True, check=True
            ).stdout
            self.assertEqual(out, body, target)
            self.assertNotIn("LEAK", out, target)
            found[target] = body
        self.assertEqual(set(found), {"Caddyfile", "sites/gh.caddy", "sites/glab.caddy"})
        self.assertIn("{env.GH_PROXY_BEARER}", found["sites/gh.caddy"])
        self.assertIn("{env.GLAB_PROXY_BEARER}", found["sites/glab.caddy"])
        self.assertIn("import /etc/caddy/sites/*.caddy", found["Caddyfile"])

    def test_the_sidecar_serves_only_the_forges(self):
        # The sidecar proxies GitHub and GitLab only; no model-endpoint site.
        src = RUN_SH.read_text()
        self.assertNotIn("stage_api_proxy_site", src)
        self.assertNotIn("api.caddy", src)
        self.assertNotIn(":8080", src)


def _free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class _Recorder(http.server.BaseHTTPRequestHandler):
    """Echoes method, path and headers as JSON."""

    protocol_version = "HTTP/1.1"

    def _handle(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        body = json.dumps({"method": self.command, "path": self.path,
                           "headers": {k.lower(): v for k, v in self.headers.items()}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = _handle

    def log_message(self, *_):
        pass


CADDY = os.environ.get("CADDY_BIN") or shutil.which("caddy")
# CI sets this so a missing tool fails the run instead of skipping it quietly.
REQUIRE_CADDY = os.environ.get("VIBE_DOCKER_TEST_REQUIRE_CADDY") == "1"


def _missing(reason):
    if REQUIRE_CADDY:
        raise RuntimeError(f"{reason}, and VIBE_DOCKER_TEST_REQUIRE_CADDY=1 forbids skipping")
    raise unittest.SkipTest(reason)


class SidecarBehaviourTest(unittest.TestCase):
    """The glab site, staged by run.sh itself, served by a real Caddy."""

    @classmethod
    def setUpClass(cls):
        if not CADDY:
            _missing("no caddy binary (set CADDY_BIN or put caddy on PATH)")
        cls.tmp = tempfile.TemporaryDirectory()
        cls.servers = []
        cls.glab_up = cls._serve()

    @classmethod
    def tearDownClass(cls):
        for s in cls.servers:
            s.shutdown()
            s.server_close()
        cls.tmp.cleanup()

    @classmethod
    def _serve(cls):
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Recorder)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        cls.servers.append(srv)
        return f"http://127.0.0.1:{srv.server_address[1]}"

    def _start(self, *, glab_policy=""):
        """Stage via run.sh, rehome /etc/caddy, start Caddy."""
        work = Path(tempfile.mkdtemp(dir=self.tmp.name))
        caddy_dir = work / "caddy"
        self.glab_port, http_port = _free_port(), _free_port()
        env = {k: v for k, v in os.environ.items() if not k.startswith("VIBE_DOCKER_")}
        if glab_policy:
            (work / "user-policy.caddy").write_text(glab_policy)
            env["VIBE_DOCKER_GLAB_POLICY"] = str(work / "user-policy.caddy")
        script = 'set -euo pipefail; source "$1"; d="$2"; stage_proxy_root "$d"; stage_glab_proxy_site "$d"'
        subprocess.run(["bash", "-c", script, "_", str(RUN_SH), str(caddy_dir)],
                       env=env, capture_output=True, text=True, check=True)
        for f in caddy_dir.rglob("*"):
            if f.is_file() and f.suffix in (".caddy", ""):
                txt = f.read_text().replace("/etc/caddy/", f"{caddy_dir}/")
                # The HTTP->HTTPS redirect listener defaults to :80, which an
                # unprivileged user can't bind.
                txt = txt.replace("\tskip_install_trust\n", f"\tskip_install_trust\n\thttp_port {http_port}\n")
                f.write_text(txt)
        self.caddy_env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": str(work), "XDG_DATA_HOME": str(work / "data"), "XDG_CONFIG_HOME": str(work / "cfg"),
            "GLAB_PROXY_SITE": f"gl.example.test:{self.glab_port}",
            "GLAB_PROXY_UPSTREAM": self.glab_up,
            "GLAB_PROXY_BEARER": "Bearer glpat-real",
            "GLAB_PROXY_BASIC": "Basic b2F1dGgyOmdscGF0LXJlYWw=",
        }
        self.log = work / "caddy.log"
        logf = open(self.log, "w")
        self.addCleanup(logf.close)
        proc = subprocess.Popen([CADDY, "run", "--config", str(caddy_dir / "Caddyfile"), "--adapter", "caddyfile"],
                                env=self.caddy_env, stdout=logf, stderr=subprocess.STDOUT)
        self.addCleanup(proc.wait)
        self.addCleanup(proc.terminate)
        deadline = time.time() + 15
        root = work / "data" / "caddy" / "pki" / "authorities" / "local" / "root.crt"
        while time.time() < deadline:
            if "serving initial configuration" in self.log.read_text() and root.exists():
                break
            self.assertIsNone(proc.poll(), self.log.read_text())
            time.sleep(0.1)
        else:
            self.fail("caddy did not become ready:\n" + self.log.read_text())
        self.glab_ctx = ssl.create_default_context(cafile=str(root))
        # The root exists before the site's leaf is issued; a handshake in
        # between gets TLSV1_ALERT_INTERNAL_ERROR. Ready means one succeeds.
        while True:
            try:
                with socket.create_connection(("127.0.0.1", self.glab_port), timeout=2) as sock:
                    self.glab_ctx.wrap_socket(sock, server_hostname="gl.example.test").close()
                break
            except (OSError, ssl.SSLError) as e:
                self.assertIsNone(proc.poll(), self.log.read_text())
                if time.time() >= deadline:
                    self.fail(f"caddy never completed a TLS handshake ({e}):\n" + self.log.read_text())
                time.sleep(0.1)
        return caddy_dir

    # -- helpers --

    def audit_log(self, want, timeout=5):
        """Poll the log until an access entry satisfies want; returns (log text, entries)."""
        deadline = time.time() + timeout
        while True:
            log = self.log.read_text()
            # Complete lines only: Caddy may be mid-write on the last one.
            entries = [json.loads(line) for line in log.split("\n")[:-1] if '"handled request"' in line]
            if any(want(e) for e in entries):
                return log, entries
            if time.time() >= deadline:
                self.fail("no matching access log entry:\n" + log)
            time.sleep(0.05)

    def glab(self, method, path, headers=None):
        """Request through the glab site; returns (status, upstream echo or body)."""
        # SNI and Host must name the GitLab host; the socket goes to loopback.
        conn = http.client.HTTPSConnection("gl.example.test", self.glab_port, context=self.glab_ctx)
        conn.sock = self.glab_ctx.wrap_socket(socket.create_connection(("127.0.0.1", self.glab_port)),
                                              server_hostname="gl.example.test")
        conn.request(method, path, headers=headers or {})
        r = conn.getresponse()
        body = r.read().decode()
        conn.close()
        try:
            return r.status, json.loads(body)
        except ValueError:
            return r.status, body

    # -- glab --

    def test_glab_injects_per_path_class_and_strips_client_credentials(self):
        self._start()
        st, echo = self.glab("GET", "/api/v4/user", {"PRIVATE-TOKEN": "vibe-docker-proxy"})
        self.assertEqual(st, 200)
        self.assertEqual(echo["headers"].get("authorization"), "Bearer glpat-real")
        self.assertNotIn("private-token", echo["headers"])
        for path in ("/g/p.git/info/refs?service=git-upload-pack", "/g/p.git/git-receive-pack"):
            with self.subTest(path=path):
                _, echo = self.glab("POST", path, {"Authorization": "Basic Y2xpZW50"})
                self.assertEqual(echo["headers"].get("authorization"), "Basic b2F1dGgyOmdscGF0LXJlYWw=")
        # LFS gets nothing: GitLab's batch response would echo the credential back.
        for path in ("/g/p.git/info/lfs/objects/batch", "/g/p.git/info/lfs/locks",
                     "/g/p.git/gitlab-lfs/objects/" + "0" * 64):
            with self.subTest(path=path):
                st, echo = self.glab("POST", path, {"Authorization": "Basic Y2xpZW50"})
                self.assertEqual(st, 200)
                self.assertNotIn("authorization", echo["headers"])
        _, echo = self.glab("GET", "/g/p/-/tree/main",
                            {"Authorization": "Bearer x", "PRIVATE-TOKEN": "x", "JOB-TOKEN": "x"})
        for h in ("authorization", "private-token", "job-token"):
            self.assertNotIn(h, echo["headers"])

    def test_glab_default_policy_blocks_project_and_group_deletion(self):
        self._start()
        for path in ("/api/v4/projects/123", "/api/v4/projects/123/", "/api/v4/projects/g%2Fsub%2Fp",
                     "/api/v4/projects/g%2fp?x=1", "//api/v4/groups/42", "/api/v4//projects/1",
                     "/api//v4/projects/1", "/api/v4/projects/1.json"):
            for method in ("DELETE", "POST"):  # POST: Rack::MethodOverride (_method=delete)
                with self.subTest(method=method, path=path):
                    st, body = self.glab(method, path)
                    self.assertEqual(st, 403)
                    self.assertIn("vibe-docker glab-proxy policy", body)
        st, _ = self.glab("POST", "/api/v4/projects/123", {"X-HTTP-Method-Override": "DELETE"})
        self.assertEqual(st, 403)
        for path in ("/api/v4/projects/123/repository/branches/x", "/api/v4/projects/123/issues/1"):
            with self.subTest(path=path):
                self.assertEqual(self.glab("DELETE", path)[0], 200)
        # The imports are the only POSTs GitLab routes on a bare project or group path.
        for path in ("/api/v4/projects/user/5", "/api/v4/projects/import", "/api/v4/projects/remote-import",
                     "/api/v4/projects/remote-import-s3", "/api/v4/groups/import", "/api//v4/projects/import.json"):
            with self.subTest(path=path):
                self.assertEqual(self.glab("POST", path)[0], 200)

    def test_glab_default_policy_covers_an_absolute_form_target(self):
        # {http.request.uri} is origin-form even for an absolute-form request
        # line, so the anchored matches still apply.
        self._start()
        for method, target in (("DELETE", "https://gl.example.test/api/v4/projects/1"),
                               ("POST", "https://gl.example.test/api/v4/user/personal_access_tokens")):
            with self.subTest(method=method, target=target):
                st, body = self.glab(method, target)
                self.assertEqual(st, 403)
                self.assertIn("vibe-docker glab-proxy policy", body)

    def test_glab_default_policy_refuses_escaped_unreserved_characters(self):
        # GitLab's router decodes these, so they could hide a blocked call.
        self._start()
        for method, path in (("DELETE", "/api/v4/%70rojects/123"), ("DELETE", "/%61pi/v4/groups/1"),
                             ("DELETE", "/api/v4/projects/%31%32%33"), ("DELETE", "/api/v4/gro%75ps/1"),
                             ("POST", "/api/v4/user/personal%5Faccess%5ftokens"),
                             ("POST", "/api/v4/personal_access_tokens/self/rotate%2Ejson"),
                             ("POST", "/g/p.git/git-%72eceive-pack"),
                             ("PUT", "/api/v4/personal_access_tokens/self/%72otate")):
            with self.subTest(method=method, path=path):
                st, body = self.glab(method, path)
                self.assertEqual(st, 403)
                self.assertIn("vibe-docker glab-proxy policy", body)
        # Reads are not checked (GitLab's docs encode dots in file paths), nor
        # are reserved characters or the query string.
        for path in ("/api/v4/projects/g%2Fp/repository/files/a%20b.txt/raw",
                     "/api/v4/projects/1/repository/files/app%2Fmodels%2Fkey%2Erb?ref=main",
                     "/api/v4/projects/g%2fp/issues?search=%61"):
            with self.subTest(path=path):
                self.assertEqual(self.glab("GET", path)[0], 200)

    def test_glab_default_policy_blocks_project_and_group_settings_changes(self):
        self._start()
        for path in ("/api/v4/projects/123", "/api/v4/projects/g%2Fp?visibility=public",
                     "/api/v4/groups/42/", "//api/v4/projects/1.json"):
            with self.subTest(path=path):
                st, body = self.glab("PUT", path)
                self.assertEqual(st, 403)
                self.assertIn("vibe-docker glab-proxy policy", body)
        self.assertEqual(self.glab("GET", "/api/v4/projects/123")[0], 200)

    def test_glab_default_policy_blocks_token_minting(self):
        self._start()
        blocked = (
            ("POST", "/api/v4/personal_access_tokens/self/rotate"),
            ("POST", "/api/v4/personal_access_tokens/17/rotate"),
            ("POST", "/api/v4/user/personal_access_tokens"),
            ("POST", "/api/v4/users/5/personal_access_tokens"),
            ("POST", "/api/v4/users/5/impersonation_tokens"),
            ("POST", "/api/v4/projects/123/access_tokens"),
            ("POST", "/api/v4/projects/g%2Fsub%2Fp/access_tokens"),
            ("POST", "/api/v4/projects/123/access_tokens/9/rotate"),
            ("POST", "/api/v4/groups/42/access_tokens/9/rotate"),
            ("POST", "/api/v4/projects/g%2fp/deploy_tokens?x=1"),
            ("POST", "/api/v4/groups/42/deploy_tokens"),
            ("POST", "/api/v4/deploy_tokens"),
            ("POST", "/api/v4/groups/42/service_accounts/7/personal_access_tokens"),
            ("POST", "//api/v4//personal_access_tokens/self/rotate"),
            ("POST", "/api/v4/projects/123//access_tokens/"),
            ("PUT", "/api/v4/personal_access_tokens/self/rotate"),
            ("POST", "/api//v4/user/personal_access_tokens"),
            ("POST", "/api/v4/user/personal_access_tokens.json"),
            ("POST", "/api/v4/personal_access_tokens/self/rotate.json"),
            ("POST", "/api/v4/projects/123/access_tokens.json?x=1"),
            ("POST", "/api/v4/deploy_tokens.json/"),
            ("POST", "/api/v4/user/keys"),
            ("POST", "/api/v4/user/gpg_keys"),
            ("POST", "/api/v4/user/emails"),
            ("POST", "/api/v4/users/5/emails"),
            ("POST", "/api/v4/users/5/keys"),
            ("POST", "/api/v4/users/5/gpg_keys"),
            ("POST", "/api/v4/projects/123/deploy_keys"),
            ("POST", "/api/v4/projects/g%2Fp/deploy_keys/9/enable"),
            ("POST", "/api/v4/user/runners"),
            ("POST", "/api/v4/runners"),
            ("POST", "/api/v4/runners/7/reset_authentication_token"),
            ("POST", "/api/v4/runners/reset_registration_token"),
            ("POST", "/api/v4/projects/123/runners/reset_registration_token"),
            ("POST", "/api/v4/groups/42/runners/reset_registration_token"),
            ("POST", "/api/v4/projects/123/triggers"),
            ("POST", "/api/v4/projects/123/cluster_agents/4/tokens"),
            ("POST", "/api/v4/deploy_keys"),
            ("POST", "/api/v4/projects/123/members"),
            ("POST", "/api/v4/groups/42/members"),
            ("PUT", "/api/v4/projects/g%2Fp/members/7"),
            ("POST", "/api/v4/groups/42/invitations"),
            ("PUT", "/api/v4/projects/123/invitations/a@b.example"),
            ("POST", "/api/v4/projects/123/share"),
            ("POST", "/api/v4/groups/42/share"),
            ("PUT", "/api/v4/projects/123/transfer"),
            ("POST", "/api/v4/groups/42/transfer"),
            ("POST", "/api/v4/projects/123/hooks"),
            ("PUT", "/api/v4/projects/123/hooks/9"),
            ("POST", "/api/v4/groups/42/hooks"),
            ("POST", "/api/v4/hooks"),
            ("POST", "/api/v4/projects/123/remote_mirrors"),
            ("PUT", "/api/v4/projects/g%2Fp/remote_mirrors/3"),
            ("PUT", "/api/v4/projects/123/mirror/pull"),
            ("POST", "/api/v4/projects/123/mirror/pull"),
            ("PUT", "/api/v4/groups/42/access_requests/7/approve"),
            ("POST", "/api/v4/projects/123/import_project_members/77"),
            ("PUT", "/api/v4/groups/42/members/7/approve"),
            ("PUT", "/api/v4/projects/123/members/7/approve"),
            ("POST", "/api/v4/groups/42/ldap_group_links"),
            ("POST", "/api/v4/groups/42/saml_group_links"),
            ("PUT", "/api/v4/projects/123/integrations/emails-on-push"),
            ("PUT", "/api/v4/groups/42/integrations/slack"),
            ("PUT", "/api/v4/projects/123/services/slack"),
            ("POST", "/api/v4/projects/123/pipeline_schedules"),
            ("PUT", "/api/v4/projects/123/pipeline_schedules/5"),
            ("POST", "/api/v4/projects/123/pipeline_schedules/5/take_ownership"),
            ("POST", "/api/v4/users"),
            ("PUT", "/api/v4/users/7"),
            ("POST", "/api/v4/applications"),
            ("PUT", "/api/v4/application/settings"),
        )
        for method, path in blocked:
            with self.subTest(method=method, path=path):
                st, body = self.glab(method, path)
                self.assertEqual(st, 403)
                self.assertIn("vibe-docker glab-proxy policy", body)
                self.assertIn("VIBE_DOCKER_GLAB_POLICY", body)
        allowed = (
            ("GET", "/api/v4/personal_access_tokens"),
            ("GET", "/api/v4/personal_access_tokens/self"),
            ("GET", "/api/v4/projects/123/access_tokens"),
            ("GET", "/api/v4/user/keys"),
            ("GET", "/api/v4/user/emails"),
            ("GET", "/api/v4/projects/123/triggers"),
            ("POST", "/api/v4/projects/123/runners"),
            ("GET", "/api/v4/projects/123/members"),
            ("GET", "/api/v4/deploy_keys"),
            ("GET", "/api/v4/projects/123/hooks"),
            ("POST", "/api/v4/projects/123/hooks/9/test/push_events"),
            ("PUT", "/api/v4/projects/123/issues/1"),
            ("GET", "/api/v4/projects/123/integrations"),
            ("GET", "/api/v4/groups/42/ldap_group_links"),
            ("GET", "/api/v4/projects/123/pipeline_schedules"),
            ("POST", "/api/v4/projects/123/pipeline_schedules/5/play"),
            ("GET", "/api/v4/users"),
            ("POST", "/api/v4/projects/123/pipeline"),
            ("POST", "/api/v4/projects/1/issues"),
            ("POST", "/api/v4/projects/1/merge_requests"),
        )
        for method, path in allowed:
            with self.subTest(method=method, path=path):
                self.assertEqual(self.glab(method, path)[0], 200)

    def test_glab_user_policy_extension_is_honoured(self):
        self._start(glab_policy=(
            "@no_branch_delete {\n\tmethod DELETE\n\tpath_regexp ^/api/v4/projects/[^/]+/repository/branches/.*\n}\n"
            'respond @no_branch_delete "blocked by user policy" 403\n'))
        st, body = self.glab("DELETE", "/api/v4/projects/123/repository/branches/x")
        self.assertEqual((st, body), (403, "blocked by user policy"))

    def test_glab_audit_log_has_requests_but_no_secrets(self):
        self._start()
        self.assertEqual(self.glab("GET", "/api/v4/user", {"PRIVATE-TOKEN": "vibe-docker-proxy"})[0], 200)
        log, entries = self.audit_log(lambda e: e["request"]["host"].startswith("gl.example.test")
                                      and e["request"]["uri"] == "/api/v4/user" and e["status"] == 200)
        self.assertTrue(all("headers" not in e["request"] for e in entries))
        self.assertNotIn("glpat-real", log)
        self.assertNotIn("vibe-docker-proxy", log)


if __name__ == "__main__":
    unittest.main()
