import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createEngine } from './harness.mjs';

let lua;
beforeEach(async () => { lua = await createEngine(); });
afterEach(() => lua.global.close());

const WORKFLOW = `{ id='dig', durationMs=5000, cooldownMs=10000 }`;

describe('Workflow validation', () => {
  const validate = (definition) => lua.doString(`
    local result = NxcInteract.Workflow.validate(${definition})
    if result.ok then return { ok = true, advisory = result.value.advisory } end
    local fields = {}
    for _, f in ipairs(result.error.details.fields) do fields[#fields + 1] = f.field end
    table.sort(fields)
    return { ok = false, fields = table.concat(fields, ',') }
  `);

  test('a minimal workflow validates', async () => {
    assert.equal((await validate(`{ id='dig', durationMs=5000 }`)).ok, true);
  });

  test('a duration is required', async () => {
    const r = await validate(`{ id='dig' }`);
    // The duration IS the contract. Everything else is presentation.
    assert.equal(r.ok, false);
    assert.equal(r.fields, 'durationMs');
  });

  test('a duration is bounded at both ends', async () => {
    assert.equal((await validate(`{ id='x', durationMs=10 }`)).ok, false);
    assert.equal((await validate(`{ id='x', durationMs=999999999 }`)).ok, false);
    assert.equal((await validate(`{ id='x', durationMs=5000 }`)).ok, true);
  });

  test('a progress step must say what it is doing', async () => {
    const r = await validate(
      `{ id='x', durationMs=5000, steps={ { kind='progress' } } }`);
    // A bar with no label tells a player nothing except that they cannot move.
    assert.equal(r.ok, false);
    assert.equal(r.fields, 'steps[1].label');
  });

  test('an animation needs both a dictionary and a name', async () => {
    const r = await validate(
      `{ id='x', durationMs=5000, steps={ { kind='animation', dict='d' } } }`);
    assert.equal(r.ok, false);
    assert.equal(r.fields, 'steps[1].anim');
  });

  test('an unknown step kind is refused and stops there', async () => {
    const r = await validate(
      `{ id='x', durationMs=5000, steps={ { kind='teleport' } } }`);
    assert.equal(r.ok, false);
    assert.equal(r.fields, 'steps[1].kind');
  });

  test('a client-decided skill check is accepted, with an advisory', async () => {
    const r = await validate(`{ id='x', durationMs=5000, steps={
      { kind='skillCheck', decidedBy='client', difficulty=0.5 } } }`);
    // Accepted, because a skill check that only affects flavour is legitimate
    // and common. Refusing it would push authors to fake one.
    assert.equal(r.ok, true);
    assert.match(r.advisory, /decided by the player/);
  });

  test('a server-decided skill check draws no advisory', async () => {
    const r = await validate(`{ id='x', durationMs=5000, steps={
      { kind='skillCheck', decidedBy='server', difficulty=0.5 } } }`);
    assert.equal(r.ok, true);
    assert.equal(r.advisory, undefined);
  });

  test('server is the default, so forgetting to choose is the safe choice', async () => {
    const r = await validate(`{ id='x', durationMs=5000, steps={
      { kind='skillCheck', difficulty=0.5 } } }`);
    // A default that fails open is a default nobody notices until it matters.
    assert.equal(r.ok, true);
    assert.equal(r.advisory, undefined);
  });
});

describe('Duration enforcement', () => {
  const satisfied = (durationMs, elapsedMs) => lua.doString(
    `return NxcInteract.Workflow.durationSatisfied({ durationMs = ${durationMs} }, ${elapsedMs})`);

  test('the full duration is enough', async () => {
    assert.equal(await satisfied(5000, 5000), true);
    assert.equal(await satisfied(5000, 6000), true);
  });

  test('a little early is tolerated, because clocks differ', async () => {
    assert.equal(await satisfied(5000, 4800), true);
  });

  test('meaningfully early is refused', async () => {
    // A player who shaves 250ms off five seconds has gained nothing. One who
    // shaves five seconds has removed the action.
    assert.equal(await satisfied(5000, 4000), false);
    assert.equal(await satisfied(5000, 10), false);
    assert.equal(await satisfied(5000, 0), false);
  });

  test('a non-numeric elapsed time is refused rather than coerced', async () => {
    assert.equal(await satisfied(5000, `'5000'`), false);
    assert.equal(await satisfied(5000, 'nil'), false);
  });
});

