var _res    = 'door_lock_baashastudios';
var pin     = '';
var maxLen  = 6;
var doorIdx = null;

// ── Render PIN dots ───────────────────────────────────────────────────────
function renderDots() {
    var html = '';
    for (var i = 0; i < maxLen; i++) {
        html += (i < pin.length)
            ? '<div class="pdot"></div>'
            : '<div class="pdot-empty"></div>';
    }
    $('#pin-dots-row').html(html);
}

// ── Key tap animation + ripple ────────────────────────────────────────────
function tapKey($btn) {
    $btn.addClass('tap');
    var $r = $('<span class="ripple"></span>');
    $btn.append($r);
    setTimeout(function() { $btn.removeClass('tap'); $r.remove(); }, 380);
}

function pressDigit(d) { if (pin.length < maxLen) { pin += d; renderDots(); } }
function pressDelete()  { pin = pin.slice(0, -1); renderDots(); }
function pressOK() {
    if (!pin || !doorIdx) return;
    $.post('https://' + _res + '/submitPin', JSON.stringify({ doorIndex: doorIdx, pin: pin }));
    pin = '';
    renderDots();
}

// ── Show result message ───────────────────────────────────────────────────
function showMsg(type) {
    var $m = $('#msg-overlay');
    $('#msg-icon').text(type === 'granted' ? '✔' : '✖');
    $('#msg-text').text(type === 'granted' ? 'ACCESS GRANTED' : 'ACCESS DENIED');
    $m.removeClass('hidden granted denied').addClass(type);
    setTimeout(function() {
        $m.addClass('hidden').removeClass('granted denied');
        if (type === 'granted') closePanel();
    }, 900);
}

// ── PIN panel open / close ────────────────────────────────────────────────
function openPanel(data) {
    doorIdx = data.index;
    maxLen  = data.maxLen || 6;
    pin     = '';
    if (data.color) {
        var c = data.color;
        document.documentElement.style.setProperty('--accent', c);
        document.documentElement.style.setProperty('--accent-dim',  hexToRgba(c, 0.35));
        document.documentElement.style.setProperty('--accent-glow', hexToRgba(c, 0.18));
    }
    var locked = data.locked !== false;
    $('#door-name').text(data.name || 'Unknown Access Point');
    $('#status-dot').toggleClass('unlocked', !locked);
    $('#status-label').toggleClass('unlocked', !locked).text(locked ? 'LOCKED' : 'UNLOCKED');
    $('#msg-overlay').addClass('hidden');
    renderDots();
    $('#backdrop').addClass('visible');
    $('#panel').removeClass('hidden');
}
function closePanel() {
    $('#backdrop').removeClass('visible');
    $('#panel').addClass('hidden');
    pin = ''; doorIdx = null;
}

// ── Hex → rgba helper ─────────────────────────────────────────────────────
function hexToRgba(hex, alpha) {
    var r = parseInt(hex.slice(1,3),16);
    var g = parseInt(hex.slice(3,5),16);
    var b = parseInt(hex.slice(5,7),16);
    return 'rgba('+r+','+g+','+b+','+alpha+')';
}

// ══════════════════════════════════════════════════════════════════════════
//  DOOR MANAGER
// ══════════════════════════════════════════════════════════════════════════
var mgrDoors        = [];
var detectDataA     = null;
var detectDataB     = null;
var editingCustomId = null;   // null = add mode, number = edit mode

// ── Open / close manager ──────────────────────────────────────────────────
function openManager(doors) {
    mgrDoors = doors || [];
    renderDoorList();
    showMgrList();
    $('#mgr-overlay').removeClass('hidden');
}
function closeManager() {
    $('#mgr-overlay').addClass('hidden');
    $('#door-select-hud').addClass('hidden');
    detectDataA = null;
    detectDataB = null;
    editingCustomId = null;
    $.post('https://' + _res + '/manager:close', JSON.stringify({}));
}

// ── List view ─────────────────────────────────────────────────────────────
function showMgrList() {
    editingCustomId = null;
    $('#mgr-list-view').removeClass('hidden');
    $('#mgr-form-view').addClass('hidden');
}

