(function () {
  'use strict';

  const sections = [
    ['general', 'General', 'Updates, shortcuts and appearance'],
    ['capture', 'Capture', 'Recorded context, capture rate and compression'],
    ['storage', 'Storage', 'Usage, locations and retention'],
    ['export', 'Export & Data', 'Export availability'],
    ['privacy', 'Privacy', 'Excluded apps, redaction and permissions'],
    ['power', 'Power', 'OCR and background processing'],
    ['audio', 'Audio', 'Microphone, voice markers and models'],
    ['tags', 'Tags', 'Organise saved moments'],
    ['advanced', 'Advanced', 'MCP access, cache and developer options']
  ];
  const defaults = () => ({
    values: { automaticUpdates: true, launchAtLogin: true, dockIcon: true, appearance: 'Dark', captureContext: true,
      directText: false, display: 'All displays', captureRate: 'Every 2 seconds', compression: 'Balanced', pauseReminder: true,
      retention: 'Keep forever', ocrEnabled: true, processingSpeed: 'Balanced', ocrPriority: 35, mic: true,
      micInput: 'Studio Display microphone', systemAudio: false, voiceEnabled: true, markerSound: true,
      pushToDictate: true, listener: false, timelineAutoplay: false, screenshotCache: true, shortcuts: true,
      redactPasswords: true, deletePreview: 'Last 5 minutes', theme: 'Dark', voiceAssets: true },
    query: '', rules: [{ id: 1, phrase: 'Purple banana', title: 'Remember this context', meaning: 'Mark this moment and retain the context that follows.', aliases: '', enabled: true }],
    nextRule: 2, editingRule: null, tags: [{ id: 1, name: 'Follow up', colour: '#398DFF' }, { id: 2, name: 'Decision', colour: '#35C5AB' }, { id: 3, name: 'Remember', colour: '#AE8EFF' }],
    nextTag: 4, excluded: ['Password manager'], redaction: 'Password manager\nPrivate window',
    models: { whisper: true, embedding: false }, modelStage: '', companion: false, clients: [], nextClient: 1,
    retainedDays: 'Before 1 October 2026', reviewStage: '', reviewPage: 1, storageUpdated: '11:42 am',
    cacheCleared: false, baseline: false, filterApps: { Ghostty: true, Safari: true, Notes: true, Finder: true }
  });
  let demo = defaults();
  let context;
  const esc = value => String(value == null ? '' : value).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
  const button = (label, action, kind = '', attrs = '') => '<button type="button" class="button ' + kind + '" data-action="' + esc(action) + '" ' + attrs + '>' + label + '</button>';
  const group = (title, body, id = '') => '<section class="settings-group panel"' + (id ? ' id="' + id + '"' : '') + '><h3>' + title + '</h3>' + body + '</section>';
  const row = (title, help, control) => '<div class="settings-row"><div class="settings-label"><strong>' + title + '</strong>' + (help ? '<p class="muted">' + help + '</p>' : '') + '</div><div class="settings-control">' + control + '</div></div>';
  const toggle = (key, label) => '<button type="button" class="settings-toggle" aria-label="' + esc(label) + '" aria-pressed="' + !!demo.values[key] + '" data-action="settings:toggle:' + key + '"><span></span><span class="settings-sr">' + (demo.values[key] ? 'On' : 'Off') + '</span></button>';
  const select = (key, label, options) => '<select aria-label="' + esc(label) + '" data-settings-value="' + key + '">' + options.map(item => '<option' + (demo.values[key] === item ? ' selected' : '') + '>' + esc(item) + '</option>').join('') + '</select>';
  const field = (id, label, value, placeholder = '') => '<label class="settings-field" for="' + id + '">' + label + '<input id="' + id + '" value="' + esc(value) + '" placeholder="' + esc(placeholder) + '" autocomplete="off"></label>';
  const notice = text => '<div class="settings-notice">' + text + '</div>';
  function show(title, body, buttons) { context.dialog(title, body, buttons || [{ label: 'Done', action: 'settings:close', primary: true }]); }
  function finish(message) { context.closeDialog(); context.render(); if (message) context.toast(message); }
  function val(id) { const el = document.getElementById(id); return el ? el.value.trim() : ''; }
  function confirm(title, body, action, label) {
    show(title, '<p>' + body + '</p>' + notice('Prototype only. This action affects sample data in this browser tab.'), [
      { label: 'Cancel', action: 'settings:close' }, { label: label || 'Confirm', action, primary: true }
    ]);
  }
  function general() {
    return group('Updates', row('Keep Retrace up to date', 'Check for updates automatically.', toggle('automaticUpdates', 'Automatic updates')) + row('Installed version', 'Interface reference: local trial 2610.22.5. This is a browser prototype.', button('Check for updates', 'settings:updates'))) +
      group('Keyboard shortcuts', row('Global shortcuts', 'Open Timeline, search your history and start dictation.', toggle('shortcuts', 'Global shortcuts')) +
        '<div class="settings-shortcuts"><span>Open Timeline</span><kbd>⌥ R</kbd><span>Search history</span><kbd>⌥ Space</kbd><span>Push to dictate</span><kbd>Hold fn</kbd></div>' + button('Edit shortcuts', 'settings:shortcuts', 'quiet')) +
      group('Startup', row('Launch at login', 'Start Retrace when you sign in.', toggle('launchAtLogin', 'Launch at login')) + row('Show Dock icon', 'Keep Retrace in the Dock.', toggle('dockIcon', 'Show Dock icon'))) +
      group('Appearance', row('Colour scheme', 'The preview keeps its dark palette; this selection demonstrates the native setting.', select('appearance', 'Colour scheme', ['Dark', 'Light', 'System']))) +
      group('About & support', '<p>Retrace is your private, searchable memory of screen and audio activity.</p><div class="settings-inline">' + button('About Retrace', 'settings:about') + '<a class="button" href="docs/full-spec.html">Full specification</a><a class="button" href="docs/issues-journal.html">Issues journal</a></div>');
  }
  function capture() {
    return group('Recorded context', row('Record application and window context', 'Keep the application name and window title with each captured moment.', toggle('captureContext', 'Record application and window context')) + row('Read visible text directly', 'Optional visible accessibility text accompanies OCR when available.', toggle('directText', 'Read visible text directly')) + row('Displays', 'Preserve the identity of each recorded display.', select('display', 'Displays', ['All displays', 'Studio Display', 'Built-in display']))) +
      group('Capture rate', row('Capture interval', 'Meaningful changes create new moments. Unchanged screens can share the same image.', select('captureRate', 'Capture interval', ['Every 2 seconds', 'Every 5 seconds', 'Every 10 seconds']))) +
      group('Compression', row('Screen quality', 'Original text quality and exact navigation must pass validation before new compression is promoted.', select('compression', 'Screen quality', ['High quality', 'Balanced', 'Smaller files'])) + notice('Higher-quality OCR and image reuse are represented in this prototype. Selecting a setting does not re-encode any media.')) +
      group('Pause reminder', row('Remind me when recording is paused', 'A gentle reminder helps avoid unintended gaps.', toggle('pauseReminder', 'Pause reminder')));
  }
  function storage() {
    const parts = [['Audio', '71.5 GB', 43, 'audio'], ['Screen video', '40.8 GB', 25, 'video'], ['Database', '47.0 GB', 28, 'database'], ['Models & other', '6.3 GB', 4, 'other']];
    const chart = '<div class="settings-storage-total"><strong>165.6 <small>GB</small></strong><span class="muted">Sample library · 98 GB available</span></div><div class="settings-storage-bar" aria-label="Sample storage allocation">' + parts.map(p => '<span class="storage-' + p[3] + '" style="width:' + p[2] + '%"></span>').join('') + '</div><div class="settings-storage-legend">' + parts.map(p => '<div><i class="storage-' + p[3] + '"></i><span>' + p[0] + '</span><strong>' + p[1] + '</strong></div>').join('') + '</div>';
    let review = '<p class="muted">Review older screen history before making any retention decision.</p><label class="settings-field">Before date<input type="date" id="settings-review-date" value="2026-10-01"></label>' + button('Preview older history', 'settings:review-preview');
    if (demo.reviewStage === 'preview') review = notice('Sample preview: 14 days of screen history, 3.2 GB logical size. Actual disk recovery can differ. Audio is outside this selection.') + '<p>Page ' + demo.reviewPage + ' · ' + esc(demo.retainedDays) + '</p><div class="settings-inline">' + button('Cancel review', 'settings:review-cancel') + button('Review deletion', 'settings:review-confirm', 'danger') + '</div>';
    if (demo.reviewStage === 'done') review = notice('Sample review completed. No files were deleted.') + button('Review next page', 'settings:review-next');
    return group('Storage usage', chart + row('Last measured ' + demo.storageUpdated, 'Usage is refreshed periodically, rather than scanning continuously.', button('Refresh usage', 'settings:refresh-storage'))) +
      group('Database locations', row('Retrace library', 'Library / Application Support / Retrace', button('Choose location', 'settings:location'))) +
      group('Rewind data', row('Imported history', 'Existing imported moments remain available in Timeline.', button('Choose Rewind folder', 'settings:rewind'))) +
      group('Retention policy', row('Keep recorded history', 'Automatic deletion needs an explicit retention choice.', select('retention', 'Retention policy', ['Keep forever', '90 days', '180 days', '365 days'])) + button('Review retention change', 'settings:retention', 'quiet')) +
      group('Review older screen history', review, 'settings-retention');
  }
  function privacy() {
    return group('Excluded applications', '<p class="muted">Excluded applications do not contribute new screen captures.</p><div class="settings-list">' + demo.excluded.map((name, i) => '<div class="settings-row"><span>' + esc(name) + '</span>' + button('Remove', 'settings:exclude-remove:' + i, 'quiet', 'aria-label="Remove ' + esc(name) + ' exclusion"') + '</div>').join('') + '</div>' + button('Add application', 'settings:exclude-add')) +
      group('Window redaction', row('Hide password fields', 'Keep sensitive fields out of new captures.', toggle('redactPasswords', 'Hide password fields')) + '<label class="settings-field" for="settings-redaction">Window names to redact<textarea id="settings-redaction" rows="3">' + esc(demo.redaction) + '</textarea></label><div class="settings-inline">' + button('Reload rules', 'settings:redaction-reload') + button('Apply rules', 'settings:redaction-save', 'primary') + '</div>') +
      group('Quick delete', '<p class="muted">Review the time range before deleting recent history.</p><div class="settings-inline">' + ['Last 5 minutes', 'Last hour', 'Last 24 hours'].map((label, i) => button(label, 'settings:quick-delete:' + i, 'danger')).join('') + '</div>') +
      group('Permissions', ['Screen recording', 'Microphone', 'Accessibility'].map(name => row(name, 'Sample permission status. No device access is requested.', '<span class="settings-status">Allowed</span>')).join('') + button('Review permissions', 'settings:permissions', 'quiet'));
  }
  function power() {
    return group('OCR processing', row('Prepare screen text', 'Recording continues if text preparation is paused.', toggle('ocrEnabled', 'Prepare screen text')) + notice(demo.values.ocrEnabled ? 'Fresh screen text has priority. Historical work waits for spare capacity.' : 'OCR is paused in the demo. New screenshots remain visible; their text is not ready.')) +
      group('Application filter', row('Apps to process', Object.keys(demo.filterApps).filter(key => demo.filterApps[key]).length + ' sample applications included.', button('Choose applications', 'settings:power-apps'))) +
      group('Processing speed', row('Automatic processing', 'Balance foreground responsiveness with background text preparation.', select('processingSpeed', 'Processing speed', ['Conservative', 'Balanced', 'Faster catch-up'])) + '<label class="settings-field" for="settings-priority">OCR priority <output id="settings-priority-value">' + demo.values.ocrPriority + '%</output><input id="settings-priority" type="range" min="0" max="100" value="' + demo.values.ocrPriority + '" data-settings-value="ocrPriority"></label>') +
      group('Energy & responsiveness', '<p>Recording and explicit searches take priority. Expensive background work can wait for a quiet moment.</p><ul class="settings-tips"><li>Input inactivity is a scheduling hint.</li><li>Process now temporarily admits pending work.</li><li>The CPU budget is admission control, not a hard CPU cap.</li></ul>' + button('Open System Monitor', 'settings:monitor', 'primary'));
  }
  function audio() {
    const rules = demo.rules.map(rule => '<div class="settings-rule"><div><strong>“' + esc(rule.phrase) + '”</strong><p>' + esc(rule.title) + '</p><span class="muted">' + esc(rule.meaning) + '</span></div><div class="settings-inline">' + button(rule.enabled ? 'Enabled' : 'Disabled', 'settings:rule-toggle:' + rule.id, rule.enabled ? 'settings-enabled' : '') + button('Edit', 'settings:rule-edit:' + rule.id, 'quiet', 'aria-label="Edit ' + esc(rule.phrase) + ' rule"') + '</div></div>').join('');
    return group('Microphone session', row('Record microphone', 'Saved audio remains separate from text preparation.', toggle('mic', 'Record microphone')) + row('Input device', 'The selected input is shown explicitly.', select('micInput', 'Input device', ['Studio Display microphone', 'MacBook Pro microphone', 'System default'])) + row('Record system audio', 'Call and video audio cannot trigger your spoken marker rules.', toggle('systemAudio', 'Record system audio')) + row('Push to dictate', 'Hold the dictation shortcut to capture a deliberate phrase.', toggle('pushToDictate', 'Push to dictate'))) +
      group('Voice marker rules', row('Listen for marker phrases', 'Uses microphone speech. Screen text and system audio do not trigger markers.', toggle('voiceEnabled', 'Listen for marker phrases')) + rules + '<div class="settings-inline">' + button('Add phrase', 'settings:rule-new', 'primary') + button('Try “Purple banana”', 'settings:rule-demo') + '</div>' + row('Play confirmation sound', 'A short acknowledgement after a marker is recognised.', toggle('markerSound', 'Marker confirmation sound')) + row('Speech assets', demo.values.voiceAssets ? 'Sample assets ready. No model was downloaded.' : 'On-device recognition assets are represented in the demo.', button(demo.values.voiceAssets ? 'Ready' : 'Prepare assets', 'settings:voice-assets')), 'settings-voice-rules') +
      group('Private companion', row(demo.companion ? 'Companion configured' : 'Companion not configured', 'Optional private service. This prototype never contacts an endpoint.', button(demo.companion ? 'Manage connection' : 'Configure', 'settings:companion'))) +
      group('Local models', row('Whisper transcription', demo.models.whisper ? 'Sample model ready · 1.5 GB' : 'No sample model selected.', button(demo.models.whisper ? 'Manage' : 'Download', 'settings:model:whisper')) + row('MiniLM embeddings', demo.models.embedding ? 'Sample model ready · 90 MB' : 'Optional local semantic indexing model.', button(demo.models.embedding ? 'Manage' : 'Download', 'settings:model:embedding'))) +
      group('Saved audio', row('Transcribe saved audio', 'Explicitly process pending recordings, including while recording is paused.', button('Transcribe saved audio', 'settings:transcribe', 'primary')) + row('Audio history', 'Browse saved recordings and prepared transcripts together.', button('Open Audio Recordings', 'settings:audio-history')));
  }
  function tags() {
    return group('Your tags', '<p class="muted">Use tags to find related moments in Timeline.</p>' + demo.tags.map(tag => '<div class="settings-row"><span class="settings-tag"><i style="background:' + tag.colour + '"></i>' + esc(tag.name) + '</span><div class="settings-inline">' + button('Edit', 'settings:tag-edit:' + tag.id, 'quiet', 'aria-label="Edit ' + esc(tag.name) + ' tag"') + button('Delete', 'settings:tag-delete:' + tag.id, 'quiet', 'aria-label="Delete ' + esc(tag.name) + ' tag"') + '</div></div>').join('') + button('Create tag', 'settings:tag-new', 'primary'));
  }
  function advanced() {
    return group('Local MCP access', row('Enable local listener', 'App-owned, permissioned access for external agents. No real server runs in this prototype.', toggle('listener', 'Enable local MCP listener')) + '<p class="muted">Clients receive explicit grants and can be revoked at any time. Read-only access is the starting point.</p>' + (demo.clients.length ? demo.clients.map(client => '<div class="settings-row"><div><strong>' + esc(client.name) + '</strong><p class="muted">' + esc(client.grant) + ' · Expires ' + esc(client.expiry) + '</p></div>' + button('Revoke', 'settings:revoke:' + client.id, 'danger') + '</div>').join('') : notice('No authorised clients in the demo.')) + button('Add client', 'settings:client-new', 'primary'), 'settings-mcp') +
      group('Cache', row('Screenshot cache', 'Reusable previews keep navigation responsive.', toggle('screenshotCache', 'Screenshot cache')) + row('Temporary cache', demo.cacheCleared ? 'Sample cache cleared.' : '256 MB of sample preview cache.', button('Clear cache', 'settings:cache'))) +
      group('Timeline controls', row('Auto-play on opening', 'Begin simulated playback when Timeline opens.', toggle('timelineAutoplay', 'Timeline auto-play'))) +
      group('Developer', row('Diagnostic information', 'View a content-free sample of the local environment.', button('View diagnostics', 'settings:diagnostics'))) +
      group('Danger zone', '<p class="muted">These flows are demonstrations. Nothing on your Mac is changed.</p><div class="settings-inline">' + button('Reset common settings', 'settings:reset-common', 'danger') + button('Delete all data', 'settings:delete-all', 'danger') + '</div>');
  }
  const views = { general, capture, storage, export: () => group('Export & Data', '<div class="settings-coming"><span class="badge">Coming soon</span><h3>Take your memory with you</h3><p>Native bulk export is planned. The current interface reserves this space; there is no export operation to run.</p><a class="button" href="docs/full-spec.html">Read the specification</a></div>'), privacy, power, audio, tags, advanced };

  function render(section, ctx) {
    context = ctx;
    const aliases = { 'Export & Data': 'export', exportData: 'export' };
    section = aliases[section] || String(section || 'general').toLowerCase();
    if (!views[section]) section = 'general';
    ctx.state.settingsSection = section;
    const item = sections.find(s => s[0] === section);
    return '<div class="settings-layout"><aside class="settings-sidebar" aria-label="Settings navigation"><label class="settings-search"><span class="settings-sr">Search settings</span><input type="search" placeholder="Search settings" data-settings-search value="' + esc(demo.query) + '"></label><div class="settings-search-results" id="settings-search-results">' + searchResults(demo.query) + '</div><nav>' + sections.map(s => '<button type="button" data-action="settings:section:' + s[0] + '" class="settings-nav' + (s[0] === section ? ' selected' : '') + '"' + (s[0] === section ? ' aria-current="page"' : '') + '>' + s[1] + '</button>').join('') + '</nav><p class="muted settings-sidebar-note">Changes apply to this demo only. Reload to start again.</p></aside><div class="settings-content"><div class="settings-title"><div><h2>' + item[1] + '</h2><p class="muted">' + item[2] + '</p></div>' + button('Reset section', 'settings:reset-section', 'quiet') + '</div>' + views[section]() + '</div></div>';
  }
  function searchResults(query) {
    if (!query.trim()) return '';
    const q = query.toLowerCase();
    const terms = { general: 'update shortcut startup appearance support', capture: 'record screen interval resolution compression window context', storage: 'disk space backup library retention rewind older delete', export: 'export data coming soon', privacy: 'excluded permission password redaction quick delete', power: 'cpu OCR background processing speed energy', audio: 'microphone transcript speaker phrase purple banana marker whisper model companion', tags: 'tag colour', advanced: 'MCP client agent token cache diagnostics reset delete' };
    const matches = sections.filter(s => (s[1] + ' ' + terms[s[0]]).toLowerCase().includes(q));
    return '<p class="muted">' + matches.length + ' matching sections</p>' + matches.map(s => button(s[1], 'settings:search-go:' + s[0], 'quiet')).join('');
  }
  function ruleEditor(id) {
    const rule = demo.rules.find(r => r.id === id) || { phrase: '', title: '', meaning: '', aliases: '' };
    demo.editingRule = id || null;
    show(id ? 'Edit voice marker rule' : 'Add voice marker rule', field('settings-rule-phrase', 'Phrase', rule.phrase, 'e.g. Purple banana') + field('settings-rule-title', 'Marker name', rule.title, 'Remember this context') + field('settings-rule-meaning', 'Meaning', rule.meaning, 'What should this phrase help you remember?') + field('settings-rule-aliases', 'Aliases (optional)', rule.aliases, 'Alternative phrases, separated by commas') + notice('New rules start disabled. The spoken phrase anchors the moment; later context can be reviewed separately.'), [{ label: 'Cancel', action: 'settings:close' }, { label: 'Save rule', action: 'settings:rule-save', primary: true }]);
  }
  function tagEditor(id) {
    const tag = demo.tags.find(t => t.id === id) || { name: '', colour: '#398DFF' };
    show(id ? 'Edit tag' : 'Create tag', field('settings-tag-name', 'Tag name', tag.name) + '<label class="settings-field" for="settings-tag-colour">Colour<input type="color" id="settings-tag-colour" value="' + tag.colour + '"></label>', [{ label: 'Cancel', action: 'settings:close' }, { label: 'Save tag', action: 'settings:tag-save:' + (id || 0), primary: true }]);
  }
  function handle(action, el, ctx) {
    context = ctx;
    const [, command, arg] = action.split(':');
    if (command === 'close') { ctx.closeDialog(); return true; }
    if (command === 'section' || command === 'search-go') { demo.query = ''; ctx.state.settingsSection = arg; ctx.navigate('settings', arg); return true; }
    if (command === 'toggle') { demo.values[arg] = !demo.values[arg]; ctx.render(); return true; }
    if (command === 'voice-rules' || command === 'mcp') {
      ctx.state.settingsSection = command === 'voice-rules' ? 'audio' : 'advanced'; ctx.navigate('settings', ctx.state.settingsSection);
      setTimeout(() => { const node = document.getElementById(command === 'voice-rules' ? 'settings-voice-rules' : 'settings-mcp'); if (node) node.scrollIntoView({ block: 'start' }); }, 0); return true;
    }
    if (command === 'updates') show('Updates', '<p>This sample is based on the 2610.22.5 local trial interface, with the agreed scrolling flow.</p><p class="muted">No update check was sent and no native build is installed by the prototype.</p>');
    else if (command === 'shortcuts') show('Keyboard shortcuts', '<div class="settings-shortcuts"><span>Open Timeline</span><kbd>⌥ R</kbd><span>Search history</span><kbd>⌥ Space</kbd><span>Push to dictate</span><kbd>Hold fn</kbd></div>' + notice('Global macOS shortcuts are illustrative here. Browser keyboard navigation remains available.'));
    else if (command === 'about') show('About Retrace', '<h3>Your memory, on your Mac.</h3><p>Screen capture, audio, OCR, transcripts and searchable context.</p><p class="muted">Standalone click-through · 11 November 2026 · Sample data only</p>');
    else if (command === 'refresh-storage') { demo.storageUpdated = 'just now'; ctx.render(); ctx.toast('Sample storage measurement refreshed.'); }
    else if (command === 'location') show('Choose library location', ctx.state.recording ? '<p>Pause recording before changing the library location.</p>' + notice('This demo will not move any files.') : '<p>Sample destination: Documents / Retrace Library</p>' + notice('A native location change would require a restart. This example only previews that flow.'), ctx.state.recording ? [{ label: 'Done', action: 'settings:close', primary: true }] : [{ label: 'Cancel', action: 'settings:close' }, { label: 'Choose sample folder', action: 'settings:location-chosen', primary: true }]);
    else if (command === 'location-chosen') show('Restart required', '<p>Sample destination selected. A native restart would apply the location change.</p>' + notice('Your real library has not moved.'));
    else if (command === 'rewind') show('Choose Rewind folder', '<p>Sample folder: Archive / Rewind</p><p class="muted">Imported history stays distinct from native Retrace recordings.</p>', [{ label: 'Cancel', action: 'settings:close' }, { label: 'Use sample folder', action: 'settings:rewind-chosen', primary: true }]);
    else if (command === 'rewind-chosen') finish('Sample Rewind folder selected. No import started.');
    else if (command === 'retention') confirm('Review retention policy', 'Selected policy: <strong>' + esc(demo.values.retention) + '</strong>. Existing recordings must be reviewed before deletion.', 'settings:retention-save', 'Apply sample policy');
    else if (command === 'retention-save') finish('Sample retention policy saved. No history was deleted.');
    else if (command === 'review-preview') { demo.retainedDays = 'Before ' + (val('settings-review-date') || '2026-10-01'); demo.reviewStage = 'preview'; ctx.render(); }
    else if (command === 'review-confirm') confirm('Delete reviewed screen history?', 'The sample selection contains 14 days of screen history. The native flow would remove those moments and their screen text.', 'settings:review-delete', 'Delete sample selection');
    else if (command === 'review-delete') { demo.reviewStage = 'done'; finish('Sample review completed. No files deleted.'); }
    else if (command === 'review-cancel') { demo.reviewStage = ''; ctx.render(); }
    else if (command === 'review-next') { demo.reviewPage++; demo.reviewStage = 'preview'; ctx.render(); }
    else if (command === 'exclude-add') show('Exclude an application', '<label class="settings-field" for="settings-excluded-app">Application<select id="settings-excluded-app"><option>Mail</option><option>Safari</option><option>Notes</option><option>Messages</option></select></label>', [{ label: 'Cancel', action: 'settings:close' }, { label: 'Add exclusion', action: 'settings:exclude-save', primary: true }]);
    else if (command === 'exclude-save') { const name = val('settings-excluded-app'); if (name && !demo.excluded.includes(name)) demo.excluded.push(name); finish('Sample exclusion added.'); }
    else if (command === 'exclude-remove') { demo.excluded.splice(Number(arg), 1); ctx.render(); }
    else if (command === 'redaction-save') { demo.redaction = val('settings-redaction'); ctx.toast('Sample redaction rules saved.'); }
    else if (command === 'redaction-reload') { ctx.render(); ctx.toast('Restored the last saved sample rules.'); }
    else if (command === 'quick-delete') confirm('Delete recent history?', 'Review range: <strong>' + ['Last 5 minutes', 'Last hour', 'Last 24 hours'][Number(arg)] + '</strong>.', 'settings:quick-delete-confirm', 'Delete sample history');
    else if (command === 'quick-delete-confirm') finish('Sample deletion flow completed. No history was deleted.');
    else if (command === 'permissions') show('Recording permissions', '<p>Screen recording, microphone and accessibility are shown as allowed in this sample.</p><p class="muted">The browser does not request or change macOS permissions.</p>');
    else if (command === 'power-apps') show('Applications to process', Object.keys(demo.filterApps).map(name => '<label class="settings-checkbox"><input type="checkbox" data-settings-app="' + name + '"' + (demo.filterApps[name] ? ' checked' : '') + '> ' + name + '</label>').join(''), [{ label: 'Done', action: 'settings:power-apps-done', primary: true }]);
    else if (command === 'power-apps-done') { document.querySelectorAll('[data-settings-app]').forEach(input => { demo.filterApps[input.dataset.settingsApp] = input.checked; }); finish('Sample application filter updated.'); }
    else if (command === 'monitor') ctx.navigate('monitor');
    else if (command === 'rule-new') ruleEditor(null);
    else if (command === 'rule-edit') ruleEditor(Number(arg));
    else if (command === 'rule-toggle') { const rule = demo.rules.find(r => r.id === Number(arg)); if (rule) rule.enabled = !rule.enabled; ctx.render(); }
    else if (command === 'rule-save') {
      const phrase = val('settings-rule-phrase');
      if (!phrase) { ctx.toast('Enter a phrase before saving.'); document.getElementById('settings-rule-phrase').focus(); return true; }
      if (demo.rules.some(r => r.phrase.toLowerCase() === phrase.toLowerCase() && r.id !== demo.editingRule)) { ctx.toast('That phrase already has a rule.'); return true; }
      const existing = demo.rules.find(r => r.id === demo.editingRule);
      const rule = { id: existing ? existing.id : demo.nextRule++, phrase, title: val('settings-rule-title') || 'Remember this context', meaning: val('settings-rule-meaning'), aliases: val('settings-rule-aliases'), enabled: existing ? existing.enabled : false };
      if (existing) Object.assign(existing, rule); else demo.rules.push(rule);
      finish(existing ? 'Sample rule saved.' : 'Sample rule added, initially disabled.');
    }
    else if (command === 'rule-demo') {
      const rule = demo.rules.find(item => item.phrase.toLowerCase() === 'purple banana');
      if (!ctx.state.recording || !demo.values.mic) ctx.toast('Resume recording and enable the sample microphone before trying a voice marker.');
      else if (!demo.values.voiceEnabled || !demo.values.voiceAssets) ctx.toast('Enable marker phrases and prepare the sample speech assets first.');
      else if (!rule || !rule.enabled) ctx.toast('Enable the “Purple banana” rule before trying it.');
      else if (typeof ctx.createVoiceMarker === 'function') ctx.createVoiceMarker(Object.assign({}, rule));
      else show('A phrase marks the moment', '<p><strong>“Purple banana”</strong> → Remember this context</p><p>The phrase fixes the marker time. What you say afterwards supplies context; you can adjust the surrounding range later.</p>' + notice('This example does not listen to your microphone. Use Mark now in Live to create a sample marker.'), [{ label: 'Done', action: 'settings:close' }, { label: 'Open Live', action: 'settings:live', primary: true }]);
    }
    else if (command === 'live') { ctx.closeDialog(); ctx.navigate('dashboard', 'live'); }
    else if (command === 'voice-assets') { demo.values.voiceAssets = true; ctx.render(); ctx.toast('Sample speech assets marked ready. No download.'); }
    else if (command === 'companion') show('Private companion', field('settings-companion-endpoint', 'Endpoint', demo.companion ? 'http://127.0.0.1:9010' : '', 'http://127.0.0.1:9010') + field('settings-companion-token', 'Demo token', '', 'Use a made-up token only') + notice('Use dummy values. This prototype never sends a request or stores these fields.'), [{ label: 'Cancel', action: 'settings:close' }].concat(demo.companion ? [{ label: 'Disconnect', action: 'settings:companion-disconnect' }] : []).concat([{ label: 'Save sample connection', action: 'settings:companion-save', primary: true }]));
    else if (command === 'companion-save') { if (!val('settings-companion-endpoint')) { ctx.toast('Enter a sample endpoint.'); return true; } demo.companion = true; finish('Sample companion configured. No connection attempted.'); }
    else if (command === 'companion-disconnect') { demo.companion = false; finish('Sample companion disconnected.'); }
    else if (command === 'model') {
      const name = arg === 'whisper' ? 'Whisper transcription' : 'MiniLM embeddings';
      show(name, demo.models[arg] ? '<p>Sample model is ready to use.</p><p class="muted">No real model is bundled with this prototype.</p>' : '<p>Prepare the sample model to explore the download flow.</p><div class="settings-progress"><span style="width:0%"></span></div>', demo.models[arg] ? [{ label: 'Done', action: 'settings:close' }, { label: 'Delete model', action: 'settings:model-delete:' + arg }] : [{ label: 'Cancel', action: 'settings:close' }, { label: 'Start sample download', action: 'settings:model-progress:' + arg, primary: true }]);
    }
    else if (command === 'model-progress') show('Preparing sample model', '<div class="settings-progress"><span style="width:65%"></span></div><p>65% · Sample progress</p><p class="muted">No network request is being made.</p>', [{ label: 'Cancel', action: 'settings:close' }, { label: 'Complete sample download', action: 'settings:model-ready:' + arg, primary: true }]);
    else if (command === 'model-ready') { demo.models[arg] = true; finish('Sample model ready. Nothing was downloaded.'); }
    else if (command === 'model-delete') confirm('Delete model?', 'Prepared text and recordings would remain available; the model would need downloading again.', 'settings:model-deleted:' + arg, 'Delete sample model');
    else if (command === 'model-deleted') { demo.models[arg] = false; finish('Sample model removed.'); }
    else if (command === 'transcribe') confirm('Transcribe saved audio', 'Pending recordings will be prioritised for text preparation in this sample. You can cancel Process now in System Monitor.', 'settings:transcribe-start', 'Process now');
    else if (command === 'transcribe-start') { ctx.state.processNow = true; ctx.closeDialog(); ctx.navigate('monitor'); }
    else if (command === 'audio-history') { ctx.navigate('timeline', 'audio'); }
    else if (command === 'tag-new') tagEditor(null);
    else if (command === 'tag-edit') tagEditor(Number(arg));
    else if (command === 'tag-save') {
      const name = val('settings-tag-name'); if (!name) { ctx.toast('Enter a tag name.'); return true; }
      const existing = demo.tags.find(t => t.id === Number(arg));
      if (existing) { existing.name = name; existing.colour = val('settings-tag-colour'); } else demo.tags.push({ id: demo.nextTag++, name, colour: val('settings-tag-colour') || '#398DFF' }); finish('Sample tag saved.');
    }
    else if (command === 'tag-delete') confirm('Delete tag?', 'The tag will be removed from the sample list. Recorded moments are kept.', 'settings:tag-deleted:' + arg, 'Delete tag');
    else if (command === 'tag-deleted') { demo.tags = demo.tags.filter(t => t.id !== Number(arg)); finish('Sample tag deleted.'); }
    else if (command === 'client-new') show('Add an MCP client', field('settings-client-name', 'Client name', '', 'e.g. Accountant Pack') + '<label class="settings-field" for="settings-client-grant">Permissions<select id="settings-client-grant"><option>Read-only history and markers</option><option>Read history and create markers</option></select></label><label class="settings-field" for="settings-client-expiry">Expires<select id="settings-client-expiry"><option>In 7 days</option><option>In 30 days</option><option>At the end of this session</option></select></label>' + notice('Permission choices are illustrative. No live client or credential is created.'), [{ label: 'Cancel', action: 'settings:close' }, { label: 'Create sample client', action: 'settings:client-save', primary: true }]);
    else if (command === 'client-save') {
      const name = val('settings-client-name'); if (!name) { ctx.toast('Enter a client name.'); return true; }
      demo.clients.push({ id: demo.nextClient++, name, grant: val('settings-client-grant'), expiry: val('settings-client-expiry').toLowerCase() });
      show('Sample client created', '<p>This is a once-shown demonstration token. It cannot authenticate to anything.</p><div class="settings-token" id="settings-demo-token">••••••••••••••••••••</div><div class="settings-inline">' + button('Reveal', 'settings:token-reveal') + button('Copy', 'settings:token-copy') + '</div>', [{ label: 'Done', action: 'settings:client-done', primary: true }]);
    }
    else if (command === 'token-reveal') { const node = document.getElementById('settings-demo-token'); if (node) node.textContent = 'DEMO-ONLY-NOT-A-REAL-TOKEN'; }
    else if (command === 'token-copy') { const node = document.getElementById('settings-demo-token'); if (node) { node.textContent = 'DEMO-ONLY-NOT-A-REAL-TOKEN'; const selection = window.getSelection(); const range = document.createRange(); range.selectNodeContents(node); selection.removeAllRanges(); selection.addRange(range); } ctx.toast('Sample token selected. Press ⌘C or Ctrl+C to copy.'); }
    else if (command === 'client-done') finish('Sample client added. No real access granted.');
    else if (command === 'revoke') confirm('Revoke client access?', 'The sample client will be removed immediately.', 'settings:revoked:' + arg, 'Revoke');
    else if (command === 'revoked') { demo.clients = demo.clients.filter(c => c.id !== Number(arg)); finish('Sample client revoked.'); }
    else if (command === 'cache') confirm('Clear temporary cache?', 'Prepared text, audio and screen history are retained.', 'settings:cache-cleared', 'Clear sample cache');
    else if (command === 'cache-cleared') { demo.cacheCleared = true; finish('Sample cache cleared. No files changed.'); }
    else if (command === 'diagnostics') show('Sample diagnostics', '<dl class="settings-diagnostics"><dt>Platform</dt><dd>macOS · Apple Silicon</dd><dt>Reference build</dt><dd>2610.22.5 local trial</dd><dt>UI mode</dt><dd>Standalone HTML</dd><dt>Network requests</dt><dd>None</dd><dt>Recording devices</dt><dd>Not accessed</dd></dl>');
    else if (command === 'reset-section') confirm('Reset this section?', 'Restore the demo defaults for ' + esc(ctx.state.settingsSection) + '.', 'settings:reset-section-confirm', 'Reset section');
    else if (command === 'reset-section-confirm') { resetSection(ctx.state.settingsSection); finish('Section reset to sample defaults.'); }
    else if (command === 'reset-common') confirm('Reset common settings?', 'Restore all settings to their initial sample values.', 'settings:reset-common-confirm', 'Reset settings');
    else if (command === 'reset-common-confirm') { demo = defaults(); finish('All sample settings reset.'); }
    else if (command === 'delete-all') confirm('Delete all recorded data?', 'This native action is irreversible. In the prototype it only demonstrates the confirmation; no recordings exist here.', 'settings:delete-all-confirm', 'Confirm sample deletion');
    else if (command === 'delete-all-confirm') finish('Deletion flow demonstrated. Your actual history is unchanged.');
    else return false;
    return true;
  }
  function resetSection(section) {
    const keys = { general: ['automaticUpdates','launchAtLogin','dockIcon','appearance','shortcuts'], capture: ['captureContext','directText','display','captureRate','compression','pauseReminder'], storage: ['retention'], privacy: ['redactPasswords'], power: ['ocrEnabled','processingSpeed','ocrPriority'], audio: ['mic','micInput','systemAudio','voiceEnabled','markerSound','pushToDictate','voiceAssets'], advanced: ['listener','timelineAutoplay','screenshotCache'] };
    const fresh = defaults(); (keys[section] || []).forEach(key => { demo.values[key] = fresh.values[key]; });
    if (section === 'privacy') { demo.excluded = fresh.excluded; demo.redaction = fresh.redaction; }
    if (section === 'tags') demo.tags = fresh.tags;
    if (section === 'audio') { demo.rules = fresh.rules; demo.models = fresh.models; demo.companion = false; }
    if (section === 'advanced') { demo.clients = []; demo.cacheCleared = false; }
    if (section === 'power') demo.filterApps = fresh.filterApps;
    if (section === 'storage') { demo.reviewStage = ''; demo.reviewPage = 1; }
  }
  document.addEventListener('input', function (event) {
    const target = event.target;
    if (target.matches('[data-settings-search]')) { demo.query = target.value; const results = document.getElementById('settings-search-results'); if (results) results.innerHTML = searchResults(demo.query); }
    if (target.matches('[data-settings-value="ocrPriority"]')) { demo.values.ocrPriority = Number(target.value); const output = document.getElementById('settings-priority-value'); if (output) output.textContent = target.value + '%'; }
  });
  document.addEventListener('change', function (event) {
    const target = event.target;
    if (target.matches('[data-settings-value]')) { demo.values[target.dataset.settingsValue] = target.type === 'range' ? Number(target.value) : target.value; if (context) context.toast('Sample setting updated.'); }
  });
  document.addEventListener('keydown', function (event) {
    if (event.key === 'Escape' && event.target.matches('[data-settings-search]')) { demo.query = ''; event.target.value = ''; const results = document.getElementById('settings-search-results'); if (results) results.innerHTML = ''; event.stopPropagation(); }
  });
  window.RetraceSettings = {
    render, handle, reset: () => { demo = defaults(); },
    snapshot: () => Object.freeze({
      voiceEnabled: demo.values.voiceEnabled,
      companion: demo.companion,
      rules: Object.freeze(demo.rules.map(rule => Object.freeze(Object.assign({}, rule)))),
      tags: Object.freeze(demo.tags.map(tag => Object.freeze(Object.assign({}, tag))))
    })
  };

  function monitorRender(ctx) {
    context = ctx;
    const counts = ctx.state.processNow ? [842, 1, 0] : [842, 0, 1];
    const heights = [17,22,28,20,32,35,26,43,38,24,22,33,44,29,24,21,31,34,39,28,25,20,18,29,31,24,20,17,13,18];
    return '<div class="monitor-layout"><section class="panel monitor-status"><div><h2>' + (ctx.state.recording ? 'Recording continues' : 'Recording paused') + '</h2><p class="muted">Text preparation: ' + (ctx.state.processNow ? 'Processing now' : 'Waiting for a quiet moment') + '</p><p>Audio and screen text share the background CPU budget. Fresh recordings take priority.</p></div><div>' + button(ctx.state.processNow ? 'Cancel Process now' : 'Process now', 'monitor:process', ctx.state.processNow ? '' : 'primary') + '</div></section>' + (!ctx.state.recording ? notice('Resume recording to process pending audio here, or use Transcribe Saved Audio in Audio settings. ' + button('Audio settings', 'monitor:audio', 'quiet')) : '') +
      '<section class="panel monitor-section"><div class="settings-title"><h3>Retrace CPU</h3><span class="badge">Sample measurements</span></div><div class="monitor-metrics">' + [['Now', ctx.state.processNow ? '24.8%' : '8.4%'], ['1 min average', '11.2%'], ['15 min average', '14.6%'], ['15 min peak', '42.1%']].map(p => '<div><span class="muted">' + p[0] + '</span><strong>' + p[1] + '</strong></div>').join('') + '</div><p class="muted">100% is one CPU core. Whole Mac: 18% · Sample coverage: 98%. These are illustrative values, not live measurements.</p></section>' +
      '<section class="panel monitor-section"><div class="settings-title"><div><h3>OCR processing</h3><p class="muted">Frames processed · Last 30 minutes</p></div>' + button('Processing settings', 'monitor:power', 'quiet') + '</div><div class="monitor-chart" role="img" aria-label="Illustrative screen text preparation over the last thirty minutes">' + heights.map((height, i) => '<span style="height:' + (height * 2) + '%" class="' + (i > 23 ? 'monitor-chart-late' : '') + '"></span>').join('') + '</div><div class="monitor-chart-label"><span>−30 min</span><span>Now</span></div><div class="monitor-metrics monitor-three">' + [['Processed', counts[0]], ['Processing', counts[1]], ['Pending', counts[2]]].map(p => '<div><strong>' + p[1] + '</strong><span class="muted">' + p[0] + '</span></div>').join('') + '</div>' + (!demo.values.ocrEnabled ? notice('OCR is paused in Power settings. New screenshots remain visible.') : '<p class="muted">Pending text remains visible as pending. Background deferral is not a recording failure.</p>') + '</section>' +
      '<section class="panel monitor-section"><div class="settings-title"><div><h3>Recent process samples</h3><p class="muted">' + (demo.baseline ? 'Baseline restarted for this demo.' : 'Content-free sample CPU and memory readings.') + '</p></div>' + button('Restart Baseline', 'monitor:baseline') + '</div><div class="monitor-table-wrap"><table class="monitor-table"><thead><tr><th>Time</th><th>Retrace CPU</th><th>Memory</th><th>Whole Mac</th></tr></thead><tbody>' + (demo.baseline ? [['Now', '8.4%', '684 MB', '18%']] : [['11:42:00', '8.4%', '684 MB', '18%'], ['11:41:00', '11.7%', '686 MB', '21%'], ['11:40:00', '13.6%', '691 MB', '24%'], ['11:39:00', '9.1%', '687 MB', '19%']]).map(values => '<tr>' + values.map(v => '<td>' + v + '</td>').join('') + '</tr>').join('') + '</tbody></table></div></section></div>';
  }
  function monitorHandle(action, el, ctx) {
    context = ctx;
    const command = action.split(':')[1];
    if (command === 'process') { ctx.state.processNow = !ctx.state.processNow; ctx.render(); ctx.toast(ctx.state.processNow ? 'Sample catch-up started. Recording has priority.' : 'Sample catch-up cancelled. Pending work is retained.'); }
    else if (command === 'power' || command === 'audio') { ctx.state.settingsSection = command; ctx.navigate('settings', command); }
    else if (command === 'baseline') { demo.baseline = true; ctx.render(); ctx.toast('Sample baseline restarted.'); }
    else return false;
    return true;
  }
  window.RetraceMonitor = { render: monitorRender, handle: monitorHandle };
}());
