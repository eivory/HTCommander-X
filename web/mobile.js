// HTCommander Mobile Web UI
// Uses MCP JSON-RPC API for radio control via polling

const state = {
    mcpUrl: null,
    deviceId: null,
    connected: false,
    radioInfo: null,
    settings: null,
    htStatus: null,
    channels: [],
    battery: -1,
    audioEnabled: false,
    pollTimer: null,
    batteryCounter: 0,
    vfoAChannel: -1,
    vfoBChannel: -1,
    channelsExpanded: true,
    chatExpanded: true,
    chatMessages: [],
    ws: null,
    audioCtx: null,
    micStream: null,
    micProcessor: null,
    micSource: null,
    pttActive: false,
    wsConnected: false,
    nextPlayTime: 0,
    micGain: parseInt(localStorage.getItem('micGain')) || 100
};

// ---- MCP Client ----

async function mcpCall(tool, args) {
    if (!state.mcpUrl) return null;
    try {
        const r = await fetch(state.mcpUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                jsonrpc: '2.0',
                id: Date.now(),
                method: 'tools/call',
                params: { name: tool, arguments: args || {} }
            })
        });
        const j = await r.json();
        if (j.error) { console.error('MCP error:', j.error); return null; }
        const text = j.result && j.result.content && j.result.content[0] && j.result.content[0].text;
        if (!text) return null;
        try { return JSON.parse(text); } catch { return text; }
    } catch (e) {
        console.error('MCP call failed:', e);
        return null;
    }
}

// ---- Initialization ----

async function init() {
    try {
        const configResp = await fetch('/api/config');
        const config = await configResp.json();
        if (!config.mcpEnabled) {
            showDisconnected('MCP server is not enabled. Enable it in Settings → Servers.');
            return;
        }
        state.mcpUrl = window.location.protocol + '//' + window.location.hostname + ':' + config.mcpPort;
    } catch (e) {
        showDisconnected('Cannot reach HTCommander web server.');
        return;
    }

    await pollOnce();
    state.pollTimer = setInterval(pollOnce, 2000);

    setupUI();
    connectAudioWebSocket();
    setupPtt();
}

// ---- Polling ----

async function pollOnce() {
    // Check connected radios
    const radios = await mcpCall('get_connected_radios');
    if (!radios || !Array.isArray(radios) || radios.length === 0) {
        if (state.connected) {
            state.connected = false;
            state.deviceId = null;
            updateConnectionUI();
        }
        showDisconnected('No radio connected. Connect a radio in HTCommander.');
        return;
    }

    const radio = radios.find(r => r.state === 'Connected') || radios[0];
    const newDeviceId = radio.device_id;
    const wasConnected = state.connected;

    if (radio.state !== 'Connected') {
        state.connected = false;
        state.deviceId = null;
        updateConnectionUI();
        showDisconnected('Radio ' + (radio.friendly_name || '') + ': ' + (radio.state || 'Unknown'));
        return;
    }

    state.connected = true;
    state.deviceId = newDeviceId;

    // First connection or device change — fetch full state
    if (!wasConnected || state.deviceId !== newDeviceId) {
        state.radioInfo = await mcpCall('get_radio_info', { device_id: newDeviceId });
        state.channels = await mcpCall('get_channels', { device_id: newDeviceId }) || [];
        state.battery = -1;
        renderChannelList();
    }

    // Poll fast-changing state
    state.settings = await mcpCall('get_radio_settings', { device_id: newDeviceId });
    state.htStatus = await mcpCall('get_ht_status', { device_id: newDeviceId });

    // Battery every ~30 seconds (15 polls × 2s)
    state.batteryCounter++;
    if (state.battery < 0 || state.batteryCounter >= 15) {
        state.batteryCounter = 0;
        const bat = await mcpCall('get_battery', { device_id: newDeviceId });
        if (typeof bat === 'number') state.battery = bat;
        else if (bat && typeof bat === 'object' && bat.battery !== undefined) state.battery = bat.battery;
    }

    hideDisconnected();
    updateConnectionUI();
    updateStatusCard();
    updateVfoDisplay();
    updateControls();
    updateRssi();
}

