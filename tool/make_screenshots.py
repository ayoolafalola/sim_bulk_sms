#!/usr/bin/env python3
"""Store screenshots for Messages++: a caption on the brand gradient above a device showing an app screen,
drawn in the app's own colours, font and layout with demo data (no real people).

    python3 tool/make_screenshots.py     # all sets
      assets/store/screenshot_1..8.png       Google Play phone, 1080x1920
      assets/store/ios/iphone_1..7.png       App Store iPhone 6.9", 1320x2868
      assets/store/ios/ipad_1..7.png         App Store iPad 13", 2064x2752

Each set shows what that platform's app really does (the iPhone app has no inbox and texts need a tap each).

Needs Google Chrome (headless) and an internet connection for the fonts.
"""
import os
import subprocess
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'assets', 'store')
CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
LOGO = open(os.path.join(ROOT, 'assets', 'icon', 'src', 'icon_full.svg')).read()
LOGO = LOGO[LOGO.index('>') + 1:LOGO.rindex('</svg>')]

CSS = r'''
* { box-sizing: border-box; margin: 0; padding: 0; }
html, body { overflow: hidden; }
body { font-family: "Plus Jakarta Sans", sans-serif; color: #16201c;
  background: radial-gradient(900px 500px at 90% 0%, rgba(242,179,61,.22), transparent 60%), linear-gradient(160deg, #1f7a66, #0f4237); }
.i { font-family: "Material Symbols Rounded"; font-weight: normal; font-style: normal; line-height: 1; letter-spacing: normal;
  text-transform: none; white-space: nowrap; direction: ltr; -webkit-font-feature-settings: "liga"; font-feature-settings: "liga";
  font-variation-settings: "FILL" 0, "wght" 500, "GRAD" 0, "opsz" 24; }
.fill { font-variation-settings: "FILL" 1, "wght" 500, "GRAD" 0, "opsz" 24; }
.cap { position: absolute; top: 96px; left: 80px; right: 80px; color: #fff; text-align: center; }
.cap h1 { font-size: 74px; font-weight: 800; letter-spacing: -2px; line-height: 1.08; }
.cap h1 em { font-style: normal; color: #F2B33D; }
.cap p { margin-top: 22px; font-size: 34px; font-weight: 500; color: #cfe9e1; line-height: 1.35; }
.phone { position: absolute; left: 160px; top: 420px; width: 760px; height: 1478px; border-radius: 92px; background: #0b0f0e;
  padding: 22px; box-shadow: 0 40px 90px rgba(0,0,0,.45), inset 0 0 0 3px #26302c; }
.screen { width: 390px; height: 780px; transform: scale(1.8359); transform-origin: 0 0; border-radius: 39px; overflow: hidden;
  background: #F7F5F0; position: relative; font-size: 14px; }
.status { height: 34px; display: flex; align-items: center; justify-content: space-between; padding: 6px 26px 0; font-size: 13px; font-weight: 700; }
.status .i { font-size: 15px; }
.title { display: flex; align-items: center; padding: 8px 12px 8px 20px; }
.title h2 { flex: 1; font-size: 28px; font-weight: 800; letter-spacing: -.5px; }
.title .i { font-size: 24px; color: #5b6763; padding: 8px; }
.muted { color: #5b6763; }
.search { margin: 0 16px 10px; height: 46px; border-radius: 24px; background: #fff; border: 1px solid #e6e2da; display: flex;
  align-items: center; gap: 10px; padding: 0 16px; color: #5b6763; }
.chips { display: flex; gap: 8px; padding: 0 16px 10px; }
.chip { height: 34px; padding: 0 14px; border-radius: 10px; border: 1px solid #d6d1c7; display: flex; align-items: center; font-weight: 600; font-size: 13px; background: #fff; }
.chip.on { background: #ddefe9; border-color: #ddefe9; color: #124E41; }
.sheet { position: absolute; left: 0; right: 0; bottom: 80px; background: #fff; border-radius: 24px 24px 0 0; overflow: hidden; }
.tile { display: flex; align-items: center; gap: 12px; padding: 11px 20px; }
.av { width: 46px; height: 46px; border-radius: 50%; flex: none; display: grid; place-items: center; font-weight: 800; font-size: 15px; }
.a1 { background: #ddefe9; color: #124E41; } .a2 { background: #e3e8fa; color: #2A3A8A; } .a3 { background: #fff1c7; color: #7A4B00; }
.a4 { background: #fbe2e2; color: #8F1D1D; } .a5 { background: #efebe3; color: #4a5551; }
.tile .body { flex: 1; min-width: 0; }
.row { display: flex; align-items: center; gap: 8px; }
.name { flex: 1; font-weight: 700; font-size: 15.5px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.time { font-size: 11.5px; color: #5b6763; }
.snip { font-size: 13.5px; color: #5b6763; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-top: 2px; }
.unread .name { font-weight: 800; } .unread .snip { color: #16201c; font-weight: 600; }
.count { background: #1B6B5A; color: #fff; font-size: 11px; font-weight: 700; border-radius: 99px; padding: 2px 7px; }
.nav { position: absolute; left: 0; right: 0; bottom: 0; height: 80px; background: #fff; border-top: 1px solid #efebe3; display: flex; }
.nav div { flex: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 4px; font-size: 11.5px; font-weight: 700; color: #5b6763; position: relative; }
.nav .i { font-size: 22px; width: 58px; height: 30px; border-radius: 16px; display: grid; place-items: center; }
.nav .on { color: #16201c; } .nav .on .i { background: #ddefe9; color: #124E41; }
.badge { position: absolute; top: 12px; left: 50%; margin-left: 8px; background: #B3261E; color: #fff; font-size: 10px; font-weight: 700; border-radius: 99px; padding: 1px 5px; }
.fab { position: absolute; right: 16px; bottom: 96px; height: 54px; padding: 0 18px; border-radius: 16px; background: #c6eadc; color: #0f3d33;
  display: flex; align-items: center; gap: 8px; font-weight: 700; box-shadow: 0 4px 12px rgba(0,0,0,.18); }
.appbar { display: flex; align-items: center; gap: 10px; padding: 6px 12px 10px 8px; background: #F7F5F0; }
.appbar .i { font-size: 24px; padding: 8px; }
.appbar h3 { flex: 1; font-size: 19px; font-weight: 700; }
.thread { padding: 6px 14px; display: flex; flex-direction: column; gap: 7px; }
.day { align-self: center; font-size: 11.5px; color: #5b6763; font-weight: 600; margin: 6px 0; }
.b { max-width: 80%; padding: 9px 13px; border-radius: 20px; line-height: 1.4; font-size: 14px; }
.in { align-self: flex-start; background: #fff; border: 1px solid #e6e2da; border-bottom-left-radius: 6px; }
.out { align-self: flex-end; background: #1B6B5A; color: #fff; border-bottom-right-radius: 6px; }
.meta { align-self: flex-end; font-size: 11px; color: #5b6763; margin-top: -3px; }
.ctag { align-self: flex-end; font-size: 11px; font-weight: 700; color: #124E41; background: #ddefe9; padding: 3px 10px; border-radius: 99px; display: flex; align-items: center; gap: 4px; }
.ctag .i { font-size: 14px; }
.reply { position: absolute; left: 10px; right: 10px; bottom: 14px; display: flex; gap: 8px; align-items: center; }
.reply .box { flex: 1; height: 48px; border-radius: 24px; background: #fff; border: 1px solid #e6e2da; display: flex; align-items: center; padding: 0 16px; color: #5b6763; gap: 8px; }
.sim { font-size: 11.5px; font-weight: 700; background: #efebe3; border-radius: 99px; padding: 4px 9px; color: #16201c; }
.send { width: 48px; height: 48px; border-radius: 50%; background: #1B6B5A; color: #fff; display: grid; place-items: center; }
.qr { display: flex; gap: 8px; padding: 0 14px; position: absolute; bottom: 72px; left: 0; right: 0; }
.qr span { border: 1px solid #d6d1c7; background: #fff; border-radius: 10px; padding: 6px 12px; font-size: 12.5px; font-weight: 600; }
.form { padding: 4px 16px; display: flex; flex-direction: column; gap: 12px; }
.field { background: #fff; border: 1px solid #d6d1c7; border-radius: 12px; padding: 7px 14px 9px; }
.field label { display: block; font-size: 11.5px; color: #1B6B5A; font-weight: 700; }
.field div { font-size: 15px; line-height: 1.45; }
.field .ph { color: #1B6B5A; font-weight: 700; }
.counter { font-size: 11.5px; color: #5b6763; margin-top: -6px; }
.vars { display: flex; flex-wrap: wrap; gap: 6px; }
.vars span { border: 1px solid #d6d1c7; border-radius: 8px; padding: 4px 9px; font-size: 12px; font-weight: 600; background: #fff; }
.card { background: #fff; border: 1px solid #e6e2da; border-radius: 18px; padding: 14px 16px; }
.card h4 { font-size: 20px; font-weight: 800; }
.preview { background: #efebe3; border-radius: 12px; padding: 10px 12px; margin-top: 8px; line-height: 1.45; font-size: 13.5px; }
.lbl { font-size: 11px; font-weight: 800; letter-spacing: .1em; color: #5b6763; text-transform: uppercase; margin: 6px 0 2px; }
.gchips { display: flex; gap: 6px; flex-wrap: wrap; }
.gchips span { border-radius: 8px; padding: 6px 10px; font-size: 12.5px; font-weight: 600; border: 1px solid #d6d1c7; background: #fff; display: flex; gap: 4px; align-items: center; }
.gchips span.on { background: #ddefe9; border-color: #ddefe9; color: #124E41; }
.gchips .i { font-size: 15px; }
.btn { height: 46px; border-radius: 24px; background: #1B6B5A; color: #fff; display: flex; align-items: center; justify-content: center; gap: 8px; font-weight: 700; font-size: 15px; }
.btn.tonal { background: #ddefe9; color: #124E41; }
.btn.outline { background: transparent; color: #1B6B5A; border: 1px solid #b9b3a8; }
.tag { display: inline-block; font-size: 11.5px; font-weight: 700; padding: 3px 9px; border-radius: 99px; }
.t-ok { background: #DDEFE9; color: #124C3F; } .t-warn { background: #FFF1C7; color: #7A4B00; } .t-info { background: #E3E8FA; color: #2A3A8A; }
.bar { height: 8px; border-radius: 4px; background: #efebe3; overflow: hidden; } .bar i { display: block; height: 100%; background: #1B6B5A; border-radius: 4px; }
.stat { display: flex; gap: 6px; flex-wrap: wrap; }
.stat span { background: #fff; border: 1px solid #d6d1c7; border-radius: 8px; padding: 5px 9px; font-size: 12px; font-weight: 600; }
.rtile { display: flex; align-items: center; gap: 10px; padding: 9px 0; border-bottom: 1px solid #efebe3; }
.rtile .i { font-size: 18px; color: #5b6763; }
.rtile b { display: block; font-size: 14px; } .rtile small { color: #5b6763; font-size: 12px; }
.rtile .st { margin-left: auto; font-size: 12.5px; font-weight: 600; }
.seg { display: flex; border: 1px solid #b9b3a8; border-radius: 22px; overflow: hidden; margin: 0 16px 10px; }
.seg div { flex: 1; height: 40px; display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: 13.5px; }
.seg div.on { background: #ddefe9; color: #124E41; } .seg div + div { border-left: 1px solid #b9b3a8; }
.qa { display: flex; gap: 8px; padding: 2px 16px 12px; }
.qa div { flex: 1; background: #fff; border: 1px solid #e6e2da; border-radius: 18px; padding: 10px 4px; text-align: center; font-size: 11.5px; font-weight: 700; }
.qa .i { display: block; color: #1B6B5A; font-size: 22px; margin-bottom: 4px; }
.grid2 { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; padding: 14px 16px; }
.gcard { background: #F7F5F0; border-radius: 18px; padding: 14px; }
.gcard b { display: block; font-size: 15.5px; } .gcard small { color: #5b6763; font-size: 12.5px; }
.days { display: flex; gap: 6px; }
.days span { width: 38px; height: 38px; border-radius: 50%; display: grid; place-items: center; font-weight: 700; font-size: 13px; border: 1px solid #d6d1c7; background: #fff; }
.days span.on { background: #1B6B5A; color: #fff; border-color: #1B6B5A; }
.switch { width: 46px; height: 28px; border-radius: 14px; background: #1B6B5A; position: relative; flex: none; }
.switch::after { content: ""; position: absolute; right: 4px; top: 4px; width: 20px; height: 20px; border-radius: 50%; background: #fff; }
.switch.off { background: #e6e2da; border: 2px solid #8f8a80; } .switch.off::after { left: 4px; right: auto; top: 2px; background: #8f8a80; width: 18px; height: 18px; }
.list { background: #fff; border: 1px solid #e6e2da; border-radius: 18px; overflow: hidden; }
.li { display: flex; align-items: center; gap: 12px; padding: 13px 16px; border-top: 1px solid #efebe3; font-size: 14.5px; }
.li:first-child { border-top: 0; }
.li .v { margin-left: auto; font-weight: 700; color: #16201c; } .li .i { color: #5b6763; }

/* iPhone 6.9": canvas 1080x2347 rendered at 1320/1080. */
.phone.iphone { left: 110px; top: 450px; width: 860px; height: 1810px; border-radius: 112px; }
.phone.iphone .screen { height: 844px; transform: scale(2.0923); border-radius: 44px; }
/* iPad: 13" store size (canvas 1080x1440 rendered at 2064/1080), showing an 11" iPad in portrait
   (834x1194 pt), where the app uses the full width. */
body.ipad .cap { top: 30px; }
body.ipad .cap h1 { font-size: 52px; letter-spacing: -1.4px; }
body.ipad .cap p { margin-top: 10px; font-size: 25px; }
.tablet { position: absolute; left: 89px; top: 150px; width: 901px; height: 1270px; border-radius: 54px; background: #0b0f0e;
  padding: 22px; box-shadow: 0 40px 90px rgba(0,0,0,.45), inset 0 0 0 3px #26302c; }
.ipadscreen { width: 834px; height: 1194px; transform: scale(1.0276); transform-origin: 0 0; border-radius: 32px; overflow: hidden; }
.ipadscreen .screen { width: 834px; height: 1194px; transform: none; border-radius: 0; }
/* Lock screen with a reminder. */
.lock { position: absolute; inset: 0; background: linear-gradient(170deg, #2b3a5c, #0e1a2b 55%, #1d2f2a); color: #fff; text-align: center; }
.lock .clock { margin-top: 70px; font-size: 84px; font-weight: 300; letter-spacing: -2px; }
.lock .date { font-size: 17px; font-weight: 600; opacity: .85; }
.note { margin: 34px 12px 0; background: rgba(245,245,245,.92); color: #111; border-radius: 22px; padding: 12px 14px; text-align: left;
  display: flex; gap: 10px; }
.note svg { width: 38px; height: 38px; border-radius: 9px; flex: none; }
.note b { font-size: 14.5px; } .note small { color: #666; font-size: 12px; float: right; }
.note p { font-size: 14px; line-height: 1.35; margin-top: 2px; }
'''

