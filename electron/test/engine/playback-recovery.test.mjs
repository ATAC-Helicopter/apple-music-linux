import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const src = readFileSync(new URL('../../src/engine-playback.js', import.meta.url), 'utf8');
function recovery() {
    const timers = [], requests = [];
    const context = {
        ENGINE: 'https://127.0.0.1:20025', _sessionId: 'first', _currentAssetId: 'track',
        _vlcMode: true, _vlcRetryCount: 0, _durationSec: 200, _vlcPosMs: 70000,
        _vlcSeekOffsetMs: 0, _vlcLoading: false, _allowCDNTransition: false,
        polls: 0, advances: 0, Event, AbortSignal, console,
        stopVLCPoll() {}, startVLCPoll() { context.polls++; },
        _amlNextRef: async () => { context.advances++; },
        setTimeout(fn) { timers.push(fn); },
        fetch: async (url, options) => { requests.push({url, body: JSON.parse(options.body)}); return {ok:true}; },
    };
    vm.createContext(context);
    vm.runInContext(src.slice(src.indexOf('function _vlcRetryFrom('), src.indexOf('function _vlcHandleStateChange(')), context);
    return { context, timers, requests, audio: {dispatchEvent() {}} };
}
test('premature mid-track EOF reloads the source at its last position instead of seeking a stopped player', async () => {
    const r = recovery();
    r.context._vlcHandleEnded(70000, r.audio);
    assert.equal(r.context.advances, 0);
    await r.timers.shift()();
    assert.equal(r.requests[0].url, 'https://127.0.0.1:20025/api/v1/vlc/load');
    assert.equal(r.requests[0].body.startMs, 70000);
    assert.equal(r.context.polls, 1);
});
test('a pending recovery cannot reload the next song after a skip', async () => {
    const r = recovery();
    r.context._vlcHandleEnded(70000, r.audio);
    r.context._sessionId = 'next';
    await r.timers.shift()();
    assert.equal(r.requests.length, 0);
    assert.equal(r.context.polls, 0);
});
test('normal track end advances rather than reloading', () => {
    const r = recovery();
    r.context._vlcHandleEnded(199000, r.audio);
    assert.equal(r.context.advances, 1);
    assert.equal(r.timers.length, 0);
});
test('a failed reload resumes status polling rather than leaving playback controls frozen', async () => {
    const r = recovery();
    r.context.fetch = async () => { throw new Error('temporary offline'); };
    r.context._vlcHandleEnded(70000, r.audio);
    await r.timers.shift()();
    assert.equal(r.context.polls, 1);
});
