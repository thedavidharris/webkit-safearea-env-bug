const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync('WebViewBug/NativeSafeArea.js', 'utf8');
function page(id) {
    const properties = new Map(), messages = [], events = [];
    const window = {
        dispatchEvent: event => events.push(event.type),
        webkit: {messageHandlers: {probe: {postMessage: message => messages.push(message)}}}
    };
    const context = vm.createContext({window, crypto: {randomUUID: () => id}, Event,
        document: {documentElement: {style: {
            getPropertyValue: key => properties.get(key) ?? '',
            setProperty: (key, value) => properties.set(key, value)
        }}}
    });
    vm.runInContext(source, context);
    return {context, window, properties, messages, events};
}
const geometry = top => ({top, right: 0, bottom: 34, left: 0});
function install(page, insets, revision) {
    page.context.installNativeSafeArea(insets, revision);
    return page.window.__nativeSafeAreaBridge;
}
test('installs all edges synchronously before the ready message; accepts decreases and zero', () => {
    const p = page('a');
    p.window.webkit.messageHandlers.probe.postMessage = () => {
        assert.equal(p.properties.get('--native-safe-area-inset-top'), '116px');
        assert.equal(p.properties.size, 4);
    };
    const bridge = install(p, geometry(116), 1);
    assert.equal(bridge.apply(geometry(72), 2, 'a'), true);
    assert.equal(p.properties.get('--native-safe-area-inset-top'), '72px');
    assert.equal(bridge.apply(geometry(0), 3, 'a'), true);
    assert.equal(p.properties.get('--native-safe-area-inset-top'), '0px');
});
test('rejects old documents, old revisions and invalid geometry without partial writes', () => {
    const p = page('new');
    const bridge = install(p, geometry(72), 5);
    assert.equal(bridge.apply(geometry(116), 6, 'old'), false);
    assert.equal(bridge.apply(geometry(116), 4, 'new'), false);
    assert.equal(bridge.apply({...geometry(116), left: -1}, 6, 'new'), false);
    assert.equal(bridge.apply({...geometry(116), left: NaN}, 6, 'new'), false);
    assert.equal(p.properties.get('--native-safe-area-inset-top'), '72px');
});
test('each new document gets values even when geometry and revision are unchanged', () => {
    const old = page('old'), next = page('next');
    install(old, geometry(116), 1);
    const bridge = install(next, geometry(116), 1);
    assert.equal(next.properties.get('--native-safe-area-inset-top'), '116px');
    assert.equal(next.messages[0].documentID, 'next');
    assert.equal(bridge.apply(geometry(116), 1, 'next'), true);
    assert.equal(next.events.length, 1, 'idempotent reconciliation does not dispatch another change');
});
test('HTML scripts parse; priming has cover policy and initial probe precedes body', () => {
    for (const path of ['index.html', 'WebViewBug/priming.html']) {
        const html = fs.readFileSync(path, 'utf8').replace('__PRIMING_ID_JSON__', '"test"');
        assert.match(html, /viewport-fit=cover/);
        for (const match of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) new vm.Script(match[1]);
    }
    const html = fs.readFileSync('index.html', 'utf8');
    assert.ok(html.indexOf('snapshot("initial")') < html.indexOf('<body>'));
    for (const edge of ['top', 'right', 'bottom', 'left']) {
        assert.ok(html.includes(`--inset-${edge}: var(--native-safe-area-inset-${edge}, env(safe-area-inset-${edge}, 0px))`));
    }
});

test('supports HTTP development pages without crypto.randomUUID', () => {
    const p = page('unused');
    delete p.context.crypto;
    const bridge = install(p, geometry(116), 1);
    assert.equal(typeof bridge.documentID, 'string');
    assert.ok(bridge.documentID.length > 0);
    assert.equal(p.properties.get('--native-safe-area-inset-top'), '116px');
});