// ---- UI Updates ----

function showDisconnected(msg) {
    document.getElementById('disconnectedMsg').style.display = 'block';
    document.getElementById('disconnectedMsg').textContent = msg;
    document.getElementById('statusCard').style.display = 'none';
    document.getElementById('vfoContainer').style.display = 'none';
    document.getElementById('rssiBar').style.display = 'none';
    document.getElementById('controlsCard').style.display = 'none';
    document.getElementById('pttCard').style.display = 'none';
    document.getElementById('channelCard').style.display = 'none';
    document.getElementById('chatCard').style.display = 'none';
}

function hideDisconnected() {
    document.getElementById('disconnectedMsg').style.display = 'none';
    document.getElementById('statusCard').style.display = '';
    document.getElementById('vfoContainer').style.display = '';
    document.getElementById('rssiBar').style.display = '';
    document.getElementById('controlsCard').style.display = '';
    document.getElementById('pttCard').style.display = '';
    document.getElementById('channelCard').style.display = '';
    document.getElementById('chatCard').style.display = '';
}

function updateConnectionUI() {
    const dot = document.getElementById('connDot');
    dot.className = 'conn-dot' + (state.connected ? ' connected' : '');
    const model = document.getElementById('radioModel');
    if (state.radioInfo) {
        const pid = state.radioInfo.product_id;
        const models = { 1: 'UV-Pro', 2: 'UV-50Pro', 3: 'GA-5WB', 4: 'VR-N75', 5: 'VR-N76', 6: 'VR-N7500', 7: 'VR-N7600', 8: 'RT-660' };
        model.textContent = models[pid] || ('Radio ' + (pid || ''));
    } else {
        model.textContent = state.connected ? 'Connected' : '--';
    }
}

function updateStatusCard() {
    document.getElementById('batteryVal').textContent = state.battery >= 0 ? state.battery + '%' : '--%';

    const ht = state.htStatus;
    if (ht) {
        document.getElementById('gpsVal').textContent = ht.is_gps_locked ? 'Locked' : 'No Fix';
        document.getElementById('scanVal').textContent = ht.is_scan ? 'On' : 'Off';
        document.getElementById('rssiVal').textContent = ht.rssi || '0';
    }
}

function updateVfoDisplay() {
    const s = state.settings;
    if (!s) return;

    const chA = s.channel_a;
    const chB = s.channel_b;
    state.vfoAChannel = chA;
    state.vfoBChannel = chB;

    // VFO A
    const infoA = state.channels.find(c => c.index === chA);
    document.getElementById('vfoAName').textContent = infoA ? (infoA.name || 'CH ' + chA) : 'CH ' + chA;
    document.getElementById('vfoAFreq').textContent = infoA ? (infoA.rx_freq_mhz || 0).toFixed(4) + ' MHz' : '---.---- MHz';
    document.getElementById('vfoAMode').textContent = infoA ? (infoA.bandwidth === 'wide' ? 'FM Wide' : 'FM Narrow') : '--';

    // VFO B
    const infoB = state.channels.find(c => c.index === chB);
    document.getElementById('vfoBName').textContent = infoB ? (infoB.name || 'CH ' + chB) : 'CH ' + chB;
    document.getElementById('vfoBFreq').textContent = infoB ? (infoB.rx_freq_mhz || 0).toFixed(4) + ' MHz' : '---.---- MHz';
    document.getElementById('vfoBMode').textContent = infoB ? (infoB.bandwidth === 'wide' ? 'FM Wide' : 'FM Narrow') : '--';

    // TX/RX indicator
    const txInd = document.getElementById('txIndicator');
    const ht = state.htStatus;
    if (ht && ht.is_in_tx) { txInd.className = 'tx-indicator tx'; txInd.textContent = 'TX'; }
    else if (ht && ht.is_in_rx) { txInd.className = 'tx-indicator rx'; txInd.textContent = 'RX'; }
    else { txInd.className = 'tx-indicator'; }

    // Highlight channel list
    document.querySelectorAll('.channel-item').forEach(el => {
        const idx = parseInt(el.dataset.index);
        el.classList.toggle('vfo-a-active', idx === chA);
        el.classList.toggle('vfo-b-active', idx === chB && idx !== chA);
    });
}

