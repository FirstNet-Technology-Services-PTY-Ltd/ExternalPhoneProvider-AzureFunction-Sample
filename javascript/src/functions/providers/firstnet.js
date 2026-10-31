'use strict';

// FirstNet adapter for the Microsoft Entra "Choose your own telephony provider" (CYOT)
// External Phone Provider Azure Function sample:
// https://github.com/Azure-Samples/ExternalPhoneProvider-AzureFunction-Sample
//
// The Function has already authenticated Microsoft, decrypted the JWE and validated the delivery
// context. This adapter only builds the call to the FirstNet OTP gateway and interprets the reply.
// Gateway contract: docs/GATEWAY-API.md in FirstNet-Technology-Services-PTY-Ltd/entra-sms

const { OUTCOME, ProviderResult, classifyFailure } = require('../providerResult');

const CONTINUE_STATUSES = new Set(['ACCEPTED']);
const FAIL_STATUSES = new Set(['REJECTED', 'FAILED', 'THROTTLED']);
const BLOCK_STATUSES = new Set(['BLOCKED']);

function riskContextFor(delivery) {
    const scenario = delivery.riskContext?.scenario;
    const ipAddress = delivery.riskContext?.ipAddress;
    if (scenario == null && ipAddress == null) return undefined;
    return {
        ...(typeof scenario === 'string' ? { scenario } : {}),
        ...(typeof ipAddress === 'string' ? { ipAddress } : {}),
    };
}

const provider = Object.freeze({
    name: 'firstnet',
    authenticationMode: 'oauth',
    credentialSpec: Object.freeze({ mode: 'oauth' }),

    createRequest({ channel, endpoint, delivery, credential }) {
        const body = {
            channel: channel === 'voice' ? 'voice' : 'sms',
            to: String(delivery.phoneNumber || ''),
            message: delivery.message,
            correlationId: delivery.correlationId || delivery.messageId,
        };
        if (typeof delivery.otp === 'string' && delivery.otp) body.otp = delivery.otp;
        if (typeof delivery.locale === 'string' && delivery.locale.trim()) body.locale = delivery.locale;
        const riskContext = riskContextFor(delivery);
        if (riskContext) body.riskContext = riskContext;

        return {
            url: endpoint,
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                Accept: 'application/json',
                Authorization: ['Bearer', credential.accessToken].join(' '),
            },
            body: JSON.stringify(body),
        };
    },

    interpretResponse(response) {
        const payload = response.json && typeof response.json === 'object' && !Array.isArray(response.json)
            ? response.json : {};
        const status = typeof payload.status === 'string' && payload.status.trim()
            ? payload.status.trim().toUpperCase() : 'UNKNOWN';
        const recognized = CONTINUE_STATUSES.has(status) || FAIL_STATUSES.has(status) || BLOCK_STATUSES.has(status);

        let outcome = OUTCOME.FAIL;
        if (CONTINUE_STATUSES.has(status)) outcome = OUTCOME.CONTINUE;
        if (BLOCK_STATUSES.has(status)) outcome = OUTCOME.BLOCK;
        // Only a 2xx ACCEPTED counts as acceptance.
        if (!response.ok && outcome === OUTCOME.CONTINUE) outcome = OUTCOME.FAIL;

        return new ProviderResult({
            outcome,
            statusRecognized: recognized,
            providerHttpStatus: response.providerHttpStatus,
            providerMessageId: typeof payload.id === 'string' && payload.id ? payload.id : null,
            providerStatusName: status,
            providerStatusDescription: typeof payload.reason === 'string' ? payload.reason : null,
            failureReason: classifyFailure({
                providerHttpStatus: response.providerHttpStatus,
                outcome,
                statusRecognized: recognized,
                validJson: response.validJson,
            }),
        });
    },
});

module.exports = provider;
