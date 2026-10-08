#!/usr/bin/env python3
"""Offline workflow regression tests. Requires Python 3 and PyYAML.

All repositories are disposable local fixtures. Git push is intercepted and
logged; no remote is configured and no network or host keys are touched.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = yaml.safe_load((ROOT / '.github/workflows/ci.yml').read_text())
JOB = WORKFLOW['jobs']['cleanup']
STEPS = JOB['steps']
REAL_GIT = shutil.which('git')


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ssh-keys-publication-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls'
        self.output = self.root / 'output'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        CALL_LOG=str(self.log), GITHUB_OUTPUT=str(self.output),
                        REAL_GIT=REAL_GIT, IS_TRACE='false')
        self.env.update({key: str(value) for key, value in JOB.get('env', {}).items()})
        self.write_executable(self.bin / 'git', '''#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == push ]]; then
  echo "push $*" >> "$CALL_LOG"
  exit "${FAIL_PUSH:-0}"
fi
exec "$REAL_GIT" "$@"
''')
        self.git('init', '-q', '-b', 'main')
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        (self.repo / 'scripts').mkdir()
        self.write_executable(self.repo / 'scripts/cleanup_expired.sh', '''#!/usr/bin/env bash
set -euo pipefail
echo cleanup >> "$CALL_LOG"
if [[ -f expired ]]; then
  rm expired
  git add -A
  git commit -qm cleanup
  if [[ "${SKIP_PUSH:-false}" != true ]]; then git push origin main; fi
fi
''')
        self.write_executable(self.repo / 'scripts/validate_keys.sh', '''#!/usr/bin/env bash
set -euo pipefail
echo validate >> "$CALL_LOG"
exit "${FAIL_VALIDATE:-0}"
''')
        self.write_executable(self.repo / 'scripts/deploy_keys.sh', '''#!/usr/bin/env bash
set -euo pipefail
echo generate >> "$CALL_LOG"
echo generated > authorized_keys
git add authorized_keys
git diff --cached --quiet || git commit -qm generate
if [[ "${SKIP_PUSH:-false}" != true ]]; then git push origin HEAD; fi
exit "${FAIL_GENERATE:-0}"
''')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')

    def write_executable(self, path, text):
        path.write_text(text)
        path.chmod(0o755)

    def git(self, *args):
        return subprocess.check_output([REAL_GIT, *args], cwd=self.repo, text=True).strip()

    def expire(self):
        (self.repo / 'expired').write_text('fixture only')
        self.git('add', '.')
        self.git('commit', '-qm', 'expiry fixture')

    def run_job(self, event, **overrides):
        self.log.write_text('')
        self.output.write_text('')
        env = dict(self.env, **overrides)
        changed = False
        for step in STEPS:
            if 'run' not in step:
                continue
            condition = step.get('if')
            if condition:
                self.assertEqual(condition, "github.event_name != 'schedule' || steps.cleanup.outputs.changed == 'true'")
                if event == 'schedule' and not changed:
                    continue
            result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', step['run']],
                                    cwd=self.repo, env=env, text=True, capture_output=True)
            if result.returncode:
                return result.returncode
            changed = 'changed=true' in self.output.read_text()
        return 0

    def calls(self):
        return self.log.read_text().splitlines()

    def use_actual_cleanup_and_generation(self):
        for name in ('cleanup_expired.sh', 'deploy_keys.sh'):
            shutil.copyfile(ROOT / 'scripts' / name, self.repo / 'scripts' / name)
        (self.repo / 'meta').mkdir()
        (self.repo / 'keys').mkdir()
        (self.repo / 'keys/.keep').write_text('')
        (self.repo / 'envs.yaml').write_text('environments: [first, second]\n')
        (self.repo / 'meta/alice.yaml').write_text(
            'user: alice\nkeys:\n  - filename: missing.pub\n    expires_at: null\n')
        # A source-only test double for the exact yq expressions these fixtures
        # exercise. Never download or execute the repository's bundled binary.
        self.write_executable(self.bin / 'yq', '''#!/usr/bin/env python3
import re
import sys
import yaml
args = sys.argv[1:]
assert args.pop(0) == 'e'
in_place = args[0] == '-i'
if in_place:
    args.pop(0)
expression, path = args
with open(path) as source:
    data = yaml.safe_load(source)
if expression == '.user':
    print(data['user'])
elif expression == '.keys | length':
    print(len(data.get('keys') or []))
elif expression == '.environments[]':
    print('\\n'.join(data['environments']))
elif re.fullmatch(r'\\.keys\\[(\\d+)\\]\\.(filename|expires_at)', expression):
    match = re.fullmatch(r'\\.keys\\[(\\d+)\\]\\.(filename|expires_at)', expression)
    value = data['keys'][int(match[1])].get(match[2])
    print('null' if value is None else value)
elif re.fullmatch(r'del\\(\\.keys\\[(\\d+)\\]\\)', expression):
    match = re.fullmatch(r'del\\(\\.keys\\[(\\d+)\\]\\)', expression)
    del data['keys'][int(match[1])]
else:
    raise SystemExit('unsupported fixture expression: ' + expression)
if in_place:
    with open(path, 'w') as output:
        yaml.safe_dump(data, output)
''')
        self.git('add', '.')
        self.git('commit', '-qm', 'actual script fixture')

    def test_actual_scripts_defer_all_pushes_until_final_publication(self):
        self.use_actual_cleanup_and_generation()
        self.assertEqual(self.run_job('schedule'), 0)
        self.assertEqual(self.calls(), ['validate', 'push push origin HEAD:main'])
        self.assertEqual(yaml.safe_load((self.repo / 'meta/alice.yaml').read_text())['keys'], [])
        for env in ('first', 'second'):
            self.assertIn(env, (self.repo / 'authorized_keys' / env).read_text())
        self.assertEqual(self.git('status', '--porcelain'), '')

    def test_actual_scripts_preserve_standalone_publication(self):
        self.use_actual_cleanup_and_generation()
        self.log.write_text('')
        env = dict(self.env)
        env.pop('SKIP_PUSH', None)
        for name in ('cleanup_expired.sh', 'deploy_keys.sh'):
            subprocess.run(['bash', f'scripts/{name}'], cwd=self.repo, env=env,
                           check=True, capture_output=True, text=True)
        self.assertEqual(self.calls(), ['push push origin main',
                                       'push push origin HEAD', 'push push origin HEAD'])

    def test_single_publication_after_validation_and_generation(self):
        self.expire()
        self.assertEqual(self.run_job('schedule'), 0)
        self.assertEqual(self.calls(), ['cleanup', 'validate', 'generate', 'push push origin HEAD:main'])
        self.assertEqual(JOB['env']['SKIP_PUSH'], 'true')

    def test_failed_validation_retries_from_unchanged_published_state(self):
        self.expire()
        published = self.git('rev-parse', 'HEAD')
        self.assertNotEqual(self.run_job('schedule', FAIL_VALIDATE='1'), 0)
        self.assertEqual(self.calls(), ['cleanup', 'validate'])
        # A fresh checkout starts at the unchanged remote commit. No new expiry
        # is introduced: the original, unpublished cleanup is naturally retried.
        self.git('reset', '--hard', published)
        self.assertEqual(self.run_job('schedule'), 0)
        self.assertEqual(self.calls(), ['cleanup', 'validate', 'generate', 'push push origin HEAD:main'])

    def test_generation_failure_does_not_publish_partial_outputs(self):
        self.expire()
        self.assertNotEqual(self.run_job('schedule', FAIL_GENERATE='1'), 0)
        self.assertEqual(self.calls(), ['cleanup', 'validate', 'generate'])

    def test_no_change_schedule_is_quiet(self):
        self.assertEqual(self.run_job('schedule'), 0)
        self.assertEqual(self.calls(), ['cleanup'])

    def test_manual_recovery_without_new_expiry(self):
        self.assertEqual(self.run_job('workflow_dispatch'), 0)
        self.assertEqual(self.calls(), ['cleanup', 'validate', 'generate', 'push push origin HEAD:main'])

    def test_main_push_without_expiry_still_regenerates(self):
        self.assertEqual(self.run_job('push'), 0)
        self.assertEqual(self.calls(), ['cleanup', 'validate', 'generate', 'push push origin HEAD:main'])

    def test_push_failure_is_not_ignored(self):
        self.assertNotEqual(self.run_job('workflow_dispatch', FAIL_PUSH='1'), 0)


if __name__ == '__main__':
    unittest.main(verbosity=2)
