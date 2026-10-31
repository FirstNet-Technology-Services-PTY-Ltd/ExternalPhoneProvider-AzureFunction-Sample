'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { selectProvider } = require('../src/functions/providers');
const { OUTCOME } = require('../src/functions/providerResult');

const firstnet = selectProvider('firstnet');
const delivery = {
    phoneNumber: '+27821234567',
    message: 'Your verification code is 012345.',
    otp: '012345',
    locale: 'en-ZA',
    correlationId: 'corr-1',
    messageId: 'msg-1',
    riskContext: { scenario: 'signIn', ipAddress: '203.0.113.10' },
};
const response = (json, status = 200) => ({
    ok: status >= 200 && status < 300, providerHttpStatus: status, json, validJson: json !== undefined,
});

test('FirstNet is registered with OAuth', () => {
    assert.equal(firstnet.name, 'firstnet');
    assert.equal(firstnet.authenticationMode, 'oauth');
    assert.deepEqual(firstnet.credentialSpec, { mode: 'oauth' });
});

test('FirstNet builds the gateway request for both channels', () => {
    for (const channel of ['sms', 'voice']) {
        const request = firstnet.createRequest({
            channel, endpoint: 'https://entra-otp.firstnet.test/v1/entra/otp', delivery,
            credential: { mode: 'oauth', accessToken: 'tok' },
        });
        assert.equal(request.method, 'POST');
        assert.equal(request.url, 'https://entra-otp.firstnet.test/v1/entra/otp');
        assert.equal(request.headers.Authorization, 'Bearer tok');
        assert.deepEqual(JSON.parse(request.body), {
            channel, to: '+27821234567', message: 'Your verification code is 012345.', correlationId: 'corr-1',
            otp: '012345', locale: 'en-ZA', riskContext: { scenario: 'signIn', ipAddress: '203.0.113.10' },
        });
    }
});

test('FirstNet omits optional fields that Entra did not supply', () => {
    const request = firstnet.createRequest({
        channel: 'sms', endpoint: 'https://x.test', credential: { accessToken: 't' },
        delivery: { phoneNumber: '+27821234567', message: 'code 1', messageId: 'm-1' },
    });
    assert.deepEqual(JSON.parse(request.body), { channel: 'sms', to: '+27821234567', message: 'code 1', correlationId: 'm-1' });
});

test('FirstNet maps gateway responses to Continue / Block / Fail', () => {
    const cases = [
        [response({ status: 'ACCEPTED', id: 'fn_1' }), OUTCOME.CONTINUE, 200, null],
        [response({ status: 'accepted', id: 'fn_1' }), OUTCOME.CONTINUE, 200, null],
        [response({ status: 'BLOCKED', reason: 'destination_velocity' }, 422), OUTCOME.BLOCK, 422, 'provider_http_error'],
        [response({ status: 'REJECTED' }, 400), OUTCOME.FAIL, 400, 'provider_http_error'],
        [response({ status: 'THROTTLED' }, 429), OUTCOME.FAIL, 429, 'provider_http_error'],
        [response({ status: 'FAILED' }, 502), OUTCOME.FAIL, 502, 'provider_http_error'],
        [response({ status: 'ACCEPTED' }, 500), OUTCOME.FAIL, 502, 'provider_http_error'],
        [response({ status: 'WHAT' }), OUTCOME.FAIL, 502, 'unrecognized_provider_status'],
        [response(undefined), OUTCOME.FAIL, 502, 'invalid_provider_json'],
    ];
    for (const [input, outcome, httpStatus, failureReason] of cases) {
        const result = firstnet.interpretResponse(input);
        assert.equal(result.outcome, outcome);
        assert.equal(result.httpStatus, httpStatus);
        assert.equal(result.failureReason, failureReason);
    }
    assert.equal(firstnet.interpretResponse(response({ status: 'ACCEPTED', id: 'fn_9' })).providerMessageId, 'fn_9');
});