STATUS = ('<div class="status"><span>9:41</span><span><span class="i fill">signal_cellular_alt</span> '
          '<span class="i fill">wifi</span> <span class="i fill">battery_full</span></span></div>')


def nav(active, unread=3):
    items = [('chat_bubble', 'Messages'), ('campaign', 'Campaigns'), ('group', 'Contacts'), ('settings', 'Settings')]
    out = '<div class="nav">'
    for icon, label in items:
        on = label == active
        badge = f'<span class="badge">{unread}</span>' if label == 'Messages' and unread else ''
        out += f'<div class="{"on" if on else ""}"><span class="i {"fill" if on else ""}">{icon}</span>{label}{badge}</div>'
    return out + '</div>'


def tile(initials, cls, name, snip, time, unread=0):
    u = ' unread' if unread else ''
    cnt = f'<span class="count">{unread}</span>' if unread else ''
    return (f'<div class="tile{u}"><div class="av {cls}">{initials}</div><div class="body"><div class="row">'
            f'<span class="name">{name}</span><span class="time">{time}</span></div><div class="row">'
            f'<span class="snip" style="flex:1">{snip}</span>{cnt}</div></div></div>')


SHOTS = [
    ('All your texts,<br><em>plus</em> so much more', 'A complete messaging app, made for people who message many.',
     STATUS + '<div class="title"><h2>Messages</h2><span class="i">done_all</span></div>'
     '<div class="search"><span class="i">search</span>Search messages and people</div>'
     '<div class="chips"><span class="chip on">All</span><span class="chip">Unread</span><span class="chip">Campaign replies</span></div>'
     '<div class="sheet" style="top:196px">'
     + tile('AO', 'a1', 'Ada Okafor', 'Wouldn’t miss it 🙌', '9:38', 2)
     + tile('GC', 'a2', 'Grace Chapel Choir', 'You: Rehearsal moved to 5pm today', '9:12')
     + tile('TB', 'a3', 'Tunde Bello', 'Can you send me the venue address?', '8:47', 1)
     + tile('MN', 'a4', 'Mrs Nwosu', 'Thank you for the reminder!', 'Yesterday')
     + tile('KA', 'a5', 'Kemi Adeyemi', 'See you on Sunday', 'Yesterday')
     + tile('ST', 'a1', 'Samuel Thompson', 'Payment received, thanks', 'Mon')
     + '</div><div class="fab"><span class="i">edit</span>New message</div>' + nav('Messages')),

    ('Every campaign reply,<br><em>right in the chat</em>', 'Campaign texts land in each person’s conversation, clearly labelled.',
     STATUS + '<div class="appbar"><span class="i">arrow_back</span><div class="av a1" style="width:38px;height:38px;font-size:13px">AO</div>'
     '<div style="flex:1"><h3 style="font-size:16px">Ada Okafor</h3><div class="muted" style="font-size:11.5px">Choir · Volunteers</div></div>'
     '<span class="i">more_vert</span></div><div class="thread">'
     '<div class="day">Saturday</div>'
     '<div class="b in">Hi! What time is rehearsal on Saturday?</div>'
     '<div class="b out">10am at the main hall. See you there!</div><div class="meta">Delivered</div>'
     '<div class="day">Today</div>'
     '<div class="ctag"><span class="i">campaign</span>Campaign · Harvest Sunday</div>'
     '<div class="b out">Hi Ada, Harvest Sunday is this weekend. Service starts at 9. Bring a friend!<br><span style="opacity:.8;font-size:12.5px">Sent via messages.comeriver.com</span></div>'
     '<div class="meta">Delivered · 8:00</div>'
     '<div class="b in">Wouldn’t miss it 🙌 Can I bring my sister?</div>'
     '</div><div class="qr"><span>Yes, please do!</span><span>Thank you</span><span>See you there</span></div>'
     '<div class="reply"><div class="box"><span class="sim">SIM 1 · MTN</span>Text message</div><div class="send"><span class="i fill">send</span></div></div>'),

    ('Write once.<br><em>Personalise</em> for all.', 'Placeholders, a live preview and an SMS counter before you send.',
     STATUS + '<div class="appbar"><span class="i">arrow_back</span><h3>New campaign</h3><span class="muted" style="font-size:12px;padding-right:10px">Draft saved</span></div>'
     '<div class="form">'
     '<div class="field"><label>Campaign name</label><div>Harvest Sunday</div></div>'
     '<div class="field"><label>Send by</label><div style="display:flex;justify-content:space-between">Text and email<span class="i">arrow_drop_down</span></div></div>'
     '<div class="field"><label>Message</label><div>Hi <span class="ph">{first_name}</span>, Harvest Sunday is this weekend. Service starts at 9. Bring a friend!</div></div>'
     '<div class="counter">Longest message (Ada): 112 characters · 1 SMS · 48 left · signature included</div>'
     '<div class="vars"><span>{first_name}</span><span>{name}</span><span>{company}</span><span>{birthday}</span><span>{email}</span></div>'
     '<div class="lbl">Recipients</div>'
     '<div class="gchips"><span class="on"><span class="i">check</span>Choir (42)</span><span class="on"><span class="i">check</span>Volunteers (18)</span><span>Youth (31)</span></div>'
     '<div class="card"><h4>58 texts · 21 emails</h4><div class="muted" style="font-size:12.5px;margin-top:2px">About 58 SMS segments. 3 excluded: opted out.</div>'
     '<div class="lbl" style="margin-top:8px">Preview for Ada Okafor</div>'
     '<div class="preview">Hi Ada, Harvest Sunday is this weekend. Service starts at 9. Bring a friend!<br>Sent via messages.comeriver.com</div></div>'
     '</div><div style="position:absolute;left:12px;right:12px;bottom:14px"><div class="btn">Save and review</div></div>'),

    ('Follow every<br>message, <em>live</em>', 'Sending, sent, delivered or failed, for every person, by text and email.',
     STATUS + '<div class="appbar"><span class="i">arrow_back</span><h3>Harvest Sunday</h3></div>'
     '<div class="form" style="gap:10px">'
     '<div class="row"><span class="tag t-warn">Sending</span><span class="muted" style="font-size:13px">79 recipients</span></div>'
     '<div class="bar"><i style="width:62%"></i></div>'
     '<div class="card" style="padding:12px 14px;line-height:1.45">Hi {first_name}, Harvest Sunday is this weekend. Service starts at 9. Bring a friend!</div>'
     '<div class="row" style="font-weight:700;font-size:13px">SMS</div>'
     '<div class="stat"><span>Delivered: 31</span><span>Sent: 4</span><span>Sending: 1</span><span>Waiting: 22</span></div>'
     '<div class="row" style="font-weight:700;font-size:13px">Email</div>'
     '<div class="stat"><span>Sent: 13</span><span>Waiting: 8</span></div>'
     '<div>'
     '<div class="rtile"><span class="i">sms</span><div><b>Ada Okafor</b><small>+234 803 123 4567</small></div><span class="st" style="color:#124C3F">Delivered</span></div>'
     '<div class="rtile"><span class="i">mail</span><div><b>Ada Okafor</b><small>ada@example.com</small></div><span class="st">Sent</span></div>'
     '<div class="rtile"><span class="i">sms</span><div><b>Bola Ade</b><small>+234 805 222 1100</small></div><span class="st" style="color:#124C3F">Delivered</span></div>'
     '<div class="rtile"><span class="i">sms</span><div><b>Chidi Obi</b><small>+234 701 555 0192</small></div><span class="st" style="color:#7A4B00">Sending</span></div>'
     '<div class="rtile"><span class="i">sms</span><div><b>Dayo Lawal</b><small>+234 809 444 7781</small></div><span class="st muted">Waiting</span></div>'
     '</div></div>'
     '<div style="position:absolute;left:12px;right:12px;bottom:14px;display:flex;gap:10px"><div class="btn tonal" style="flex:1"><span class="i">pause</span>Pause</div><div class="btn outline" style="flex:1">Cancel campaign</div></div>'),

    ('Your phone’s contacts,<br><em>already here</em>', 'Numbers, emails and birthdays stay in sync. Group people in two taps.',
     STATUS + '<div class="title"><h2>Contacts</h2><span class="muted" style="font-size:13px">412 people</span><span class="i">checklist</span></div>'
     '<div class="qa"><div><span class="i">description</span>From file</div><div><span class="i">person_add</span>Add one</div></div>'
     '<div class="seg"><div>People</div><div class="on">Groups</div></div>'
     '<div class="sheet" style="top:244px"><div class="grid2">'
     '<div class="gcard"><b>Choir</b><small>42 people</small></div><div class="gcard"><b>Volunteers</b><small>18 people</small></div>'
     '<div class="gcard"><b>Youth fellowship</b><small>31 people</small></div><div class="gcard"><b>Customers</b><small>126 people</small></div>'
     '<div class="gcard"><b>Ushers</b><small>12 people</small></div><div class="gcard"><b>Parents, JSS 2</b><small>57 people</small></div>'
     '<div class="gcard"><b>Staff</b><small>9 people</small></div><div class="gcard"><b>Birthday club</b><small>64 people</small></div>'
     '</div></div><div class="fab"><span class="i">group_add</span>New group</div>' + nav('Contacts')),

    ('Send on <em>your</em><br>schedule', 'Once at a set time, or every week. It sends by itself, even with the app closed.',
     STATUS + '<div class="appbar"><span class="i">arrow_back</span><h3>Schedule</h3></div>'
     '<div class="form">'
     '<div class="card"><div class="muted" style="font-size:12.5px">Campaign</div><div style="font-weight:800;font-size:17px">Sunday service reminder</div></div>'
     '<div class="seg" style="margin:0"><div>Once</div><div class="on">Every week</div></div>'
     '<div class="lbl">On these days</div>'
     '<div class="days"><span>M</span><span>T</span><span>W</span><span>T</span><span>F</span><span class="on">S</span><span class="on">S</span></div>'
     '<div class="field"><label>Time</label><div>08:00</div></div>'
     '<div class="field"><label>Ends</label><div style="color:#5b6763">Never</div></div>'
     '<div class="card" style="background:#ddefe9;border-color:#ddefe9;color:#124C3F">'
     '<div style="font-weight:800">Every Saturday and Sunday at 08:00</div>'
     '<div style="font-size:13px;margin-top:4px">Next run: Sat 08:00 · 79 people · about 79 SMS</div></div>'
     '<div class="muted" style="font-size:12.5px;line-height:1.45">Each run uses the groups as they are then, so people you add later get it too.</div>'
     '</div><div style="position:absolute;left:12px;right:12px;bottom:14px"><div class="btn">Save schedule</div></div>'),

    ('Text or email.<br><em>Or both.</em>', 'Emails go through your Mailgun-compatible service or your own Gmail.',
     STATUS + '<div class="appbar"><span class="i">arrow_back</span><h3>Email</h3></div>'
     '<div class="form">'
     '<div class="muted" style="font-size:13px;line-height:1.45">Campaigns can send emails as well as texts. Emails always go out by themselves.</div>'
     '<div class="lbl">Send emails with</div>'
     '<div class="seg" style="margin:0"><div>Off</div><div class="on">Mailgun API</div><div>Gmail</div></div>'
     '<div class="field"><label>API base URL</label><div>https://api.mailgun.net/v3</div></div>'
     '<div class="field"><label>Sending domain</label><div>mg.gracechapel.org</div></div>'
     '<div class="field"><label>API key</label><div>••••••••••••••••••••••</div></div>'
     '<div class="field"><label>From address</label><div>news@mg.gracechapel.org</div></div>'
     '<div class="row" style="justify-content:space-between"><div><div style="font-weight:700">Add an unsubscribe line</div>'
     '<div class="muted" style="font-size:12.5px">Many countries require a way to opt out.</div></div><div class="switch"></div></div>'
     '<div class="btn outline"><span class="i">outgoing_mail</span>Send test email</div>'
     '</div><div style="position:absolute;left:12px;right:12px;bottom:14px"><div class="btn">Save</div></div>'),

    ('Free to start.<br><em>Pro</em> when you grow.', 'Unlimited campaigns and schedules, and your own signature.',
     STATUS + '<div class="appbar"><span class="i">arrow_back</span><h3>Comeriver Pro</h3></div>'
     '<div class="form">'
     '<div class="card" style="background:#DDEFE9;border-color:#DDEFE9;color:#124C3F;display:flex;gap:10px;align-items:center">'
     '<span class="i fill" style="font-size:26px">workspace_premium</span><div style="font-weight:700;line-height:1.4">Pro removes the limits and lets you change the signature.</div></div>'
     '<div class="lbl">What Pro adds</div>'
     '<div class="list">'
     '<div class="li"><span style="flex:1"></span><span class="muted" style="width:96px;font-weight:700">Free</span><span style="width:86px;font-weight:800">Pro</span></div>'
     '<div class="li"><span style="flex:1">Campaigns</span><span class="muted" style="width:96px">Up to 5</span><span style="width:86px;font-weight:700">Unlimited</span></div>'
     '<div class="li"><span style="flex:1">Schedules</span><span class="muted" style="width:96px">1</span><span style="width:86px;font-weight:700">Unlimited</span></div>'
     '<div class="li"><span style="flex:1">Emails a day</span><span class="muted" style="width:96px">50</span><span style="width:86px;font-weight:700">Your limit</span></div>'
     '<div class="li"><span style="flex:1">Signature</span><span class="muted" style="width:96px">Fixed</span><span style="width:86px;font-weight:700">Yours / none</span></div>'
     '</div>'
     '<div class="lbl">Choose a plan</div>'
     '<div class="btn tonal">Monthly</div><div class="btn">Yearly</div>'
     '<div class="muted" style="font-size:12px;text-align:center">Renews automatically until you cancel in Google Play.</div>'
     '<div class="row" style="justify-content:center;gap:24px;color:#1B6B5A;font-weight:700;font-size:13.5px"><span>Restore purchases</span><span>Manage subscription</span></div>'
     '</div>'),
]


