import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createResourceEngine } from './boundary.mjs';

/**
 * The server gate, driven the way a modified client would drive it.
 *
 * The handlers are net events, so they are invoked directly with the natives
 * stubbed — which is exactly what a forged `TriggerServerEvent` does.
 */
describe('The interaction gate', () => {
  let lua;

  beforeEach(async () => {
    lua = await createResourceEngine('nxc_interact', {
      blocks: ['shared_scripts', 'server_scripts'],
    });

    await lua.doString(`
      __toClient = {}
      __dispatched = {}
      __consumed = {}
      __capabilities = {}
      __now = 1000

      Nxc.Time.setClock(function() return __now end)

      function TriggerClientEvent(name, target, ...)
        __toClient[#__toClient + 1] = { name = name, args = { ... } }
      end
      function TriggerEvent(name, context)
        __dispatched[#__dispatched + 1] = { name = name, context = context }
      end

      exports = setmetatable({}, { __index = function()
        return {
          hasCapability = function(_, cap) return __capabilities[cap] == true end,
          accountFor = function() return 'acc_test' end,
          characterFor = function() return nil end,
        }
      end })

      function __start(request, from)
        source = from or 5
        __events['nxc_interact:server:start'](request)
      end
      function __complete(report, from)
        source = from or 5
        __events['nxc_interact:server:complete'](report)
      end
      function __lastRefusal()
        for i = #__toClient, 1, -1 do
          if __toClient[i].name == 'nxc_interact:client:refused' then
            return __toClient[i].args[2]
          end
        end
        return nil
      end
    `);
  });

  afterEach(() => lua.global.close());

  const register = (extra = '') => lua.doString(`
    __exports['register']({ id = 'dig', durationMs = 5000, onComplete = 'my_job:server:dug' ${extra} })
  `);

  test('the honest path dispatches once, after the duration', async () => {
    await register();
    const r = await lua.doString(`
      __start({ key = 'nxc_interact:dig' })
      __now = 6000
      __complete({ key = 'nxc_interact:dig' })
      return { count = #__dispatched, name = __dispatched[1] and __dispatched[1].name,
               elapsed = __dispatched[1] and __dispatched[1].context.elapsedMs }
    `);
    assert.equal(r.count, 1);
    assert.equal(r.name, 'my_job:server:dug');
    assert.equal(r.elapsed, 5000);
  });

  test('completing instantly dispatches nothing', async () => {
    await register();
    const r = await lua.doString(`
      __start({ key = 'nxc_interact:dig' })
      __complete({ key = 'nxc_interact:dig' })
      return { count = #__dispatched, refusal = __lastRefusal() }
    `);
    // A client that reports both ends of an interval controls the interval.
    // Which is why it does not report the start.
    assert.equal(r.count, 0);
    assert.equal(r.refusal, 'NXC_INTERACT_TOO_FAST');
  });

  test('completing without starting dispatches nothing', async () => {
    await register();
    const r = await lua.doString(`
      __now = 999999
      __complete({ key = 'nxc_interact:dig' })
      return { count = #__dispatched, refusal = __lastRefusal() }
    `);
    assert.equal(r.count, 0);
    assert.equal(r.refusal, 'NXC_INTERACT_NOT_STARTED');
  });

  test('a claimed elapsed time in the payload counts for nothing', async () => {
    await register();
    const r = await lua.doString(`
      __start({ key = 'nxc_interact:dig' })
      __complete({ key = 'nxc_interact:dig', elapsedMs = 999999, startedAtMs = 0 })
      return #__dispatched
    `);
    assert.equal(r, 0);
  });

  test('an unknown workflow dispatches nothing', async () => {
    const r = await lua.doString(`
      __start({ key = 'nxc_banking:withdrawEverything' })
      return { toClient = #__toClient, dispatched = #__dispatched }
    `);
    assert.equal(r.dispatched, 0);
  });

  test('the client cannot name the event it wants fired', async () => {
    await register();
    const r = await lua.doString(`
      __start({ key = 'nxc_interact:dig', onComplete = 'nxc_banking:server:payout' })
      __now = 6000
      __complete({ key = 'nxc_interact:dig', onComplete = 'nxc_banking:server:payout' })
      return __dispatched[1].name
    `);
    assert.equal(r, 'my_job:server:dug');
  });

  test('a missing capability refuses at the start, not after the wait', async () => {
    await register(`, capability = 'jobs.dig'`);
    const r = await lua.doString(`
      __capabilities = {}
      __start({ key = 'nxc_interact:dig' })
      return { refusal = __lastRefusal(),
               began = (function()
                 for _, m in ipairs(__toClient) do
                   if m.name == 'nxc_interact:client:begin' then return true end
                 end
                 return false
               end)() }
    `);
    // Refusing after the animation is a worse experience than refusing before,
    // for identical safety.
    // A structured code rather than a bare word, consistent with every other
    // refusal in the framework.
    assert.equal(r.refusal, 'NXC_LIB_FORBIDDEN');
    assert.equal(r.began, false);
  });

  test('a workflow that consumes is refused while no inventory exists', async () => {
    await register(`, consumes = { { item = 'shovel', count = 1 } }`);
    const r = await lua.doString(`
      __start({ key = 'nxc_interact:dig' })
      return { refusal = __lastRefusal(), dispatched = #__dispatched }
    `);
    // Refused rather than completed with the consumption silently dropped. A
    // crafting recipe that consumes nothing and produces nothing looks like it
    // worked.
    assert.equal(r.refusal, 'NXC_INTERACT_UNAVAILABLE');
    assert.equal(r.dispatched, 0);
  });

  test('a registered item provider is consulted, and can refuse', async () => {
    await register(`, consumes = { { item = 'shovel', count = 1 } }`);
    const r = await lua.doString(`
      __exports['setItemProvider'](function(_, request)
        __consumed[#__consumed + 1] = request[1].item
        return true
      end)
      __start({ key = 'nxc_interact:dig' })
      __now = 6000
      __complete({ key = 'nxc_interact:dig' })
      local afterSuccess = #__dispatched

      __exports['setItemProvider'](function() return false end)
      __now = 10000
      __start({ key = 'nxc_interact:dig' })
      __now = 16000
      __complete({ key = 'nxc_interact:dig' })
      return { afterSuccess = afterSuccess, afterRefusal = #__dispatched,
               consumed = __consumed[1] }
    `);
    assert.equal(r.afterSuccess, 1);
    assert.equal(r.consumed, 'shovel');
    assert.equal(r.afterRefusal, 1, 'a refused consumption still dispatched the handler');
  });

  test('a second start while one is in flight is refused', async () => {
    await register();
    const r = await lua.doString(`
      __start({ key = 'nxc_interact:dig' })
      __start({ key = 'nxc_interact:dig' })
      return __lastRefusal()
    `);
    assert.equal(r, 'NXC_INTERACT_ALREADY_BUSY');
  });

  test('the context is built from the server, not the payload', async () => {
    await register();
    const r = await lua.doString(`
      __start({ key = 'nxc_interact:dig' })
      __now = 6000
      __complete({ key = 'nxc_interact:dig', account = 'acc_someone_else', source = 999 })
      local context = __dispatched[1].context
      return { account = context.account, source = context.source,
               decidedBy = context.outcomeDecidedBy }
    `);
    assert.equal(r.account, 'acc_test');
    assert.equal(r.source, 5);
    assert.equal(r.decidedBy, 'server');
  });

  test('a client-decided outcome is recorded as such', async () => {
    await register(`, steps = { { kind = 'skillCheck', decidedBy = 'client' } }`);
    const r = await lua.doString(`
      __start({ key = 'nxc_interact:dig' })
      __now = 6000
      __complete({ key = 'nxc_interact:dig', success = true })
      return __dispatched[1].context.outcomeDecidedBy
    `);
    // Nothing can verify it. Recording it as claimed rather than trusted is what
    // lets a later audit tell the two apart.
    assert.equal(r, 'client');
  });

  test('a disconnect clears an in-flight workflow', async () => {
    await register();
    const r = await lua.doString(`
      __start({ key = 'nxc_interact:dig' })
      source = 5
      __events['playerDropped']()
      __now = 6000
      __complete({ key = 'nxc_interact:dig' })
      return { dispatched = #__dispatched, refusal = __lastRefusal() }
    `);
    assert.equal(r.dispatched, 0);
    assert.equal(r.refusal, 'NXC_INTERACT_NOT_STARTED');
  });
});