describe('In-flight workflows', () => {
  const FIXTURE = `
    local state = NxcInteract.Sessions.new()
    local workflow = ${WORKFLOW}
  `;

  test('starting records the start', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      local started = NxcInteract.Sessions.start(state, 1, workflow, 1000, 'corr')
      return { ok = started.ok, inFlight = NxcInteract.Sessions.inFlight(state, 1).workflowId }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.inFlight, 'dig');
  });

  test('a second start is refused rather than replacing the first', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      NxcInteract.Sessions.start(state, 1, workflow, 1000, 'a')
      local second = NxcInteract.Sessions.start(state, 1, workflow, 1100, 'b')
      return { ok = second.ok, code = second.error.code,
               startedAt = NxcInteract.Sessions.inFlight(state, 1).startedAtMs }
    `);
    // Replacing would let a player start a five second action, start it again,
    // and have two completions in flight for one wait.
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_INTERACT_ALREADY_BUSY');
    assert.equal(r.startedAt, 1000, 'the original start was overwritten');
  });

  test('completing after the duration succeeds', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      NxcInteract.Sessions.start(state, 1, workflow, 1000, 'corr')
      local done = NxcInteract.Sessions.complete(state, 1, 'dig', workflow, 6000)
      return { ok = done.ok, elapsed = done.value.elapsedMs,
               stillInFlight = NxcInteract.Sessions.inFlight(state, 1) ~= nil }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.elapsed, 5000);
    assert.equal(r.stillInFlight, false);
  });

  test('completing too early is refused, and clears the flight', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      NxcInteract.Sessions.start(state, 1, workflow, 1000, 'corr')
      local done = NxcInteract.Sessions.complete(state, 1, 'dig', workflow, 1200)
      return { ok = done.ok, code = done.error.code,
               stillInFlight = NxcInteract.Sessions.inFlight(state, 1) ~= nil }
    `);
    // THE CENTRAL CHECK. Elapsed time is measured from the start the SERVER
    // recorded; nothing the client says about timing is consulted.
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_INTERACT_TOO_FAST');
    // Cleared, so a forged completion does not leave the player able to retry
    // instantly against the same start.
    assert.equal(r.stillInFlight, false);
  });

  test('completing something that was never started is refused', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      local done = NxcInteract.Sessions.complete(state, 1, 'dig', workflow, 9999)
      return done.error.code
    `);
    assert.equal(r, 'NXC_INTERACT_NOT_STARTED');
  });

  test('starting one workflow and completing another is refused', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      local long = { id='mine', durationMs=60000 }
      NxcInteract.Sessions.start(state, 1, long, 1000, 'corr')
      local done = NxcInteract.Sessions.complete(state, 1, 'dig', workflow, 6000)
      return { code = done.error.code, started = done.error.details.started }
    `);
    // Without an identity check, a player could start a one minute workflow and
    // complete a five second one against its timer.
    assert.equal(r.code, 'NXC_INTERACT_WRONG_WORKFLOW');
    assert.equal(r.started, 'mine');
  });
});