LOGO_SVG = f'<svg viewBox="0 0 108 108">{LOGO}</svg>'

IOS_SHOTS = [
    SHOTS[2],  # Write once. Personalise for all.

    ('Texts in a tap.<br><em>Emails</em> on their own.', 'Review each text in Messages and tap Send, or send to 20 at once.',
     STATUS + '<div class="appbar"><span class="i">arrow_back</span><h3>Harvest Sunday</h3></div>'
     '<div class="form" style="gap:10px">'
     '<div class="row"><span class="tag t-warn">Waiting for you</span><span class="muted" style="font-size:13px">79 recipients</span></div>'
     '<div class="bar"><i style="width:43%"></i></div>'
     '<div class="card" style="padding:12px 14px;line-height:1.45">Hi {first_name}, Harvest Sunday is this weekend. Service starts at 9. Bring a friend!</div>'
     '<div class="row" style="font-weight:700;font-size:13px">SMS</div>'
     '<div class="stat"><span>Sent: 13</span><span>Waiting: 45</span></div>'
     '<div class="row" style="font-weight:700;font-size:13px">Email</div>'
     '<div class="stat"><span>Sent: 21</span></div>'
     '<div>'
     '<div class="rtile"><span class="i">mail</span><div><b>Ada Okafor</b><small>ada@example.com</small></div><span class="st">Sent</span></div>'
     '<div class="rtile"><span class="i">sms</span><div><b>Ada Okafor</b><small>+234 803 123 4567</small></div><span class="st">Sent</span></div>'
     '<div class="rtile"><span class="i">sms</span><div><b>Bola Ade</b><small>+234 805 222 1100</small></div><span class="st">Sent</span></div>'
     '<div class="rtile"><span class="i">sms</span><div><b>Chidi Obi</b><small>+234 701 555 0192</small></div><span class="st muted">Waiting</span></div>'
     '<div class="rtile"><span class="i">sms</span><div><b>Dayo Lawal</b><small>+234 809 444 7781</small></div><span class="st muted">Waiting</span></div>'
     '</div></div>'
     '<div style="position:absolute;left:12px;right:12px;bottom:14px;display:flex;flex-direction:column;gap:8px">'
     '<div class="btn"><span class="i">send</span>Open next message (14 of 58)</div>'
     '<div class="btn outline">Cancel campaign</div></div>'),

    # Contacts: no unread badge (no inbox on iPhone / iPad).
    (SHOTS[4][0], SHOTS[4][1], SHOTS[4][2].replace('<span class="badge">3</span>', '')),

    ('Send on <em>your</em><br>schedule', 'Get a reminder the moment it’s due. Emails go out on their own.',
     SHOTS[5][2].replace('Each run uses the groups as they are then, so people you add later get it too.',
                         'When a run is due you get a reminder: open it and tap Send for each text. '
                         'Emails in the run go out by themselves.')),

    ('Never miss<br>a <em>send</em>', 'A reminder arrives as soon as a scheduled campaign is due.',
     '<div class="lock">' + STATUS.replace('class="status"', 'class="status" style="color:#fff"') +
     '<div class="clock">8:00</div><div class="date">Sunday 26 October</div>'
     f'<div class="note">{LOGO_SVG}<div style="flex:1"><b>Messages++</b><small>now</small>'
     '<p><b>Sunday service reminder is due</b><br>Open Messages++ to send it. Texts need a tap each; emails go by themselves.</p></div></div>'
     '<div class="note" style="margin-top:10px;opacity:.75">' + LOGO_SVG +
     '<div style="flex:1"><b>Messages++</b><small>Sat</small><p>Youth fellowship reminder: 31 texts sent, 9 emails sent.</p></div></div>'
     '</div>'),

    SHOTS[6],  # Text or email
    (SHOTS[7][0], SHOTS[7][1], SHOTS[7][2].replace('cancel in Google Play', 'cancel in the App Store')),
]