describe('Composing with nxc_target', () => {
  let lua;

  beforeEach(async () => {
    lua = await createResourceEngine('nxc_interact', {
      blocks: ['shared_scripts', 'server_scripts'],
    });
    await lua.doString(`
      __toClient = {} __dispatched = {} __capabilities = {} __now = 1000
      Nxc.Time.setClock(function() return __now end)
      function TriggerClientEvent(name, target, ...)
        __toClient[#__toClient + 1] = { name = name, target = target, args = { ... } }
      end
      function TriggerEvent(name, context)
        __dispatched[#__dispatched + 1] = { name = name, context = context }
      end
      exports = setmetatable({}, { __index = function() return {
        hasCapability = function(_, cap) return __capabilities[cap] == true end,
        accountFor = function() return 'acc_test' end,
        characterFor = function() return nil end } end })
    `);
  });

  afterEach(() => lua.global.close());

  test('a resource can start a workflow for a player', async () => {
    // THE LINK BETWEEN THE TWO RESOURCES. A nxc_target option handler runs on
    // the server with a validated context and no client to ask — without this
    // export it could not make the player stand there and do the thing it had
    // just decided they were allowed to do.
    const r = await lua.doString(`
      __exports['register']({ id='pick', durationMs=8000, onComplete='my_doors:server:picked' })

      -- What a target handler does with the context it was given.
      local started = __exports['begin'](5, 'nxc_interact:pick')

      local begun
      for _, m in ipairs(__toClient) do
        if m.name == 'nxc_interact:client:begin' then begun = m end
      end
      return { ok = started.ok, key = started.value.key,
               sentTo = begun and begun.target, duration = begun and begun.args[1].durationMs }
    `);
    assert.equal(r.ok, true);
    assert.equal(r.key, 'nxc_interact:pick');
    assert.equal(r.sentTo, 5);
    assert.equal(r.duration, 8000);
  });

  test('a resource starting one does not bypass the capability check', async () => {
    const r = await lua.doString(`
      __exports['register']({ id='pick', durationMs=8000, capability='doors.pick' })
      __capabilities = {}
      local started = __exports['begin'](5, 'nxc_interact:pick')
      return { ok = started.ok, code = started.error.code }
    `);
    // A resource asking on a player's behalf is not the same as the player being
    // entitled. The two diverge the moment one resource trusts another's
    // reasoning, so the session is asked either way.
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_LIB_FORBIDDEN');
  });

  test('a resource cannot start an unknown workflow', async () => {
    const r = await lua.doString(`
      local started = __exports['begin'](5, 'nxc_banking:payout')
      return { ok = started.ok, code = started.error.code }
    `);
    assert.equal(r.ok, false);
    assert.equal(r.code, 'NXC_INTERACT_UNKNOWN_WORKFLOW');
  });

  test('a resource cannot start a second workflow for a busy player', async () => {
    const r = await lua.doString(`
      __exports['register']({ id='pick', durationMs=8000 })
      __exports['begin'](5, 'nxc_interact:pick')
      local second = __exports['begin'](5, 'nxc_interact:pick')
      return second.error.code
    `);
    assert.equal(r, 'NXC_INTERACT_ALREADY_BUSY');
  });

  test('both entry points share one implementation', async () => {
    // The client asking and a resource starting must be the same code, or the
    // checks drift apart and one path quietly becomes the weak one.
    const r = await lua.doString(`
      __exports['register']({ id='pick', durationMs=8000, capability='doors.pick' })
      __capabilities = {}

      source = 5
      __events['nxc_interact:server:start']({ key = 'nxc_interact:pick' })
      local viaClient
      for _, m in ipairs(__toClient) do
        if m.name == 'nxc_interact:client:refused' then viaClient = m.args[2] end
      end

      local viaResource = __exports['begin'](5, 'nxc_interact:pick').error.code
      return { viaClient = viaClient, viaResource = viaResource }
    `);
    assert.equal(r.viaClient, r.viaResource);
    assert.equal(r.viaClient, 'NXC_LIB_FORBIDDEN');
  });
});