// ── Form view (add or edit) ───────────────────────────────────────────────
function showMgrForm(editDoor) {
    editingCustomId = editDoor ? editDoor.customId : null;

    $('#mgr-list-view').addClass('hidden');
    $('#mgr-form-view').removeClass('hidden');

    // Title + save button label
    $('#f-form-title').text(editDoor ? 'EDIT DOOR' : 'ADD NEW DOOR');
    $('#f-save-btn').text(editDoor ? 'SAVE CHANGES' : 'SAVE DOOR');

    // Pre-fill fields
    $('#f-name').val(editDoor ? editDoor.name : '');
    $('#f-locktype').val(editDoor ? (editDoor.lockType || 'pin') : 'pin');
    $('#f-codes').val(
        editDoor && editDoor.codes && editDoor.codes.length
            ? editDoor.codes.join(', ') : ''
    );
    $('#f-jobs').val(
        editDoor && editDoor.authorizedJobs && editDoor.authorizedJobs.length
            ? editDoor.authorizedJobs.map(function(j){ return j.name + ':' + j.grade; }).join(', ')
            : ''
    );
    $('#f-items').val(
        editDoor && editDoor.authorizedItems && editDoor.authorizedItems.length
            ? editDoor.authorizedItems.join(', ') : ''
    );
    $('#f-dist').val(editDoor ? (editDoor.distance || 1.5) : 1.5);
    $('#f-double').prop('checked', false);

    // Reset door select state
    detectDataA = null;
    detectDataB = null;
    $('#door-select-results').addClass('hidden');
    $('#door-select-btn').prop('disabled', false).text('⊕  POINT & SELECT BOTH DOORS');

    // Double door option only in add mode
    $('#fgrp-double-opt').toggle(!editingCustomId);
    $('#fgrp-doorb').addClass('hidden');

    updateFormFields();

    // Detect setup
    if (editDoor) {
        // Pre-fill from saved position
        detectDataA = {
            detected: !!(editDoor.objHash && editDoor.objHash !== 0),
            x: editDoor.x, y: editDoor.y, z: editDoor.z,
            heading: editDoor.heading, hash: editDoor.objHash || 0
        };
        setDetectStatus('a', detectDataA);
    } else {
        setDetectStatus('a', null);
        doDetect('a');
    }
}

// ── Show/hide fields based on lock type ───────────────────────────────────
function updateFormFields() {
    var lt        = $('#f-locktype').val();
    var needsPin  = lt === 'pin'  || lt === 'pin_or_job' || lt === 'any';
    var needsJob  = lt === 'job'  || lt === 'pin_or_job' || lt === 'any';
    var needsItem = lt === 'item' || lt === 'any';

    $('#fgrp-codes').toggleClass('hidden', !needsPin);
    $('#fgrp-jobs').toggleClass('hidden', !needsJob);
    $('#fgrp-items').toggleClass('hidden', !needsItem);

    var isDouble = $('#f-double').is(':checked') && !editingCustomId;

    // In double door mode: hide single-door detect bar, show pointer-select UI
    $('#detect-bar').toggleClass('hidden', isDouble);
    $('#detect-coords').toggleClass('hidden', isDouble);
    $('#fgrp-doorb').toggleClass('hidden', !isDouble);
}

// ── Detect status display (single door / door A only) ─────────────────────
function setDetectStatus(slot, data) {
    if (slot !== 'a') return;
    detectDataA = data || null;
    if (!data) {
        $('#detect-icon').text('○').removeClass('ok');
        $('#detect-text').text('SCANNING FOR NEARBY PROP...').removeClass('ok');
        $('#detect-coords').text('—');
    } else if (data.detected) {
        $('#detect-icon').text('●').addClass('ok');
        $('#detect-text').text('PROP DETECTED').addClass('ok');
        $('#detect-coords').text('X: '+data.x+'   Y: '+data.y+'   Z: '+data.z+'   H: '+data.heading);
    } else {
        $('#detect-icon').text('○').removeClass('ok');
        $('#detect-text').text('NO PROP FOUND — USING PLAYER POSITION').removeClass('ok');
        $('#detect-coords').text('X: '+data.x+'   Y: '+data.y+'   Z: '+data.z);
    }
}

function doDetect(slot) {
    setDetectStatus(slot || 'a', null);
    $.post('https://' + _res + '/manager:detectDoor', JSON.stringify({ slot: slot || 'a' }));
}

