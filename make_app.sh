#!/usr/bin/env bash
# Family Map - Android app generator + APK builder.
# GitHub Actions ye script chalata hai, APK app/android/app/build/outputs/apk/debug/ me banta hai.
set -euo pipefail

rm -rf app
mkdir app
cd app

npm init -y >/dev/null
npm install --legacy-peer-deps \
  @capacitor/core@7 @capacitor/cli@7 @capacitor/android@7 \
  @capacitor/local-notifications@7 \
  @capacitor-community/background-geolocation@1.2.25

cat > capacitor.config.json <<'CONFIG_EOF'
{
  "appId": "com.family.livemap",
  "appName": "Family Map",
  "webDir": "www",
  "server": { "androidScheme": "https", "cleartext": true },
  "android": { "useLegacyBridge": true },
  "plugins": { "CapacitorHttp": { "enabled": true } }
}
CONFIG_EOF

mkdir www
cat > www/index.html <<'HTML_EOF'
<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Family Map</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
html,body,#map{height:100%;margin:0}
body{font-family:system-ui,sans-serif}
#panel{position:fixed;left:0;right:0;bottom:0;z-index:1000;background:#fff;
  padding:12px 14px max(env(safe-area-inset-bottom),16px);
  border-radius:16px 16px 0 0;box-shadow:0 -2px 14px rgba(0,0,0,.2)}
#row{display:flex;gap:8px}
#name{flex:1;min-width:0;font-size:17px;padding:10px;border:1px solid #bbb;border-radius:8px}
#go{font-size:17px;padding:10px 14px;border:0;border-radius:8px;background:#1a73e8;color:#fff}
#go.on{background:#c5221f}
#batt{display:none;width:100%;margin-top:8px;font-size:16px;padding:10px;border:0;
  border-radius:8px;background:#f9ab00;color:#222}
#status{margin:8px 0 0;font-size:14px;color:#555}
#people{margin-top:8px;display:flex;gap:8px;overflow-x:auto;padding-bottom:2px}
.chip{flex:none;padding:7px 12px;border:2px solid transparent;border-radius:18px;color:#fff;font-size:15px}
.chip.on{border-color:#222}
#gear{position:fixed;top:max(env(safe-area-inset-top),28px);right:12px;z-index:1000;
  padding:10px 16px;border:0;border-radius:22px;background:#fff;font-size:15px;
  box-shadow:0 1px 6px rgba(0,0,0,.35)}
#cfg{position:fixed;inset:0;z-index:2000;background:rgba(0,0,0,.45);display:none;
  align-items:center;justify-content:center;padding:20px}
#cfg.open{display:flex}
#cfgbox{background:#fff;border-radius:14px;padding:16px;width:100%;max-width:380px}
#cfgbox label{display:block;font-size:14px;color:#444;margin-top:10px}
#cfgbox input{width:100%;box-sizing:border-box;font-size:17px;padding:10px;
  border:1px solid #bbb;border-radius:8px;margin-top:4px}
#save{margin-top:14px;width:100%;font-size:17px;padding:10px;border:0;border-radius:8px;
  background:#1a73e8;color:#fff}
.pin{--c:#1a73e8;width:34px;height:34px;border-radius:50%;background:var(--c);
  border:3px solid #fff;color:#fff;font-weight:700;display:flex;align-items:center;
  justify-content:center;box-shadow:0 1px 6px rgba(0,0,0,.45);position:relative;box-sizing:border-box}
.pin::after{content:"";position:absolute;inset:-3px;border-radius:50%;
  border:3px solid var(--c);animation:pulse 2s ease-out infinite}
@keyframes pulse{from{transform:scale(1);opacity:.8}to{transform:scale(2.2);opacity:0}}
@media (prefers-reduced-motion:reduce){.pin::after{animation:none}}
</style>
</head><body>
<div id="map"></div>
<button id="gear">Server</button>