function updateRssi() {
    const ht = state.htStatus;
    const rssi = ht ? (ht.rssi || 0) : 0;
    const pct = Math.min(100, (rssi / 16) * 100);
    document.getElementById('rssiFill').style.width = pct + '%';
}

function updateControls() {
    const s = state.settings;
    if (!s) return;

    const volSlider = document.getElementById('volumeSlider');
    const sqSlider = document.getElementById('squelchSlider');

    // Only update if not being dragged
    if (document.activeElement !== volSlider) {
        volSlider.value = s.volume_level || 0;
        document.getElementById('volVal').textContent = s.volume_level || 0;
    }
    if (document.activeElement !== sqSlider) {
        sqSlider.value = s.squelch_level || 0;
        document.getElementById('sqVal').textContent = s.squelch_level || 0;
    }
}

// ---- Channel List ----

function renderChannelList() {
    const list = document.getElementById('channelList');
    list.innerHTML = '';
    const channels = state.channels || [];

    channels.forEach(ch => {
        if (!ch || (ch.rx_freq === 0 && !ch.name)) return; // Skip empty
        const el = document.createElement('div');
        el.className = 'channel-item';
        el.dataset.index = ch.index;

        el.innerHTML =
            '<span class="ch-index">' + ch.index + '</span>' +
            '<span class="ch-name">' + (ch.name || '--') + '</span>' +
            '<span class="ch-freq">' + (ch.rx_freq_mhz || 0).toFixed(4) + '</span>';

        // Tap = VFO A
        el.addEventListener('click', () => switchChannel(ch.index, 'A'));

        // Long press = VFO B
        let longPressTimer = null;
        el.addEventListener('touchstart', (e) => {
            longPressTimer = setTimeout(() => {
                longPressTimer = null;
                e.preventDefault();
                switchChannel(ch.index, 'B');
                el.style.background = 'rgba(129,199,132,0.2)';
                setTimeout(() => el.style.background = '', 300);
            }, 500);
        }, { passive: false });
        el.addEventListener('touchend', () => { if (longPressTimer) clearTimeout(longPressTimer); });
        el.addEventListener('touchmove', () => { if (longPressTimer) clearTimeout(longPressTimer); });

        list.appendChild(el);
    });
}

async function switchChannel(index, vfo) {
    if (!state.deviceId) return;
    await mcpCall('set_vfo_channel', { device_id: state.deviceId, vfo: vfo, channel_index: index });
}

// ---- Chat ----

async function sendChat() {
    const input = document.getElementById('chatInput');
    const msg = input.value.trim();
    if (!msg) return;
    input.value = '';

    addChatMessage('You', msg);
    await mcpCall('send_chat_message', { message: msg });
}

function addChatMessage(from, text) {
    const now = new Date();
    const time = now.getHours().toString().padStart(2, '0') + ':' + now.getMinutes().toString().padStart(2, '0');
    state.chatMessages.push({ time, from, text });
    if (state.chatMessages.length > 50) state.chatMessages.shift();

    const container = document.getElementById('chatMessages');
    const el = document.createElement('div');
    el.className = 'chat-msg';
    el.innerHTML = '<span class="time">' + time + '</span><strong>' + from + ':</strong> ' + escapeHtml(text);
    container.appendChild(el);
    container.scrollTop = container.scrollHeight;
}

function escapeHtml(str) {
    const div = document.createElement('div');
    div.textContent = str;
    return div.innerHTML;
}

// ---- UI Setup ----

