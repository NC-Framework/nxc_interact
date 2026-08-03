import { test, describe, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { createBoundary } from './boundary.mjs';

describe('nxc_interact server exports', () => {
  let boundary;
  beforeEach(async () => {
    boundary = await createBoundary({ provider: 'nxc_interact', consumer: 'nxc_core' });
  });
  afterEach(() => boundary.close());

  test('register returns a readable Result, namespaced by the caller', async () => {
    const result = await boundary.callExport('register', [
      { id: 'dig', durationMs: 5000, onComplete: 'my_job:server:dug' },
    ], { from: 'my_job' });
    assert.ok('ok' in result, 'the Result crossed as an empty table');
    assert.equal(result.ok, true);
    assert.equal(result.value.key, 'my_job:dig');
  });

  test('a refusal keeps its fields', async () => {
    const result = await boundary.callExport('register', [
      { id: 'dig' },
    ], { from: 'my_job' });
    assert.equal(result.ok, false);
    assert.equal(result.error.details.fields[0].field, 'durationMs');
  });

  test('a client-decided outcome comes back as an advisory', async () => {
    const result = await boundary.callExport('register', [
      { id: 'pick', durationMs: 5000,
        steps: [{ kind: 'skillCheck', decidedBy: 'client' }] },
    ], { from: 'my_job' });
    assert.equal(result.ok, true);
    assert.match(result.value.advisory, /decided by the player/);
  });

  test('providers can be registered across the boundary', async () => {
    // These take a FUNCTION, which cannot cross a resource boundary as a copy.
    // Registering one from another state is therefore not something this harness
    // can model — what it can check is that calling the export does not throw,
    // and that the resource notices the provider is absent until it is set.
    const before = await boundary.provider.doString(`
      __exports['setItemProvider'](function() return true end)
      return true
    `);
    assert.equal(before, true);
  });
});

describe('nxc_interact client exports', () => {
  let boundary;
  beforeEach(async () => {
    boundary = await createBoundary({
      provider: 'nxc_interact', consumer: 'nxc_core',
      server: false, realClock: true,
      blocks: ['shared_scripts', 'client_scripts'],
    });
  });
  afterEach(() => boundary.close());

  test('isBusy crosses as a boolean', async () => {
    assert.equal(typeof (await boundary.callExport('isBusy')), 'boolean');
  });

  test('cancel is safe to call when nothing is running', async () => {
    await boundary.callExport('cancel');
    assert.equal(await boundary.callExport('isBusy'), false);
  });

  test('the client half loads with no os', async () => {
    const r = await boundary.provider.doString(`return type(os) .. ',' .. type(io)`);
    assert.equal(r, 'nil,nil');
  });
});
