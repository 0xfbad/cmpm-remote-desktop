import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {test} from 'node:test';

const sourcePath = process.env.TTYD_XTERM_SOURCE || process.argv[2];
assert.ok(sourcePath, 'Pass the actual patched ttyd xterm source path as the argument or TTYD_XTERM_SOURCE');
const source = readFileSync(sourcePath, 'utf8');
const signature = '    private onSocketOpen() {';
const start = source.indexOf(signature);
const end = source.indexOf('\n    @bind\n    private onSocketClose', start);
assert.ok(start >= 0 && end > start, 'The source must contain the complete onSocketOpen method');
const method = source.slice(start + signature.length, end).trimEnd();
assert.ok(method.endsWith('}'), 'The complete method must end before onSocketClose');
const onSocketOpen = new Function('window', 'document', 'parent', 'console', method.slice(0, -1));

function runtime({frameId = 'terminal-frame', visible = true, foreground = true, outer = 'frame', inner = 'body', opened = false}) {
    const calls = [];
    const outerBody = {};
    const innerBody = {};
    const textarea = {};
    const link = {};
    const field = {};
    const innerOwners = {body: innerBody, textarea, link, 'clipboard-field': field};
    const frame = frameId === null ? null : {
        id: frameId,
        getClientRects: () => visible ? [{}] : [],
    };
    const parentDocument = {
        body: outerBody,
        activeElement: outer === 'frame' ? frame : outer === 'body' ? outerBody : {id: outer},
        hasFocus: () => foreground,
    };
    const document = {
        body: innerBody,
        activeElement: innerOwners[inner],
    };
    const terminal = {
        cols: 111,
        rows: 37,
        textarea,
        element: {contains: element => element === textarea || element === link},
        options: {disableStdin: true},
        reset: () => calls.push(['reset']),
        focus: () => {
            calls.push(['focus']);
            document.activeElement = textarea;
            if (frame) parentDocument.activeElement = frame;
        },
    };
    const client = {
        token: 'counter-token',
        terminal,
        opened,
        reconnectKey: {dispose: () => calls.push(['dispose'])},
        textEncoder: new TextEncoder(),
        socket: {send: bytes => calls.push(['send', JSON.parse(new TextDecoder().decode(bytes))])},
        overlayAddon: {showOverlay: (...args) => calls.push(['overlay', ...args])},
        initListeners: () => calls.push(['listeners']),
    };
    const previousOuter = parentDocument.activeElement;
    const previousInner = document.activeElement;

    onSocketOpen.call(client, {frameElement: frame}, document, {document: parentDocument}, {log() {}});

    return {calls, client, document, parentDocument, previousOuter, previousInner, textarea, frame};
}

const cases = [
    {name: 'standalone terminal keeps existing autofocus', frameId: null, foreground: false, outer: 'report-note', inner: 'link', focus: true},
    {name: 'unrelated frame keeps existing autofocus', frameId: 'another-client', foreground: false, outer: 'report-note', inner: 'link', focus: true},
    {name: 'pending pointer owner can enter a ready terminal', outer: 'frame', inner: 'body', focus: true},
    {name: 'URL restored mode can enter a ready terminal', outer: 'body', inner: 'body', focus: true},
    {name: 'current terminal input retains ownership', outer: 'frame', inner: 'textarea', focus: true},
    {name: 'report keeps ownership', outer: 'report-note', focus: false},
    {name: 'SSH command keeps ownership', outer: 'ssh-command', focus: false},
    {name: 'SSH password keeps ownership', outer: 'ssh-password', focus: false},
    {name: 'toolbar keeps ownership', outer: 'other-control', focus: false},
    {name: 'keyboard mode activation keeps button ownership', outer: 'terminal-mode-button', focus: false},
    {name: 'other client keeps ownership', outer: 'vnc-frame', focus: false},
    {name: 'hidden client cannot autofocus', visible: false, outer: 'body', focus: false},
    {name: 'background workspace cannot autofocus', foreground: false, outer: 'frame', focus: false},
    {name: 'background URL restored workspace cannot autofocus', foreground: false, outer: 'body', focus: false},
    {name: 'frame clipboard field keeps ownership', outer: 'frame', inner: 'clipboard-field', focus: false},
    {name: 'terminal link keeps ownership', outer: 'frame', inner: 'link', focus: false},
];

for (const opened of [false, true]) {
    for (const scenario of cases) {
        test(`${opened ? 'reconnect' : 'first connection'}: ${scenario.name}`, () => {
            const result = runtime({...scenario, opened});
            const expected = [
                ['dispose'],
                ['send', {AuthToken: 'counter-token', columns: 111, rows: 37}],
                ...(opened ? [['reset'], ['overlay', 'Reconnected', 300]] : []),
                ['listeners'],
            ];
            assert.deepEqual(result.calls.filter(([name]) => name !== 'focus'), expected);
            assert.equal(result.client.opened, true);
            assert.equal(result.client.reconnectKey, undefined);
            assert.equal(result.client.terminal.options.disableStdin, !opened);
            assert.equal(result.calls.filter(([name]) => name === 'focus').length, scenario.focus ? 1 : 0);

            if (scenario.focus) {
                assert.equal(result.document.activeElement, result.textarea);
                if (result.frame) assert.equal(result.parentDocument.activeElement, result.frame);
                return;
            }

            assert.equal(result.parentDocument.activeElement, result.previousOuter);
            assert.equal(result.document.activeElement, result.previousInner);
        });
    }
}