<div id="cfg"><div id="cfgbox">
  <b>Server settings</b>
  <label>Server link<input id="server" placeholder="https://username.pythonanywhere.com" autocapitalize="none" autocomplete="off"></label>
  <label>Family code<input id="code" autocapitalize="none" autocomplete="off"></label>
  <button id="save">Save karo</button>
</div></div>

<div id="panel">
  <div id="row">
    <input id="name" placeholder="Tumhara naam" maxlength="20" autocomplete="off">
    <button id="go">Sharing shuru karo</button>
  </div>
  <button id="batt">Battery optimisation off karo</button>
  <p id="status">Abhi sharing band hai</p>
  <div id="people"></div>
</div>

<script>
const DUR = 1800;
const $ = id => document.getElementById(id);
const stub = () => new Proxy({}, {get: () => async () => { throw new Error('Sirf app me chalega'); }});
const Cap = window.Capacitor || {registerPlugin: stub};
const BG = Cap.registerPlugin('BackgroundGeolocation');
const Battery = Cap.registerPlugin('Battery');
const Notif = Cap.registerPlugin('LocalNotifications');

function load(k) { try { return localStorage.getItem(k) || ''; } catch (e) { return ''; } }
function store(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
const say = t => { $('status').textContent = t; };

const cfg = {server: load('server'), code: load('code')};
$('name').value = load('name');
$('server').value = cfg.server;
$('code').value = cfg.code;
if (!cfg.server || !cfg.code) $('cfg').classList.add('open');
$('gear').onclick = () => $('cfg').classList.add('open');

const map = L.map('map', {zoomControl: false}).setView([20, 78], 5);
L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  {maxZoom: 19, attribution: '&copy; OpenStreetMap'}).addTo(map);

const people = {};
let me = '', sharing = false, watcher = null, following = null, fitted = false;