function setupUI() {
    // Volume slider
    const volSlider = document.getElementById('volumeSlider');
    volSlider.addEventListener('input', () => {
        document.getElementById('volVal').textContent = volSlider.value;
    });
    volSlider.addEventListener('change', () => {
        if (state.deviceId) mcpCall('set_volume', { device_id: state.deviceId, level: parseInt(volSlider.value) });
    });

    // Squelch slider
    const sqSlider = document.getElementById('squelchSlider');
    sqSlider.addEventListener('input', () => {
        document.getElementById('sqVal').textContent = sqSlider.value;
    });
    sqSlider.addEventListener('change', () => {
        if (state.deviceId) mcpCall('set_squelch', { device_id: state.deviceId, level: parseInt(sqSlider.value) });
    });

    // Mic gain slider (client-side only, persisted in localStorage)
    const micSlider = document.getElementById('micGainSlider');
    micSlider.value = state.micGain;
    document.getElementById('micVal').textContent = state.micGain;
    micSlider.addEventListener('input', () => {
        state.micGain = parseInt(micSlider.value);
        document.getElementById('micVal').textContent = micSlider.value;
    });
    micSlider.addEventListener('change', () => {
        localStorage.setItem('micGain', micSlider.value);
    });

    // Audio toggle
    const audioBtn = document.getElementById('audioBtn');
    audioBtn.addEventListener('click', async () => {
        if (!state.deviceId) return;
        state.audioEnabled = !state.audioEnabled;
        await mcpCall('set_audio', { device_id: state.deviceId, enabled: state.audioEnabled });
        audioBtn.classList.toggle('active', state.audioEnabled);
    });

    // Chat send
    document.getElementById('chatSendBtn').addEventListener('click', sendChat);
    document.getElementById('chatInput').addEventListener('keydown', (e) => {
        if (e.key === 'Enter') sendChat();
    });

    // Section toggles
    setupToggle('channelToggle', 'channelSection', 'channelsExpanded');
    setupToggle('chatToggle', 'chatSection', 'chatExpanded');
}

function setupToggle(toggleId, sectionId, stateKey) {
    const toggle = document.getElementById(toggleId);
    const section = document.getElementById(sectionId);
    const arrow = toggle.querySelector('.arrow');

    toggle.addEventListener('click', () => {
        state[stateKey] = !state[stateKey];
        section.style.display = state[stateKey] ? '' : 'none';
        arrow.classList.toggle('open', state[stateKey]);
    });
}

// ---- WebSocket Audio ----

function connectAudioWebSocket() {
    const wsProto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsUrl = wsProto + '//' + window.location.hostname + ':' + window.location.port + '/ws/audio';
    let ws;
    try { ws = new WebSocket(wsUrl); } catch (e) { return; }
    ws.binaryType = 'arraybuffer';

    ws.onopen = () => {
        state.wsConnected = true;
        state.ws = ws;
        updatePttUI();
    };

    ws.onmessage = (event) => {
        if (!(event.data instanceof ArrayBuffer)) return;
        const view = new Uint8Array(event.data);
        if (view.length < 1) return;

        switch (view[0]) {
            case 0x01: // RX audio
                playRxAudio(view.subarray(1));
                break;
            case 0x04: // PTT rejected
                setPttStatus('Another client has PTT');
                break;
            case 0x05: // PTT acquired
                setPttStatus('Transmitting...');
                break;
        }
    };

    ws.onclose = () => {
        state.wsConnected = false;
        state.ws = null;
        updatePttUI();
        setTimeout(connectAudioWebSocket, 3000);
    };

    ws.onerror = () => {}; // onclose will fire after this
}

