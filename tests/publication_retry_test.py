#!/usr/bin/env python3
"""Exercise publication races using disposable local Git repositories.

Requires Python 3, Git, Bash, and ssh-keygen. No network, user Git configuration,
host authorized_keys, or repository-provided executables are used. The actual
cleanup, validator, generator, and publication helper run against JSON-as-YAML
fixtures and a deliberately small, Python-only yq test double.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
REAL_GIT = shutil.which("git")

YQ_FIXTURE = r'''#!/usr/bin/env python3
import json
import re
import sys

args = sys.argv[1:]
assert args.pop(0) == 'e'
in_place = args[0] == '-i'
if in_place:
    args.pop(0)
expression, path = args
with open(path, encoding='utf-8') as source:
    data = json.load(source)

def output(value):
    if value is None:
        print('null')
    elif isinstance(value, bool):
        print(str(value).lower())
    else:
        print(value)

if expression == '.user':
    output(data['user'])
elif expression == '.keys | length':
    output(len(data['keys']))
elif expression == '.keys[].filename':
    for key in data['keys']:
        output(key['filename'])
elif expression == '.environments[]':
    for environment in data['environments']:
        output(environment)
elif match := re.fullmatch(r'del\(\.keys\[(\d+)\]\)', expression):
    del data['keys'][int(match[1])]
elif match := re.fullmatch(r'\.keys\[(\d+)\]\.environments \| length', expression):
    output(len(data['keys'][int(match[1])]['environments']))
elif match := re.fullmatch(r'\.keys\[(\d+)\]\.environments\[(\d+)\]', expression):
    output(data['keys'][int(match[1])]['environments'][int(match[2])])
elif match := re.fullmatch(
        r'\.keys\[(\d+)\]\.environments\[\] \| select\(\. == "([^"]+)" or \. == "all"\)',
        expression):
    for environment in data['keys'][int(match[1])]['environments']:
        if environment in (match[2], 'all'):
            output(environment)
elif match := re.fullmatch(r'\.keys\[(\d+)\]\.(\w+)', expression):
    output(data['keys'][int(match[1])].get(match[2]))
else:
    sys.exit('unsupported fixture yq expression: ' + expression)
if in_place:
    with open(path, 'w', encoding='utf-8') as destination:
        json.dump(data, destination)
'''

GIT_WRAPPER = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

real_git = os.environ['REAL_GIT']
args = sys.argv[1:]

def git(*arguments, cwd=None):
    return subprocess.check_output([real_git, *arguments], cwd=cwd,
                                   text=True, stderr=subprocess.STDOUT).strip()

def record(entry):
    with open(os.environ['CALL_LOG'], 'a', encoding='utf-8') as stream:
        stream.write(json.dumps(entry) + '\n')

if args[0] == 'push':
    log = Path(os.environ['CALL_LOG'])
    calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
    attempt = 1 + sum(call['command'] == 'push' for call in calls)
    record({'command': 'push', 'args': args, 'head': git('rev-parse', 'HEAD')})
    if attempt <= int(os.environ.get('RACE_WRITES', '0')):
        writer = Path(os.environ['WRITER'])
        git('fetch', '-q', 'origin', 'main', cwd=writer)
        git('reset', '--hard', 'origin/main', cwd=writer)
        path = writer / 'meta/alice.yaml'
        metadata = json.loads(path.read_text())
        for key in metadata['keys']:
            if key['filename'] == 'active_rsa.pub':
                key['revoked'] = True
        name = 'concurrent_%s_rsa.pub' % attempt
        metadata['keys'].append({
            'filename': name, 'comment': None,
            'added_at': '2026-01-01T00:00:00Z', 'expires_at': None,
            'revoked': False, 'environments': ['all'],
        })
        path.write_text(json.dumps(metadata))
        public_key = (writer / 'keys/alice/active_rsa.pub').read_text()
        if os.environ.get('RACE_KIND') == 'invalid':
            public_key = 'not an OpenSSH public key\n'
        (writer / 'keys/alice' / name).write_text(public_key)
        with (writer / 'concurrent-notes.txt').open('a') as stream:
            stream.write('concurrent source edit %s\n' % attempt)
        if os.environ.get('RACE_KIND') == 'generation-failure':
            (writer / 'envs.yaml').write_text(json.dumps({
                'environments': ['first', 'second', 'blocked'],
            }))
            blocked = writer / 'authorized_keys/blocked'
            blocked.mkdir(exist_ok=True)
            (blocked / '.keep').write_text('directory prevents output generation\n')
        git('add', '-A', cwd=writer)
        git('commit', '-qm', 'Concurrent source edit %s' % attempt, cwd=writer)
        git('push', '-q', 'origin', 'HEAD:main', cwd=writer)
        tip = git('rev-parse', 'HEAD', cwd=writer)
        record({'command': 'concurrent-commit', 'head': tip})
        if os.environ.get('KNOW_REMOTE_COMMIT') == '1':
            # Fetch objects by URL without advancing origin/main. This makes
            # Git report non-fast-forward instead of fetch first.
            git('fetch', '-q', os.environ['REMOTE'], 'main')
    if os.environ.get('DENY_PUBLISH') == '1':
        hook = Path(os.environ['REMOTE']) / 'hooks/pre-receive'
        hook.write_text('#!/bin/sh\necho "fixture permission denied" >&2\nexit 1\n')
        hook.chmod(0o755)
elif args[0] == 'fetch':
    record({'command': 'fetch', 'args': args})
    if os.environ.get('FAIL_FETCH') == '1':
        sys.stderr.write('fatal: fixture fetch transport failed\n')
        sys.exit(128)
elif args[0] in ('reset', 'rebase', 'merge', 'cherry-pick'):
    record({'command': args[0], 'args': args})
os.execv(real_git, [real_git, *args])
'''


class PublicationRetryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ssh-keys-retry-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.remote = self.root / "remote.git"
        self.seed = self.root / "seed"
        self.repo = self.root / "runner"
        self.writer = self.root / "writer"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.log = self.root / "calls.jsonl"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GIT_")}
        self.env.update(
            HOME=str(self.home), XDG_CONFIG_HOME=str(self.home),
            LC_ALL="C",
            GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
            GIT_TERMINAL_PROMPT="0", GIT_ALLOW_PROTOCOL="file",
            PATH=f'{self.bin}:{os.environ["PATH"]}',
            REAL_GIT=REAL_GIT, CALL_LOG=str(self.log), REMOTE=str(self.remote),
            WRITER=str(self.writer), IS_TRACE="false", SKIP_PUSH="true",
        )
        self.write_executable(self.bin / "git", GIT_WRAPPER)
        self.write_executable(self.bin / "yq", YQ_FIXTURE)
        self.git("init", "-q", "--bare", "-b", "main", str(self.remote))
        self.git("init", "-q", "-b", "main", str(self.seed))
        self.configure_identity(self.seed)
        for directory in ("scripts", "meta", "keys/alice", "authorized_keys"):
            (self.seed / directory).mkdir(parents=True, exist_ok=True)
        for script, phase in (("cleanup_expired.sh", "cleanup"),
                              ("validate_keys.sh", "validate"),
                              ("deploy_keys.sh", "generate")):
            source = (ROOT / "scripts" / script).read_text()
            first_line, rest = source.split("\n", 1)
            trace = ('printf \'{"command":"phase","phase":"%s",'
                     '"skip_push":"%%s"}\\n\' "${SKIP_PUSH:-}" >> "$CALL_LOG"\n') % phase
            (self.seed / "scripts" / script).write_text(first_line + "\n" + trace + rest)
        shutil.copyfile(ROOT / "scripts/publish_keys.sh", self.seed / "scripts/publish_keys.sh")
        fixture_key = self.root / "disposable-key"
        self.command(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(fixture_key)])
        self.public_key = fixture_key.with_suffix(".pub").read_text()
        fixture_key.unlink()
        fixture_key.with_suffix(".pub").unlink()
        keys = []
        for name, expiry in (("expired_rsa.pub", "2000-01-01T00:00:00Z"),
                             ("active_rsa.pub", None)):
            (self.seed / "keys/alice" / name).write_text(self.public_key)
            keys.append({"filename": name, "comment": None,
                         "added_at": "1999-01-01T00:00:00Z", "expires_at": expiry,
                         "revoked": False, "environments": ["all"]})
        (self.seed / "meta/alice.yaml").write_text(json.dumps({"user": "alice", "keys": keys}))
        (self.seed / "envs.yaml").write_text(json.dumps({"environments": ["first", "second"]}))
        for environment in ("first", "second"):
            (self.seed / "authorized_keys" / environment).write_text("stale published output\n")
        self.git("add", ".", cwd=self.seed)
        self.git("commit", "-qm", "Published source fixture", cwd=self.seed)
        self.git("remote", "add", "origin", str(self.remote), cwd=self.seed)
        self.git("push", "-q", "origin", "main", cwd=self.seed)
        self.base = self.remote_tip()
        for clone in (self.repo, self.writer):
            self.git("clone", "-q", str(self.remote), str(clone))
            self.configure_identity(clone)
        # Reproduce the workflow's already-completed preparation. These real
        # scripts may commit locally but must not publish their partial work.
        for script in ("cleanup_expired.sh", "validate_keys.sh", "deploy_keys.sh"):
            self.command(["bash", f"scripts/{script}"], cwd=self.repo)
        self.pending = self.git("rev-parse", "HEAD", cwd=self.repo)
        self.assertNotEqual(self.pending, self.base)
        self.assertEqual(self.remote_tip(), self.base)
        self.log.write_text("")

    def write_executable(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def command(self, args, cwd=None, check=True, env=None):
        return subprocess.run(args, cwd=cwd or self.root, env=env or self.env,
                              check=check, capture_output=True, text=True, timeout=30)

    def git(self, *args, cwd=None):
        return self.command([REAL_GIT, *args], cwd=cwd).stdout.strip()

    def configure_identity(self, repo):
        self.git("config", "user.name", "Publication Fixture", cwd=repo)
        self.git("config", "user.email", "fixture@example.invalid", cwd=repo)

    def remote_tip(self):
        return self.git("--git-dir", str(self.remote), "rev-parse", "refs/heads/main")

    def remote_file(self, path):
        return self.git("--git-dir", str(self.remote), "show", f"main:{path}")

    def calls(self, command):
        return [entry for entry in map(json.loads, self.log.read_text().splitlines())
                if entry["command"] == command]

    def publish(self, **settings):
        # Deliberately start with push enabled: the helper itself must ensure
        # that every retry pipeline keeps its intermediate commits local.
        env = dict(self.env, SKIP_PUSH="false", **settings)
        result = self.command(["bash", "scripts/publish_keys.sh"], cwd=self.repo,
                              env=env, check=False)
        self.output = result.stdout + result.stderr
        return result.returncode

    def assert_safe_pushes(self, count):
        pushes = self.calls("push")
        self.assertEqual(len(pushes), count, self.output)
        for push in pushes:
            self.assertEqual(push["args"], ["push", "--porcelain", "origin", "HEAD:main"])
        for forbidden in ("rebase", "merge", "cherry-pick"):
            self.assertEqual(self.calls(forbidden), [], self.output)

    def assert_phases(self, phases):
        entries = self.calls("phase")
        self.assertEqual([entry["phase"] for entry in entries], phases, self.output)
        self.assertTrue(all(entry["skip_push"] == "true" for entry in entries))

    def assert_successful_regeneration(self, concurrent_writes):
        self.assertEqual(self.remote_tip(), self.git("rev-parse", "HEAD", cwd=self.repo))
        self.assertEqual(self.git("status", "--porcelain", cwd=self.repo), "")
        keys = json.loads(self.remote_file("meta/alice.yaml"))["keys"]
        self.assertNotIn("expired_rsa.pub", [key["filename"] for key in keys])
        self.assertTrue(next(key for key in keys if key["filename"] == "active_rsa.pub")["revoked"])
        expected_names = {f"alice:concurrent_{number}_rsa.pub"
                          for number in range(1, concurrent_writes + 1)}
        for environment in ("first", "second"):
            output = self.remote_file(f"authorized_keys/{environment}")
            actual_names = {line.split()[-1] for line in output.splitlines()
                            if line and not line.startswith("#")}
            self.assertEqual(actual_names, expected_names)
        self.assertEqual(self.remote_file("concurrent-notes.txt").splitlines(),
                         [f"concurrent source edit {number}"
                          for number in range(1, concurrent_writes + 1)])
        # Replaying the old generation would preserve the revoked key and omit
        # new keys. Its original commit must not be in the published history.
        result = self.command([REAL_GIT, "merge-base", "--is-ancestor", self.pending,
                               self.remote_tip()], cwd=self.repo, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.git("rev-list", "--merges", f"{self.base}..HEAD", cwd=self.repo), "")
        for commit in self.calls("concurrent-commit"):
            self.command([REAL_GIT, "merge-base", "--is-ancestor", commit["head"], "HEAD"],
                         cwd=self.repo)

    def test_no_race_publishes_once_without_rebuilding(self):
        self.assertEqual(self.publish(), 0, self.output)
        self.assert_safe_pushes(1)
        self.assert_phases([])
        self.assertEqual(self.calls("fetch"), [])
        self.assertEqual(self.remote_tip(), self.pending)

    def test_dirty_worktree_is_refused_without_losing_local_changes(self):
        path = self.repo / "meta/alice.yaml"
        edited = path.read_text() + "\n"
        path.write_text(edited)
        self.assertNotEqual(self.publish(), 0)
        self.assertIn("unclean working tree", self.output)
        self.assert_safe_pushes(0)
        self.assertEqual(self.calls("fetch"), [])
        self.assertEqual(self.calls("reset"), [])
        self.assert_phases([])
        self.assertEqual(path.read_text(), edited)
        self.assertEqual(self.remote_tip(), self.base)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.repo), self.pending)

    def test_rejection_without_new_remote_advance_is_not_retried(self):
        # A stale local branch with an already-current tracking ref is not a
        # newly observed writer race. Do not throw away local work in this case.
        (self.writer / "concurrent-notes.txt").write_text("already known edit\n")
        self.git("add", ".", cwd=self.writer)
        self.git("commit", "-qm", "Already observed source edit", cwd=self.writer)
        self.git("push", "-q", "origin", "main", cwd=self.writer)
        self.git("fetch", "-q", "origin", "main", cwd=self.repo)
        remote_tip = self.remote_tip()
        self.assertNotEqual(self.publish(), 0)
        self.assertIn("[rejected] (non-fast-forward)", self.output)
        self.assert_safe_pushes(1)
        self.assertEqual(len(self.calls("fetch")), 1)
        self.assertEqual(self.calls("reset"), [])
        self.assert_phases([])
        self.assertEqual(self.remote_tip(), remote_tip)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.repo), self.pending)

    def test_fetch_first_race_rebuilds_and_preserves_concurrent_source_edits(self):
        self.assertEqual(self.publish(RACE_WRITES="1"), 0, self.output)
        self.assertIn("[rejected] (fetch first)", self.output)
        self.assert_safe_pushes(2)
        self.assertEqual(len(self.calls("fetch")), 1)
        self.assert_phases(["cleanup", "validate", "generate"])
        self.assert_successful_regeneration(1)

    def test_non_fast_forward_race_is_also_retried(self):
        self.assertEqual(self.publish(RACE_WRITES="1", KNOW_REMOTE_COMMIT="1"), 0, self.output)
        self.assertIn("[rejected] (non-fast-forward)", self.output)
        self.assert_safe_pushes(2)
        self.assert_phases(["cleanup", "validate", "generate"])
        self.assert_successful_regeneration(1)

    def test_second_race_rebuilds_again_and_succeeds_on_last_attempt(self):
        self.assertEqual(self.publish(RACE_WRITES="2"), 0, self.output)
        self.assert_safe_pushes(3)
        self.assertEqual(len(self.calls("fetch")), 2)
        self.assert_phases(["cleanup", "validate", "generate"] * 2)
        self.assert_successful_regeneration(2)

    def test_validation_failure_on_fresh_main_never_publishes(self):
        self.assertNotEqual(self.publish(RACE_WRITES="1", RACE_KIND="invalid"), 0)
        self.assert_safe_pushes(1)
        self.assert_phases(["cleanup", "validate"])
        self.assertEqual(self.remote_tip(), self.calls("concurrent-commit")[-1]["head"])
        self.assertEqual(self.remote_file("authorized_keys/first"), "stale published output")
        # Cleanup ran and committed locally, but its result was not published.
        self.assertIn("expired_rsa.pub", self.remote_file("meta/alice.yaml"))
        self.assertFalse((self.repo / "keys/alice/expired_rsa.pub").exists())

    def test_partial_generation_failure_on_retry_never_publishes(self):
        self.assertNotEqual(self.publish(RACE_WRITES="1", RACE_KIND="generation-failure"), 0)
        self.assert_safe_pushes(1)
        self.assert_phases(["cleanup", "validate", "generate"])
        self.assertIn("Is a directory", self.output)
        self.assertIn("alice:concurrent_1_rsa.pub", (self.repo / "authorized_keys/first").read_text())
        self.assertEqual(self.remote_tip(), self.calls("concurrent-commit")[-1]["head"])
        for environment in ("first", "second"):
            self.assertEqual(self.remote_file(f"authorized_keys/{environment}"), "stale published output")

    def test_repeated_races_exhaust_three_attempts_without_overwriting_main(self):
        self.assertNotEqual(self.publish(RACE_WRITES="3"), 0)
        self.assert_safe_pushes(3)
        self.assertEqual(len(self.calls("fetch")), 2)
        self.assert_phases(["cleanup", "validate", "generate"] * 2)
        self.assertRegex(self.output, r"(?i)exhaust.*3.*attempt")
        self.assertEqual(self.remote_tip(), self.calls("concurrent-commit")[-1]["head"])
        self.assertEqual(self.remote_file("concurrent-notes.txt").splitlines(),
                         [f"concurrent source edit {number}" for number in range(1, 4)])
        self.assertEqual(self.remote_file("authorized_keys/first"), "stale published output")

    def test_hook_rejection_is_not_retried(self):
        self.assertNotEqual(self.publish(DENY_PUBLISH="1"), 0)
        self.assertIn("fixture permission denied", self.output)
        self.assert_safe_pushes(1)
        self.assertEqual(self.calls("fetch"), [])
        self.assert_phases([])
        self.assertEqual(self.remote_tip(), self.base)
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.repo), self.pending)

    def test_failed_fetch_does_not_reset_rebuild_or_push_again(self):
        self.assertNotEqual(self.publish(RACE_WRITES="1", FAIL_FETCH="1"), 0)
        self.assertIn("fixture fetch transport failed", self.output)
        self.assert_safe_pushes(1)
        self.assertEqual(len(self.calls("fetch")), 1)
        self.assertEqual(self.calls("reset"), [])
        self.assert_phases([])
        self.assertEqual(self.git("rev-parse", "HEAD", cwd=self.repo), self.pending)
        self.assertEqual(self.remote_tip(), self.calls("concurrent-commit")[-1]["head"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