describe('Cooldowns', () => {
  const FIXTURE = `
    local state = NxcInteract.Sessions.new()
    local workflow = ${WORKFLOW}
  `;

  test('a cooldown blocks a second run and then expires', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      NxcInteract.Sessions.start(state, 1, workflow, 1000, 'a')
      NxcInteract.Sessions.complete(state, 1, 'dig', workflow, 6000)
      return {
        immediately = NxcInteract.Sessions.canStart(state, 1, workflow, 6100).ok,
        code = NxcInteract.Sessions.canStart(state, 1, workflow, 6100).error.code,
        later = NxcInteract.Sessions.canStart(state, 1, workflow, 17000).ok,
      }
    `);
    assert.equal(r.immediately, false);
    assert.equal(r.code, 'NXC_INTERACT_COOLDOWN');
    assert.equal(r.later, true);
  });

  test('a cooldown is per player and per workflow', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      NxcInteract.Sessions.start(state, 1, workflow, 1000, 'a')
      NxcInteract.Sessions.complete(state, 1, 'dig', workflow, 6000)
      local other = { id='chop', durationMs=5000, cooldownMs=10000 }
      return {
        otherPlayer = NxcInteract.Sessions.canStart(state, 2, workflow, 6100).ok,
        otherWorkflow = NxcInteract.Sessions.canStart(state, 1, other, 6100).ok,
      }
    `);
    // A global cooldown would make one player's action block everyone; a
    // per-player-only one would make a long workflow block a short unrelated one.
    assert.equal(r.otherPlayer, true);
    assert.equal(r.otherWorkflow, true);
  });

  test('cancelling sets no cooldown', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      NxcInteract.Sessions.start(state, 1, workflow, 1000, 'a')
      NxcInteract.Sessions.abandon(state, 1)
      return NxcInteract.Sessions.canStart(state, 1, workflow, 1100).ok
    `);
    // Punishing a cancelled action makes cancelling worse than never starting,
    // which is backwards for the one control a player has.
    assert.equal(r, true);
  });

  test('a completion refused as too fast sets no cooldown either', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      NxcInteract.Sessions.start(state, 1, workflow, 1000, 'a')
      NxcInteract.Sessions.complete(state, 1, 'dig', workflow, 1200)
      return NxcInteract.Sessions.canStart(state, 1, workflow, 1300).ok
    `);
    // The action did not happen, so nothing is owed. Setting one would let a
    // forged completion deny the player their real attempt.
    assert.equal(r, true);
  });

  test('disconnecting forgets a player entirely', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      NxcInteract.Sessions.start(state, 1, workflow, 1000, 'a')
      NxcInteract.Sessions.complete(state, 1, 'dig', workflow, 6000)
      NxcInteract.Sessions.start(state, 2, workflow, 1000, 'b')

      NxcInteract.Sessions.forget(state, 1)
      return {
        gone = NxcInteract.Sessions.canStart(state, 1, workflow, 6100).ok,
        otherUntouched = NxcInteract.Sessions.inFlight(state, 2) ~= nil,
      }
    `);
    // A cooldown limits a player's rate of action, and a player who is gone has
    // no rate. Keeping it would also grow the table forever.
    assert.equal(r.gone, true);
    assert.equal(r.otherUntouched, true);
  });

  test('pruning drops expired cooldowns and keeps live ones', async () => {
    const r = await lua.doString(`
      ${FIXTURE}
      for player = 1, 5 do
        NxcInteract.Sessions.start(state, player, workflow, 1000, 'c')
        NxcInteract.Sessions.complete(state, player, 'dig', workflow, 6000)
      end
      local removed = NxcInteract.Sessions.prune(state, 20000)
      local left = 0
      for _ in pairs(state.cooldowns) do left = left + 1 end
      return { removed = removed, left = left }
    `);
    // Slow rather than wrong is how a table becomes a memory problem.
    assert.equal(r.removed, 5);
    assert.equal(r.left, 0);
  });
});

describe('Workflow identity', () => {
  test('two resources with the same workflow id do not share a cooldown', async () => {
    const r = await lua.doString(`
      local state = NxcInteract.Sessions.new()
      -- The registry keys workflows by owner:id so two resources can each have
      -- their own dig. The in-flight record and the cooldown must agree on which
      -- identity they track, or one resource silently blocks the other.
      local mine  = { id='dig', key='my_job:dig',    durationMs=5000, cooldownMs=10000 }
      local yours = { id='dig', key='other_job:dig', durationMs=5000, cooldownMs=10000 }

      NxcInteract.Sessions.start(state, 1, mine, 1000, 'a')
      NxcInteract.Sessions.complete(state, 1, 'my_job:dig', mine, 6000)

      return {
        sameOneBlocked = NxcInteract.Sessions.canStart(state, 1, mine, 6100).ok,
        otherAllowed = NxcInteract.Sessions.canStart(state, 1, yours, 6100).ok,
      }
    `);
    // The loud half of this bug was every completion mismatching its own start.
    // THIS half would have been silent: one resource's cooldown quietly applying
    // to another's unrelated workflow.
    assert.equal(r.sameOneBlocked, false);
    assert.equal(r.otherAllowed, true, "another resource's dig was blocked by this one");
  });

  test('a completion must name the same identity the start recorded', async () => {
    const r = await lua.doString(`
      local state = NxcInteract.Sessions.new()
      local workflow = { id='dig', key='my_job:dig', durationMs=5000 }
      NxcInteract.Sessions.start(state, 1, workflow, 1000, 'a')
      return {
        byKey = NxcInteract.Sessions.complete(state, 1, 'my_job:dig', workflow, 6000).ok,
      }
    `);
    assert.equal(r.byKey, true);
  });
});
