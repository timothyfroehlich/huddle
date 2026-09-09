#!/usr/bin/env node
// Global Antigravity adapter.  It retains Antigravity's real transcript path
// and uses its documented ephemeralMessage injection field.
const { execFileSync } = require('child_process');
const path = require('path');
const phase = process.argv[2] || 'before-agent';
let raw = '';
process.stdin.on('data', chunk => { raw += chunk; });
process.stdin.on('end', () => {
  let input = {}; try { input = JSON.parse(raw || '{}'); } catch {}
  const cwd = input.workspacePaths?.[0] || process.cwd();
  const start = phase === 'before-agent' && input.invocationNum === 0;
  const hookEvent = phase === 'post-tool' ? 'PostToolUse' : start ? 'SessionStart' : 'UserPromptSubmit';
  const payload = JSON.stringify({ session_id: input.conversationId || '', transcript_path: input.transcriptPath || '', cwd, hook_event_name: hookEvent, source: 'startup' });
  const here = __dirname;
  const run = script => { try { return execFileSync('bash', [path.join(here, script)], { cwd, input: payload, encoding: 'utf8', timeout: 9000 }); } catch { return ''; } };
  let output = phase === 'post-tool' ? '' : start ? run('huddle-session-start.sh') : run('huddle-poll.sh');
  if (phase === 'post-tool') {
    const announcePayload = JSON.stringify({
      ...input,
      tool_name: input.tool_name || input.toolName || '',
      tool_input: input.tool_input || input.toolInput || {},
      tool_response: input.tool_response || input.toolResponse || {},
    });
    try { execFileSync('bash', [path.join(here, 'huddle-pr-announce.sh')], { cwd, input: announcePayload, stdio: ['pipe', 'ignore', 'ignore'], timeout: 5000 }); } catch {}
  }
  process.stdout.write(phase === 'post-tool' ? '{}' : JSON.stringify({ injectSteps: output.trim() ? [{ ephemeralMessage: output.trim() }] : [] }));
});