function playRxAudio(pcmBytes) {
    if (pcmBytes.length < 2) return;

    if (!state.audioCtx) {
        state.audioCtx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 48000 });
    }
    const ctx = state.audioCtx;

    const samples = pcmBytes.length / 2;
    const buffer = ctx.createBuffer(1, samples, 48000);
    const channel = buffer.getChannelData(0);
    const dv = new DataView(pcmBytes.buffer, pcmBytes.byteOffset, pcmBytes.byteLength);
    for (let i = 0; i < samples; i++) {
        channel[i] = dv.getInt16(i * 2, true) / 32768.0;
    }

    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.connect(ctx.destination);

    // Schedule playback with minimal gap to avoid clicks
    const now = ctx.currentTime;
    const startTime = Math.max(now, state.nextPlayTime);
    source.start(startTime);
    state.nextPlayTime = startTime + buffer.duration;
}

function updatePttUI() {
    const btn = document.getElementById('pttBtn');
    if (state.wsConnected && state.connected) {
        btn.classList.remove('disabled');
        setPttStatus('Hold to transmit');
    } else if (state.wsConnected) {
        btn.classList.add('disabled');
        setPttStatus('No radio connected');
    } else {
        btn.classList.add('disabled');
        setPttStatus('Audio not connected');
    }
}

function setPttStatus(msg) {
    document.getElementById('pttStatus').textContent = msg;
}

function setupPtt() {
    const btn = document.getElementById('pttBtn');

    const startPtt = async (e) => {
        e.preventDefault();
        if (!state.wsConnected || !state.connected) return;
        if (state.pttActive) return;

        // Request mic if not already captured
        if (!state.micStream) {
            try {
                state.micStream = await navigator.mediaDevices.getUserMedia({ audio: { sampleRate: 48000, channelCount: 1, echoCancellation: false, noiseSuppression: false } });
                setupMicCapture();
                document.getElementById('httpsNotice').style.display = 'none';
            } catch (err) {
                // Mic access denied or HTTPS required — PTT still works for keying radio, just no voice TX
                document.getElementById('httpsNotice').style.display = '';
            }
        }

        state.pttActive = true;
        btn.classList.add('active');
        state.ws.send(new Uint8Array([0x02]));
    };

    const stopPtt = (e) => {
        if (e) e.preventDefault();
        if (!state.pttActive) return;
        state.pttActive = false;
        btn.classList.remove('active');
        if (state.ws && state.ws.readyState === WebSocket.OPEN) {
            state.ws.send(new Uint8Array([0x03]));
        }
        setPttStatus('Hold to transmit');
    };

    btn.addEventListener('pointerdown', startPtt, { passive: false });
    btn.addEventListener('pointerup', stopPtt, { passive: false });
    btn.addEventListener('pointercancel', stopPtt, { passive: false });
    btn.addEventListener('pointerleave', stopPtt, { passive: false });

    // Prevent context menu on long press (mobile)
    btn.addEventListener('contextmenu', (e) => e.preventDefault());
}

function setupMicCapture() {
    if (!state.audioCtx) {
        state.audioCtx = new (window.AudioContext || window.webkitAudioContext)({ sampleRate: 48000 });
    }
    const ctx = state.audioCtx;
    const source = ctx.createMediaStreamSource(state.micStream);

    // ScriptProcessorNode: 4096 samples, 1 input, 1 output
    const processor = ctx.createScriptProcessor(4096, 1, 1);
    processor.onaudioprocess = (e) => {
        if (!state.pttActive || !state.ws || state.ws.readyState !== WebSocket.OPEN) return;

        const float32 = e.inputBuffer.getChannelData(0);

        // Convert float32 → int16 LE
        const frame = new Uint8Array(1 + float32.length * 2);
        frame[0] = 0x01; // Audio command
        const dv = new DataView(frame.buffer, 1);
        const gain = state.micGain / 100;
        for (let i = 0; i < float32.length; i++) {
            dv.setInt16(i * 2, Math.max(-32768, Math.min(32767, float32[i] * gain * 32768)), true);
        }
        state.ws.send(frame);
    };

    source.connect(processor);
    processor.connect(ctx.destination); // Required for ScriptProcessorNode to fire
    state.micSource = source;
    state.micProcessor = processor;
}

// ---- Start ----

init();