$('save').onclick = () => {
  let s = $('server').value.trim();
  if (s && !/^https?:\/\//.test(s)) s = 'https://' + s;
  cfg.server = s.replace(/\/+$/, '');
  cfg.code = $('code').value.trim();
  store('server', cfg.server);
  store('code', cfg.code);
  $('cfg').classList.remove('open');
  fitted = false;
  poll();
};

function colorOf(n) {
  let h = 0;
  for (const c of n) h = (h * 31 + c.charCodeAt(0)) % 360;
  return 'hsl(' + h + ',65%,42%)';
}

function upsert(name, lat, lon, ts) {
  let p = people[name];
  if (!p) {
    const c = colorOf(name);
    const el = document.createElement('div');
    el.className = 'pin';
    el.style.setProperty('--c', c);
    el.textContent = [...name][0].toUpperCase();
    const icon = L.divIcon({className: '', html: el, iconSize: [34, 34], iconAnchor: [17, 17]});
    people[name] = {
      color: c, ts: ts, pts: [[lat, lon]], to: null,
      marker: L.marker([lat, lon], {icon, title: name}).addTo(map),
      trail: L.polyline([[lat, lon]], {color: c, weight: 4, opacity: 0.5}).addTo(map)
    };
    return;
  }
  p.ts = ts;
  const last = p.pts[p.pts.length - 1];
  if (Math.abs(last[0] - lat) < 1e-6 && Math.abs(last[1] - lon) < 1e-6) return;
  const cur = p.marker.getLatLng();
  p.from = [cur.lat, cur.lng];
  p.to = [lat, lon];
  p.t0 = performance.now();
  p.pts.push([lat, lon]);
  if (p.pts.length > 60) p.pts.shift();
  p.trail.setLatLngs(p.pts);
}

function removePerson(n) {
  const p = people[n];
  if (!p) return;
  map.removeLayer(p.marker);
  map.removeLayer(p.trail);
  delete people[n];
  if (following === n) following = null;
}

function frame(now) {
  for (const [n, p] of Object.entries(people)) {
    if (p.to) {
      const k = Math.min(1, (now - p.t0) / DUR);
      const e = 1 - Math.pow(1 - k, 3);
      p.marker.setLatLng([
        p.from[0] + (p.to[0] - p.from[0]) * e,
        p.from[1] + (p.to[1] - p.from[1]) * e
      ]);
      if (k === 1) p.to = null;
    }
    if (following === n) map.setView(p.marker.getLatLng(), map.getZoom(), {animate: false});
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
map.on('dragstart', () => { following = null; renderChips(); });

function renderChips() {
  const box = $('people');
  box.replaceChildren();
  const now = Date.now() / 1000;
  for (const [n, p] of Object.entries(people)) {
    const age = Math.max(0, Math.round(now - p.ts));
    p.marker.setOpacity(age > 1800 ? 0.45 : 1);
    const b = document.createElement('button');
    b.className = 'chip' + (following === n ? ' on' : '');
    b.style.background = p.color;
    b.textContent = n + ' ' + (age < 60 ? age + 's' : Math.round(age / 60) + 'm');
    b.onclick = () => {
      following = following === n ? null : n;
      if (following) map.setView(p.marker.getLatLng(), 17);
      renderChips();
    };
    box.appendChild(b);
  }
}
setInterval(renderChips, 1000);

async function poll() {
  if (!cfg.server || !cfg.code) return;
  try {
    const r = await fetch(cfg.server + '/locations?code=' + encodeURIComponent(cfg.code));
    if (r.status === 403) { say('Family code galat hai'); return; }
    if (!r.ok) return;
    const d = await r.json();
    const now = Date.now() / 1000;
    for (const [n, v] of Object.entries(d)) {
      if (n === me && sharing) continue;
      upsert(n, v.lat, v.lon, now - v.age);
    }
    for (const n of Object.keys(people)) {
      if (!(n in d) && !(n === me && sharing)) removePerson(n);
    }
    if (!fitted && Object.keys(people).length) {
      const g = L.featureGroup(Object.values(people).map(p => p.marker));
      map.fitBounds(g.getBounds().pad(0.3), {maxZoom: 16});
      fitted = true;
    }
    renderChips();
  } catch (e) {}
}
setInterval(poll, 2000);
poll();

function post(body) {
  return fetch(cfg.server + '/update', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(Object.assign({code: cfg.code, name: me}, body))
  });
}

function send(loc) {
  upsert(me, loc.latitude, loc.longitude, Date.now() / 1000);
  post({lat: loc.latitude, lon: loc.longitude, acc: loc.accuracy}).then(r => {
    say(r.ok ? 'Location bheji ' + new Date().toLocaleTimeString() : 'Family code galat hai');
  }).catch(() => say('Network error, dobara try ho raha hai'));
}

async function checkBattery() {
  try {
    const s = await Battery.status();
    $('batt').style.display = s.ignoring ? 'none' : 'block';
  } catch (e) { $('batt').style.display = 'none'; }
}
$('batt').onclick = async () => { try { await Battery.request(); } catch (e) {} };
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') checkBattery();
});
checkBattery();

async function stopShare() {
  try { await BG.removeWatcher({id: watcher}); } catch (e) {}
  sharing = false;
  watcher = null;
  post({stop: true}).catch(() => {});
  removePerson(me);
  $('go').textContent = 'Sharing shuru karo';
  $('go').classList.remove('on');
  say('Abhi sharing band hai');
}

$('go').onclick = async () => {
  if (sharing) { await stopShare(); return; }
  const name = $('name').value.trim();
  if (!name) { say('Pehle apna naam likho'); return; }
  if (!cfg.server || !cfg.code) { $('cfg').classList.add('open'); return; }
  me = name;
  store('name', name);
  say('Permissions maang raha hai...');
  try { await Notif.requestPermissions(); } catch (e) {}
  try {
    watcher = await BG.addWatcher({
      backgroundTitle: 'Family Map',
      backgroundMessage: 'Aapki location share ho rahi hai',
      requestPermissions: true,
      stale: false,
      distanceFilter: 10
    }, (loc, err) => {
      if (err) {
        if (err.code === 'NOT_AUTHORIZED' && confirm('Location permission chahiye. Settings kholein?')) {
          BG.openSettings();
        }
        say('Location error: ' + (err.message || err.code));
        return;
      }
      send(loc);
    });
    sharing = true;
    $('go').textContent = 'Sharing band karo';
    $('go').classList.add('on');
    say('Location dhundh raha hai...');
    checkBattery();
  } catch (e) {
    say('Start nahi hua: ' + e.message);
  }
};
</script>
</body></html>
HTML_EOF

