#!/usr/bin/env node
// Translate Codex hook JSON to the huddle's small shared payload contract.
const { execFileSync } = require('child_process');
const path = require('path');
const event = process.argv[2] || 'poll';
let raw = '';
process.stdin.on('data', chunk => { raw += chunk; });
process.stdin.on('end', () => {
  let input = {}; try { input = JSON.parse(raw || '{}'); } catch {}
  const cwd = input.cwd || process.cwd();
  const payload = JSON.stringify({ session_id: input.session_id || input.sessionId || input.thread_id || input.threadId || '', transcript_path: input.transcript_path || input.transcriptPath || '', cwd, hook_event_name: event === 'start' ? 'SessionStart' : event === 'post-tool' ? 'PostToolUse' : 'UserPromptSubmit', source: 'startup', harness: 'Codex' });
  const here = __dirname;
  const run = script => { try { return execFileSync('bash', [path.join(here, script)], { cwd, input: payload, encoding: 'utf8', timeout: 9000 }); } catch { return ''; } };
  let output = event === 'start' ? run('huddle-session-start.sh') : run('huddle-poll.sh');
  if (event === 'post-tool') {
    try { execFileSync('bash', [path.join(here, 'huddle-pr-announce.sh')], { cwd, input: raw, stdio: ['pipe', 'ignore', 'ignore'], timeout: 5000 }); } catch {}
  }
  if (output) {
    process.stdout.write(JSON.stringify({
      continue: true,
      hookSpecificOutput: {
        hookEventName: event === 'start' ? 'SessionStart' : event === 'post-tool' ? 'PostToolUse' : 'UserPromptSubmit',
        additionalContext: output,
      },
    }));
  }
});