DEVICES = {
    # name: (canvas css size, output pixels, body class, frame)
    'android': ((1080, 1920), (1080, 1920), '', 'phone'),
    'iphone': ((1080, 2347), (1320, 2868), '', 'iphone'),
    'ipad': ((1080, 1440), (2064, 2752), 'ipad', 'ipad'),
}


def render(device, out, caption, sub, screen):
    (cw, ch), (ow, oh), body, frame = DEVICES[device]
    if frame == 'ipad':
        caption = caption.replace('<br>', ' ')
        device_html = f'<div class="tablet"><div class="ipadscreen"><div class="screen">{screen}</div></div></div>'
    else:
        device_html = f'<div class="phone {"iphone" if frame == "iphone" else ""}"><div class="screen">{screen}</div></div>'
    page = (f'<!doctype html><html><head><meta charset="utf-8">'
            '<link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=block" rel="stylesheet">'
            '<link href="https://fonts.googleapis.com/css2?family=Material+Symbols+Rounded:opsz,wght,FILL,GRAD@24,500,0..1,0&display=block" rel="stylesheet">'
            f'<style>{CSS} html, body {{ width: {cw}px; height: {ch}px; }}</style></head>'
            f'<body class="{body}"><div class="cap"><h1>{caption}</h1><p>{sub}</p></div>{device_html}</body></html>')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, 'shot.html')
        open(path, 'w').write(page)
        subprocess.run([CHROME, '--headless=new', '--disable-gpu', '--hide-scrollbars',
                        f'--force-device-scale-factor={ow / cw}', '--virtual-time-budget=8000',
                        f'--window-size={cw},{ch}', '--screenshot=' + out, 'file://' + path],
                       check=True, capture_output=True)
        # Exact store size (rounding in the browser can be a pixel off).
        subprocess.run(['sips', '-z', str(oh), str(ow), out, '--out', out], check=True, capture_output=True)
        print('Wrote', os.path.relpath(out, ROOT))


if __name__ == '__main__':
    for n, (caption, sub, screen) in enumerate(SHOTS, start=1):
        render('android', os.path.join(OUT, f'screenshot_{n}.png'), caption, sub, screen)
    for n, (caption, sub, screen) in enumerate(IOS_SHOTS, start=1):
        render('iphone', os.path.join(OUT, 'ios', f'iphone_{n}.png'), caption, sub, screen)
        render('ipad', os.path.join(OUT, 'ios', f'ipad_{n}.png'), caption, sub, screen)