// ── Door list render ──────────────────────────────────────────────────────
function renderDoorList() {
    var list = mgrDoors;
    if (!list || list.length === 0) {
        $('#mgr-empty').removeClass('hidden');
        $('#mgr-door-list').html('');
        return;
    }
    $('#mgr-empty').addClass('hidden');
    var html = '';
    for (var i = 0; i < list.length; i++) {
        var d = list[i];
        var stateClass = d.locked ? 'locked' : 'unlocked';
        var stateText  = d.locked ? 'LOCKED' : 'OPEN';
        var actionHtml = d.isCustom
            ? '<button class="mgr-row-edit" data-idx="' + d.index + '">EDIT</button>' +
              '<button class="mgr-row-del"  data-cid="' + d.customId + '">DEL</button>'
            : '<span class="mgr-row-static">CONFIG</span>';
        html +=
            '<div class="mgr-row">' +
            '<span class="mgr-row-idx">#' + d.index + '</span>' +
            '<span class="mgr-row-name">' + d.name + '</span>' +
            '<span class="mgr-row-type">' + d.lockType.toUpperCase() + '</span>' +
            '<span class="mgr-row-state ' + stateClass + '">' + stateText + '</span>' +
            actionHtml +
            '</div>';
    }
    $('#mgr-door-list').html(html);
}

// ── Parse helpers ─────────────────────────────────────────────────────────
function parseCSV(str) {
    if (!str || !str.trim()) return [];
    return str.split(',').map(function(s){ return s.trim(); }).filter(Boolean);
}
function parseJobs(str) {
    if (!str || !str.trim()) return [];
    return parseCSV(str).map(function(s) {
        var parts = s.split(':');
        return { name: parts[0].trim(), grade: parseInt(parts[1]) || 0 };
    }).filter(function(j){ return j.name.length > 0; });
}

// ── Save (add or edit) ────────────────────────────────────────────────────
function saveDoor() {
    var name = $('#f-name').val().trim();
    if (!name) { $('#f-name').focus(); return; }

    var lockType        = $('#f-locktype').val();
    var codes           = parseCSV($('#f-codes').val());
    var authorizedJobs  = parseJobs($('#f-jobs').val());
    var authorizedItems = parseCSV($('#f-items').val());
    var distance        = parseFloat($('#f-dist').val()) || 1.5;

    if (editingCustomId) {
        $.post('https://' + _res + '/manager:editDoor', JSON.stringify({
            customId:        editingCustomId,
            name:            name,
            lockType:        lockType,
            codes:           codes,
            authorizedJobs:  authorizedJobs,
            authorizedItems: authorizedItems,
            distance:        distance,
        }));
        showMgrList();
        return;
    }

    // Add mode
    var isDouble = $('#f-double').is(':checked');

    if (isDouble) {
        // Double door mode requires pointer selection
        if (!detectDataA || !detectDataB) {
            var $sb = $('#door-select-btn');
            var orig = $sb.text();
            $sb.text('SELECT DOORS FIRST!').css({ 'border-color': 'rgba(248,113,113,0.7)', 'color': 'var(--red)' });
            setTimeout(function() { $sb.text(orig).css({ 'border-color': '', 'color': '' }); }, 2000);
            return;
        }
    } else {
        // Single door mode
        if (!detectDataA) { doDetect('a'); return; }
    }

    var payload = {
        name:            name,
        objHash:         detectDataA.hash || 0,
        x:               detectDataA.x,
        y:               detectDataA.y,
        z:               detectDataA.z,
        heading:         detectDataA.heading,
        distance:        distance,
        lockType:        lockType,
        codes:           codes,
        authorizedJobs:  authorizedJobs,
        authorizedItems: authorizedItems,
    };
    if (isDouble && detectDataB) {
        payload.doorB = {
            hash:    detectDataB.hash || 0,
            x:       detectDataB.x,
            y:       detectDataB.y,
            z:       detectDataB.z,
            heading: detectDataB.heading,
        };
    }
    $.post('https://' + _res + '/manager:saveDoor', JSON.stringify(payload));
    showMgrList();
}

function deleteDoor(customId) {
    $.post('https://' + _res + '/manager:deleteDoor', JSON.stringify({ customId: customId }));
}