npx cap add android

# --- Android manifest: permissions + (zaroorat ho to) location service ---
python3 - <<'PY_EOF'
p = 'android/app/src/main/AndroidManifest.xml'
s = open(p).read()

service = ''
try:
    lib = open('node_modules/@capacitor-community/background-geolocation/android/src/main/AndroidManifest.xml').read()
    if 'BackgroundGeolocationService' not in lib:
        service = ('    <service android:name="com.equimaps.capacitor_background_geolocation.BackgroundGeolocationService"'
                   ' android:enabled="true" android:exported="true" android:foregroundServiceType="location" />\n')
except OSError:
    pass

perms = (
    '    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />\n'
    '    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />\n'
    '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />\n'
    '    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION" />\n'
    '    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />\n'
    '    <uses-permission android:name="android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS" />\n'
    '    <uses-feature android:name="android.hardware.location.gps" android:required="false" />\n'
)
s = s.replace('<application', perms + '    <application android:usesCleartextTraffic="true"', 1)
if service:
    s = s.replace('</application>', service + '    </application>', 1)
open(p, 'w').write(s)
print(s)
PY_EOF

# --- Battery optimisation plugin (native) ---
JAVA_DIR=android/app/src/main/java/com/family/livemap
mkdir -p "$JAVA_DIR"

cat > "$JAVA_DIR/BatteryPlugin.java" <<'JAVA_EOF'
package com.family.livemap;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.PowerManager;
import android.provider.Settings;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

@CapacitorPlugin(name = "Battery")
public class BatteryPlugin extends Plugin {

    @PluginMethod
    public void status(PluginCall call) {
        PowerManager pm = (PowerManager) getContext().getSystemService(Context.POWER_SERVICE);
        JSObject res = new JSObject();
        res.put("ignoring", pm.isIgnoringBatteryOptimizations(getContext().getPackageName()));
        call.resolve(res);
    }

    @PluginMethod
    public void request(PluginCall call) {
        try {
            Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
            i.setData(Uri.parse("package:" + getContext().getPackageName()));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(i);
        } catch (Exception e) {
            Intent i = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            getContext().startActivity(i);
        }
        call.resolve();
    }
}
JAVA_EOF

cat > "$JAVA_DIR/MainActivity.java" <<'JAVA_EOF'
package com.family.livemap;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(BatteryPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
JAVA_EOF

# --- Notification icon + text for the background-location notification ---
mkdir -p android/app/src/main/res/drawable android/app/src/main/res/values

cat > android/app/src/main/res/drawable/ic_tracking.xml <<'XML_EOF'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp" android:height="24dp"
    android:viewportWidth="24" android:viewportHeight="24">
  <path android:fillColor="#FFFFFFFF"
      android:pathData="M12,2C8.13,2 5,5.13 5,9c0,5.25 7,13 7,13s7,-7.75 7,-13c0,-3.87 -3.13,-7 -7,-7zM12,11.5c-1.38,0 -2.5,-1.12 -2.5,-2.5s1.12,-2.5 2.5,-2.5 2.5,1.12 2.5,2.5 -1.12,2.5 -2.5,2.5z"/>
</vector>
XML_EOF

cat > android/app/src/main/res/values/bg_geo.xml <<'XML_EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="capacitor_background_geolocation_notification_channel_name">Family Map location</string>
    <string name="capacitor_background_geolocation_notification_icon">drawable/ic_tracking</string>
    <string name="capacitor_background_geolocation_notification_color">blue</string>
</resources>
XML_EOF

npx cap sync android

cd android
chmod +x gradlew
./gradlew assembleDebug --no-daemon

echo "APK ready:"
ls -lh app/build/outputs/apk/debug/