// ── Wire everything up ────────────────────────────────────────────────────
$(document).ready(function() {

    // PIN numpad
    $(document).on('click', '.key[data-n]', function() {
        var n = $(this).data('n');
        tapKey($(this));
        if      (n === 'del') { pressDelete(); }
        else if (n === 'ok')  { pressOK();     }
        else                  { pressDigit(String(n)); }
    });
    $('#btn-cancel').on('click', function() {
        $.post('https://' + _res + '/close', JSON.stringify({}));
        closePanel();
    });
    $(document).on('keydown', function(e) {
        if ($('#panel').hasClass('hidden')) return;
        if (e.key >= '0' && e.key <= '9') { pressDigit(e.key); tapKey($('.key[data-n="'+e.key+'"]')); }
        else if (e.key === 'Backspace')    { pressDelete(); tapKey($('.key-del')); }
        else if (e.key === 'Enter')        { pressOK();     tapKey($('.key-ok')); }
        else if (e.key === 'Escape')       { $.post('https://'+_res+'/close', JSON.stringify({})); closePanel(); }
        e.preventDefault();
    });

    // Manager: open/close
    $('#mgr-close-btn').on('click', closeManager);
    $('#mgr-add-btn').on('click', function(){ showMgrForm(null); });

    // Manager: form controls
    $('#detect-btn').on('click', function(){ doDetect('a'); });
    $('#f-cancel-btn').on('click', showMgrList);
    $('#f-save-btn').on('click', saveDoor);
    $('#f-locktype').on('change', updateFormFields);
    $('#f-double').on('change', updateFormFields);

    // Double door: pointer select button
    $('#door-select-btn').on('click', function() {
        $(this).prop('disabled', true);
        detectDataA = null;
        detectDataB = null;
        $('#door-select-results').addClass('hidden');
        $.post('https://' + _res + '/manager:startDoorSelect', JSON.stringify({}));
    });

    // Manager: edit button
    $(document).on('click', '.mgr-row-edit', function() {
        var idx = parseInt($(this).data('idx'));
        var door = null;
        for (var i = 0; i < mgrDoors.length; i++) {
            if (mgrDoors[i].index === idx) { door = mgrDoors[i]; break; }
        }
        if (door) showMgrForm(door);
    });

    // Manager: delete (two-tap confirm)
    $(document).on('click', '.mgr-row-del', function(e) {
        e.stopPropagation();
        var $btn = $(this);
        if ($btn.hasClass('confirming')) {
            deleteDoor($btn.data('cid'));
            $btn.removeClass('confirming').text('DEL');
        } else {
            $('.mgr-row-del').removeClass('confirming').text('DEL');
            $btn.addClass('confirming').text('CONFIRM?');
        }
    });
    $(document).on('click', function(e) {
        if (!$(e.target).hasClass('mgr-row-del')) {
            $('.mgr-row-del').removeClass('confirming').text('DEL');
        }
    });

    // FiveM message handler
    window.addEventListener('message', function(ev) {
        var d = ev.data;
        if (!d || !d.action) return;

        // PIN panel
        if      (d.action === 'open')    { openPanel(d.door); }
        else if (d.action === 'close')   { closePanel(); }
        else if (d.action === 'granted') { showMsg('granted'); }
        else if (d.action === 'denied')  { showMsg('denied'); }

        // Manager
        else if (d.action === 'manager:open') {
            openManager(d.doors);
        }
        else if (d.action === 'manager:update') {
            mgrDoors = d.doors || [];
            renderDoorList();
        }
        else if (d.action === 'manager:close') {
            $('#mgr-overlay').addClass('hidden');
        }
        else if (d.action === 'manager:detectResult') {
            // Only used for single door A scan
            setDetectStatus(d.slot || 'a', d.data);
        }

        // ── Double door pointer selection ────────────────────────────────
        else if (d.action === 'manager:selectPhase') {
            var txt  = d.phase === 1 ? 'AIM AT DOOR 1 — PRESS [E]' : 'AIM AT DOOR 2 — PRESS [E]';
            var step = 'STEP ' + d.phase + ' OF 2';
            $('#dsh-instruction').text(txt);
            $('#dsh-step').text(step);
            $('#door-select-hud').removeClass('hidden');
        }
        else if (d.action === 'manager:selectResult') {
            $('#door-select-hud').addClass('hidden');
            detectDataA = d.doorA;
            detectDataB = d.doorB;
            var a = d.doorA, b = d.doorB;
            var aOk = a && a.detected;
            var bOk = b && b.detected;
            $('#dsr-a-status')
                .text(aOk ? '● PROP DETECTED' : '○ POSITION ONLY')
                .toggleClass('ok', !!aOk);
            $('#dsr-a-coords').text(a ? 'X:'+a.x+'  Y:'+a.y+'  Z:'+a.z : '');
            $('#dsr-b-status')
                .text(bOk ? '● PROP DETECTED' : '○ POSITION ONLY')
                .toggleClass('ok', !!bOk);
            $('#dsr-b-coords').text(b ? 'X:'+b.x+'  Y:'+b.y+'  Z:'+b.z : '');
            $('#door-select-results').removeClass('hidden');
            $('#door-select-btn').prop('disabled', false).text('⊕  RESELECT BOTH DOORS');
        }
        else if (d.action === 'manager:selectCancel') {
            $('#door-select-hud').addClass('hidden');
            $('#door-select-btn').prop('disabled', false).text('⊕  POINT & SELECT BOTH DOORS');
        }
    });

});
